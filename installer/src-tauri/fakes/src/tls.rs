//! Certificates for the fakes: the keys an iPhone and a computer share once
//! paired, and a certificate authority for the fake HTTPS servers.

use std::sync::Arc;

use rcgen::{
    BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose, SanType,
};
use rustls::{
    RootCertStore, ServerConfig,
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer},
    server::WebPkiClientVerifier,
};

pub fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::aws_lc_rs::default_provider())
}

/// What a pairing leaves on both sides: the iPhone's certificate, and the
/// computer's root and host certificates, as usbmuxd keeps them in its
/// pair record.
#[derive(Clone)]
pub struct PairKeys {
    pub root_cert_pem: String,
    pub root_key_pem: String,
    pub host_cert_pem: String,
    pub host_key_pem: String,
    pub device_cert_pem: String,
    pub root_cert_der: Vec<u8>,
    pub device_cert_der: Vec<u8>,
    pub device_key_der: Vec<u8>,
    pub host_id: String,
    pub system_buid: String,
    pub escrow_bag: Vec<u8>,
}

impl PairKeys {
    pub fn generate() -> Self {
        let root_key = KeyPair::generate().expect("key");
        let mut root_params = CertificateParams::new(Vec::<String>::new()).expect("params");
        root_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        root_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::DigitalSignature];
        root_params.distinguished_name.push(DnType::CommonName, "Root Certification Authority");
        let root_cert = root_params.self_signed(&root_key).expect("root");
        let root_issuer = Issuer::new(root_params, &root_key);

        let host_key = KeyPair::generate().expect("key");
        let mut host_params = CertificateParams::new(Vec::<String>::new()).expect("params");
        host_params.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyEncipherment];
        host_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
        host_params.distinguished_name.push(DnType::CommonName, "Host");
        let host_cert = host_params.signed_by(&host_key, &root_issuer).expect("host");

        let device_key = KeyPair::generate().expect("key");
        let mut device_params = CertificateParams::new(vec!["Device".to_string()]).expect("params");
        device_params.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyEncipherment];
        device_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        device_params.distinguished_name.push(DnType::CommonName, "Device");
        let device_cert = device_params.signed_by(&device_key, &root_issuer).expect("device");

        let mut escrow_bag = vec![0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut escrow_bag);

        PairKeys {
            root_cert_pem: root_cert.pem(),
            root_key_pem: root_key.serialize_pem(),
            host_cert_pem: host_cert.pem(),
            host_key_pem: host_key.serialize_pem(),
            device_cert_pem: device_cert.pem(),
            root_cert_der: root_cert.der().to_vec(),
            device_cert_der: device_cert.der().to_vec(),
            device_key_der: device_key.serialize_der(),
            host_id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            system_buid: uuid::Uuid::new_v4().to_string().to_uppercase(),
            escrow_bag,
        }
    }

    /// The pair record as usbmuxd hands it to the installer.
    pub fn pair_record(&self, udid: &str, wifi_mac: &str) -> plist::Dictionary {
        let mut d = plist::Dictionary::new();
        d.insert("DeviceCertificate".into(), plist::Value::Data(self.device_cert_pem.clone().into_bytes()));
        d.insert("HostCertificate".into(), plist::Value::Data(self.host_cert_pem.clone().into_bytes()));
        d.insert("HostPrivateKey".into(), plist::Value::Data(self.host_key_pem.clone().into_bytes()));
        d.insert("RootCertificate".into(), plist::Value::Data(self.root_cert_pem.clone().into_bytes()));
        d.insert("RootPrivateKey".into(), plist::Value::Data(self.root_key_pem.clone().into_bytes()));
        d.insert("SystemBUID".into(), self.system_buid.clone().into());
        d.insert("HostID".into(), self.host_id.clone().into());
        d.insert("EscrowBag".into(), plist::Value::Data(self.escrow_bag.clone()));
        d.insert("WiFiMACAddress".into(), wifi_mac.into());
        d.insert("UDID".into(), udid.into());
        d
    }

    /// lockdownd's side of a session: its own certificate, and only a
    /// computer whose host certificate its root signed gets in.
    pub fn device_tls(&self) -> Arc<ServerConfig> {
        let mut roots = RootCertStore::empty();
        roots
            .add(CertificateDer::from(self.root_cert_der.clone()))
            .expect("root");
        let verifier = WebPkiClientVerifier::builder_with_provider(Arc::new(roots), provider())
            .build()
            .expect("verifier");
        let config = ServerConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .expect("versions")
            .with_client_cert_verifier(verifier)
            .with_single_cert(
                vec![CertificateDer::from(self.device_cert_der.clone())],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.device_key_der.clone())),
            )
            .expect("device certificate");
        Arc::new(config)
    }
}

/// A certificate authority for the fake HTTPS servers, which the
/// installer's HTTP client trusts in the tests, and only in the tests.
pub struct TestCa {
    key: KeyPair,
    params: CertificateParams,
    pub cert_der: Vec<u8>,
    pub cert_pem: String,
}

impl TestCa {
    pub fn new() -> Self {
        let key = KeyPair::generate().expect("key");
        let mut params = CertificateParams::new(Vec::<String>::new()).expect("params");
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::DigitalSignature];
        params.distinguished_name.push(DnType::CommonName, "Cartouche Installer tests");
        let cert = params.self_signed(&key).expect("ca");
        TestCa {
            cert_der: cert.der().to_vec(),
            cert_pem: cert.pem(),
            key,
            params,
        }
    }

    /// A server configuration for these host names.
    pub fn server(&self, hosts: &[&str]) -> Arc<ServerConfig> {
        let key = KeyPair::generate().expect("key");
        let mut params = CertificateParams::new(Vec::<String>::new()).expect("params");
        params.subject_alt_names = hosts
            .iter()
            .map(|h| SanType::DnsName((*h).try_into().expect("host name")))
            .collect();
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        params.distinguished_name.push(DnType::CommonName, hosts[0]);
        let issuer = Issuer::new(self.params.clone(), &self.key);
        let cert = params.signed_by(&key, &issuer).expect("server");
        let mut config = ServerConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .expect("versions")
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(cert.der().to_vec()), CertificateDer::from(self.cert_der.clone())],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
            )
            .expect("server certificate");
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        Arc::new(config)
    }
}

impl Default for TestCa {
    fn default() -> Self {
        Self::new()
    }
}
