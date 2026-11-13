//! A stand-in for Apple's certificate authorities: it signs the development
//! certificates the developer services hand out, and wraps provisioning
//! profiles in CMS as Apple does, with its own certificates inside, which is
//! where isideload finds the chain of a certificate that is not Apple's.

use cms::{
    cert::CertificateChoices,
    content_info::{CmsVersion, ContentInfo},
    signed_data::{CertificateSet, EncapsulatedContentInfo, SignedData, SignerInfos},
};
use der::{Decode, Encode, asn1::SetOfVec};
use rcgen::{
    BasicConstraints, CertificateParams, CertificateSigningRequestParams, DnType,
    ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair, KeyUsagePurpose, SerialNumber,
};
use x509_cert::spki::{AlgorithmIdentifierOwned, ObjectIdentifier};

const ID_SIGNED_DATA: &str = "1.2.840.113549.1.7.2";
const ID_DATA: &str = "1.2.840.113549.1.7.1";
const ID_SHA256: &str = "2.16.840.1.101.3.4.2.1";

pub struct AppleCa {
    wwdr_key: KeyPair,
    wwdr_params: CertificateParams,
    pub root_der: Vec<u8>,
    pub wwdr_der: Vec<u8>,
}

/// A development certificate as the developer services issued it.
pub struct Issued {
    pub der: Vec<u8>,
    /// The serial number in Apple's notation: hexadecimal, upper case, no
    /// leading zero.
    pub serial: String,
}

impl AppleCa {
    pub fn new() -> Self {
        let root_key = KeyPair::generate().expect("key");
        let mut root_params = CertificateParams::new(Vec::<String>::new()).expect("params");
        root_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        root_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
        root_params.distinguished_name.push(DnType::CommonName, "Fake Apple Root CA");
        root_params.distinguished_name.push(DnType::OrganizationName, "Fake Apple Inc.");
        let root = root_params.self_signed(&root_key).expect("root");
        let root_issuer = Issuer::new(root_params, &root_key);

        let wwdr_key = KeyPair::generate().expect("key");
        let mut wwdr_params = CertificateParams::new(Vec::<String>::new()).expect("params");
        wwdr_params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
        wwdr_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
        wwdr_params.distinguished_name.push(
            DnType::CommonName,
            "Fake Apple Worldwide Developer Relations Certification Authority",
        );
        wwdr_params.distinguished_name.push(DnType::OrganizationalUnitName, "G3");
        wwdr_params.distinguished_name.push(DnType::OrganizationName, "Fake Apple Inc.");
        let wwdr = wwdr_params.signed_by(&wwdr_key, &root_issuer).expect("wwdr");

        AppleCa {
            wwdr_key,
            wwdr_params,
            root_der: root.der().to_vec(),
            wwdr_der: wwdr.der().to_vec(),
        }
    }

    /// Signs a development certificate for the key of `csr_pem`, with the
    /// subject Apple gives it, whatever the request said, for a year.
    pub fn issue_development(&self, csr_pem: &str, team_id: &str, holder: &str) -> Result<Issued, String> {
        let now = std::time::SystemTime::now();
        let year = std::time::Duration::from_secs(365 * 24 * 3600);
        self.issue_development_between(csr_pem, team_id, holder, now - std::time::Duration::from_secs(3600), now + year)
    }

    /// The same, valid from `not_before` to `not_after`.
    pub fn issue_development_between(
        &self,
        csr_pem: &str,
        team_id: &str,
        holder: &str,
        not_before: std::time::SystemTime,
        not_after: std::time::SystemTime,
    ) -> Result<Issued, String> {
        let mut csr = CertificateSigningRequestParams::from_pem(csr_pem)
            .map_err(|e| format!("the certificate signing request does not read: {e}"))?;
        let mut serial = [0u8; 8];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut serial);
        serial[0] = 0x10 | (serial[0] & 0x6f);
        let mut params = std::mem::replace(&mut csr.params, CertificateParams::default());
        params.distinguished_name = rcgen::DistinguishedName::new();
        params.distinguished_name.push(DnType::CommonName, format!("Apple Development: {holder} ({team_id})"));
        params.distinguished_name.push(DnType::OrganizationalUnitName, team_id);
        params.distinguished_name.push(DnType::OrganizationName, holder);
        params.distinguished_name.push(DnType::CountryName, "FR");
        params.serial_number = Some(SerialNumber::from_slice(&serial));
        params.is_ca = IsCa::ExplicitNoCa;
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::CodeSigning];
        params.not_before = not_before.into();
        params.not_after = not_after.into();
        csr.params = params;
        let issuer = Issuer::new(self.wwdr_params.clone(), &self.wwdr_key);
        let cert = csr.signed_by(&issuer).map_err(|e| format!("could not sign the certificate: {e}"))?;
        Ok(Issued {
            der: cert.der().to_vec(),
            serial: hex::encode_upper(serial).trim_start_matches('0').to_string(),
        })
    }

    /// A provisioning profile: the plist inside CMS SignedData, with the
    /// authority's certificates.
    pub fn profile(&self, plist: &plist::Dictionary) -> Vec<u8> {
        let mut xml = Vec::new();
        plist::Value::Dictionary(plist.clone()).to_writer_xml(&mut xml).expect("plist");
        let certificates: Vec<CertificateChoices> = [&self.wwdr_der, &self.root_der]
            .into_iter()
            .map(|der| CertificateChoices::Certificate(x509_cert::Certificate::from_der(der).expect("certificate")))
            .collect();
        let signed = SignedData {
            version: CmsVersion::V1,
            digest_algorithms: SetOfVec::try_from(vec![AlgorithmIdentifierOwned {
                oid: ObjectIdentifier::new_unwrap(ID_SHA256),
                parameters: None,
            }])
            .expect("digests"),
            encap_content_info: EncapsulatedContentInfo {
                econtent_type: ObjectIdentifier::new_unwrap(ID_DATA),
                econtent: Some(der::Any::new(der::Tag::OctetString, xml).expect("content")),
            },
            certificates: Some(CertificateSet(SetOfVec::try_from(certificates).expect("certificates"))),
            crls: None,
            signer_infos: SignerInfos(SetOfVec::new()),
        };
        let info = ContentInfo {
            content_type: ObjectIdentifier::new_unwrap(ID_SIGNED_DATA),
            content: der::Any::encode_from(&signed).expect("signed data"),
        };
        info.to_der().expect("profile")
    }
}

impl Default for AppleCa {
    fn default() -> Self {
        Self::new()
    }
}
