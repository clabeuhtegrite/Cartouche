//! IPAs for the tests: Cartouche as app/scripts/package.sh assembles it
//! (LiveContainer's app, SideStore's framework, LiveProcess and the widget),
//! with small Mach-O executables isideload can sign and the fake iPhone can
//! check, and any other app.

use std::io::Write;

use zip::write::SimpleFileOptions;

pub use crate::github::BUNDLE_ID;

const MH_MAGIC_64: u32 = 0xfeed_facf;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;
pub const MH_EXECUTE: u32 = 2;
pub const MH_DYLIB: u32 = 6;
const LC_SEGMENT_64: u32 = 0x19;
const LC_CODE_SIGNATURE: u32 = 0x1d;

/// A thin arm64 Mach-O: __TEXT with one section of code made from `seed`,
/// __LINKEDIT, and room after the load commands for the signer to add its
/// LC_CODE_SIGNATURE. With `signed`, it has one already, empty, as a
/// binary signed ad hoc by its build.
pub fn macho(filetype: u32, seed: &str, signed: bool) -> Vec<u8> {
    const TEXT_SIZE: usize = 0x4000;
    const CODE_OFFSET: usize = 0x1000;
    const CODE_LEN: usize = 0x2400;
    let linkedit: Vec<u8> = pseudo_random(&format!("{seed}-linkedit"), 0x180);
    let signature_slot = if signed { 0x200 } else { 0 };

    let ncmds: u32 = if signed { 3 } else { 2 };
    let sizeofcmds: u32 = 152 + 72 + if signed { 16 } else { 0 };
    let mut data = vec![0u8; TEXT_SIZE + linkedit.len() + signature_slot];
    let put32 = |data: &mut Vec<u8>, at: usize, v: u32| data[at..at + 4].copy_from_slice(&v.to_le_bytes());
    let put64 = |data: &mut Vec<u8>, at: usize, v: u64| data[at..at + 8].copy_from_slice(&v.to_le_bytes());
    let name = |data: &mut Vec<u8>, at: usize, s: &str| data[at..at + s.len()].copy_from_slice(s.as_bytes());

    put32(&mut data, 0, MH_MAGIC_64);
    put32(&mut data, 4, CPU_TYPE_ARM64);
    put32(&mut data, 8, 0);
    put32(&mut data, 12, filetype);
    put32(&mut data, 16, ncmds);
    put32(&mut data, 20, sizeofcmds);
    put32(&mut data, 24, 0x0020_0085); // MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE

    // __TEXT, with its one section.
    let at = 32;
    put32(&mut data, at, LC_SEGMENT_64);
    put32(&mut data, at + 4, 152);
    name(&mut data, at + 8, "__TEXT");
    put64(&mut data, at + 24, 0x1_0000_0000);
    put64(&mut data, at + 32, TEXT_SIZE as u64);
    put64(&mut data, at + 40, 0);
    put64(&mut data, at + 48, TEXT_SIZE as u64);
    put32(&mut data, at + 56, 5);
    put32(&mut data, at + 60, 5);
    put32(&mut data, at + 64, 1);
    let section = at + 72;
    name(&mut data, section, "__text");
    name(&mut data, section + 16, "__TEXT");
    put64(&mut data, section + 32, 0x1_0000_0000 + CODE_OFFSET as u64);
    put64(&mut data, section + 40, CODE_LEN as u64);
    put32(&mut data, section + 48, CODE_OFFSET as u32);
    put32(&mut data, section + 52, 2);
    put32(&mut data, section + 64, 0x8000_0400);

    // __LINKEDIT, at the end of the file.
    let at = 32 + 152;
    let linkedit_size = linkedit.len() + signature_slot;
    put32(&mut data, at, LC_SEGMENT_64);
    put32(&mut data, at + 4, 72);
    name(&mut data, at + 8, "__LINKEDIT");
    put64(&mut data, at + 24, 0x1_0000_0000 + TEXT_SIZE as u64);
    put64(&mut data, at + 32, 0x4000);
    put64(&mut data, at + 40, TEXT_SIZE as u64);
    put64(&mut data, at + 48, linkedit_size as u64);
    put32(&mut data, at + 56, 1);
    put32(&mut data, at + 60, 1);

    if signed {
        let at = 32 + 152 + 72;
        put32(&mut data, at, LC_CODE_SIGNATURE);
        put32(&mut data, at + 4, 16);
        put32(&mut data, at + 8, (TEXT_SIZE + linkedit.len()) as u32);
        put32(&mut data, at + 12, signature_slot as u32);
    }

    let code = pseudo_random(seed, CODE_LEN);
    data[CODE_OFFSET..CODE_OFFSET + CODE_LEN].copy_from_slice(&code);
    data[TEXT_SIZE..TEXT_SIZE + linkedit.len()].copy_from_slice(&linkedit);
    data
}

/// Bytes that look like content and are the same for the same seed.
pub fn pseudo_random(seed: &str, len: usize) -> Vec<u8> {
    use sha2::Digest;
    let mut out = Vec::with_capacity(len + 32);
    let mut block = sha2::Sha256::digest(seed.as_bytes()).to_vec();
    while out.len() < len {
        out.extend_from_slice(&block);
        block = sha2::Sha256::digest(&block).to_vec();
    }
    out.truncate(len);
    out
}

fn binary_plist(dict: plist::Dictionary) -> Vec<u8> {
    let mut out = Vec::new();
    plist::Value::Dictionary(dict).to_writer_binary(&mut out).expect("plist");
    out
}

fn xml_plist(dict: plist::Dictionary) -> Vec<u8> {
    crate::wire::xml(&dict)
}

#[derive(Clone, Debug)]
pub struct CartoucheIpa {
    pub bundle_id: String,
    pub version: String,
    /// The built-in SideStore's framework, com.SideStore.SideStore: what
    /// makes isideload give Cartouche its certificate.
    pub sidestore_framework: bool,
    /// Whether the Files app (and house_arrest) can reach its Documents.
    pub file_sharing: bool,
    pub extensions: bool,
    /// Cartouche for the player's own certificate, which a signing app signs
    /// on the iPhone (app/scripts/own_certificate_ipa.py):
    /// CartoucheImportedSigning in its Info.plist.
    pub own_certificate: bool,
    /// Pads the app with this many bytes, for a large download.
    pub padding: usize,
}

impl CartoucheIpa {
    pub fn new(version: &str) -> Self {
        CartoucheIpa {
            bundle_id: BUNDLE_ID.into(),
            version: version.into(),
            sidestore_framework: true,
            file_sharing: true,
            extensions: true,
            own_certificate: false,
            padding: 0,
        }
    }

    pub fn build(&self) -> Vec<u8> {
        let app = "Payload/LiveContainer.app";
        let mut files: Vec<(String, Vec<u8>)> = Vec::new();
        let id = &self.bundle_id;
        let mut info = crate::dict! {
            "CFBundleIdentifier" => id.clone(),
            "CFBundleExecutable" => "LiveContainer",
            "CFBundleName" => "LiveContainer",
            "CFBundleDisplayName" => "LiveContainer",
            "CFBundleShortVersionString" => self.version.clone(),
            "CFBundleVersion" => self.version.clone(),
            "CFBundlePackageType" => "APPL",
            "CFBundleDevelopmentRegion" => "en",
            "CFBundleSupportedPlatforms" => vec![plist::Value::from("iPhoneOS")],
            "MinimumOSVersion" => "26.0",
            "UIDeviceFamily" => vec![plist::Value::from(1u64)],
            "LSSupportsOpeningDocumentsInPlace" => true,
            "ALTAppGroups" => vec![plist::Value::from("group.com.SideStore.SideStore")],
            "CartoucheBundleIdentifier" => id.clone(),
            "BGTaskSchedulerPermittedIdentifiers" => vec![plist::Value::from(format!("{id}.transfer.*"))],
            "LSApplicationCategoryType" => "public.app-category.games"
        };
        if self.file_sharing {
            info.insert("UIFileSharingEnabled".into(), true.into());
        }
        if self.own_certificate {
            info.insert("CartoucheImportedSigning".into(), true.into());
        }
        files.push((format!("{app}/Info.plist"), xml_plist(info)));
        files.push((format!("{app}/LiveContainer"), macho(MH_EXECUTE, &format!("main {}", self.version), true)));
        files.push((format!("{app}/PkgInfo"), b"APPL????".to_vec()));
        files.push((format!("{app}/Assets.car"), pseudo_random("assets", 4096 + self.padding)));
        for (lang, name) in [("en", "Cartouche"), ("fr", "Cartouche")] {
            let strings = format!("\"CFBundleDisplayName\" = \"{name}\";\n\"CFBundleName\" = \"{name}\";\n");
            files.push((format!("{app}/{lang}.lproj/InfoPlist.strings"), strings.into_bytes()));
        }
        files.push((format!("{app}/CartoucheCatalog/nxnative.json"), b"{\"games\":[]}".to_vec()));

        let shared = format!("{app}/Frameworks/LiveContainerShared.framework");
        files.push((
            format!("{shared}/Info.plist"),
            binary_plist(crate::dict! {
                "CFBundleIdentifier" => "com.kdt.LiveContainerShared",
                "CFBundleExecutable" => "LiveContainerShared",
                "CFBundlePackageType" => "FMWK",
                "CFBundleShortVersionString" => "3.6.0"
            }),
        ));
        files.push((format!("{shared}/LiveContainerShared"), macho(MH_DYLIB, "shared", false)));

        if self.sidestore_framework {
            let ss = format!("{app}/Frameworks/SideStoreApp.framework");
            files.push((
                format!("{ss}/Info.plist"),
                binary_plist(crate::dict! {
                    "CFBundleIdentifier" => "com.SideStore.SideStore",
                    "CFBundleExecutable" => "SideStore",
                    "CFBundleName" => "SideStore",
                    "CFBundlePackageType" => "FMWK",
                    "CFBundleShortVersionString" => "0.6.2"
                }),
            ));
            files.push((format!("{ss}/SideStore"), macho(MH_DYLIB, "sidestore", false)));
            files.push((format!("{ss}/LCAppInfo.plist"), xml_plist(crate::dict! { "LCJITLessSignID" => 0u64 })));
        }

        if self.extensions {
            for (dir, exe, suffix) in [
                ("LiveProcess.appex", "LiveProcess", "LiveProcess"),
                ("LiveWidgetExtension.appex", "LiveWidgetExtension", "LiveWidget"),
            ] {
                let ext = format!("{app}/PlugIns/{dir}");
                files.push((
                    format!("{ext}/Info.plist"),
                    xml_plist(crate::dict! {
                        "CFBundleIdentifier" => format!("{id}.{suffix}"),
                        "CFBundleExecutable" => exe,
                        "CFBundleName" => exe,
                        "CFBundlePackageType" => "XPC!",
                        "CFBundleShortVersionString" => self.version.clone(),
                        "NSExtension" => crate::dict! { "NSExtensionPointIdentifier" => "com.apple.widgetkit-extension" }
                    }),
                ));
                files.push((format!("{ext}/{exe}"), macho(MH_EXECUTE, exe, true)));
            }
        }
        zip(&files)
    }
}

/// Any other app, as a player might pick by mistake.
pub fn other_app_ipa(bundle_id: &str, name: &str) -> Vec<u8> {
    let app = format!("Payload/{name}.app");
    let files = vec![
        (
            format!("{app}/Info.plist"),
            xml_plist(crate::dict! {
                "CFBundleIdentifier" => bundle_id,
                "CFBundleExecutable" => name,
                "CFBundleName" => name,
                "CFBundleShortVersionString" => "1.0",
                "CFBundleVersion" => "1",
                "CFBundlePackageType" => "APPL"
            }),
        ),
        (format!("{app}/{name}"), macho(MH_EXECUTE, name, false)),
    ];
    zip(&files)
}

fn zip(files: &[(String, Vec<u8>)]) -> Vec<u8> {
    let mut out = std::io::Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut out);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        let mut dirs: Vec<String> = Vec::new();
        for (path, _) in files {
            let parts: Vec<&str> = path.split('/').collect();
            for i in 1..parts.len() {
                let dir = format!("{}/", parts[..i].join("/"));
                if !dirs.contains(&dir) {
                    dirs.push(dir);
                }
            }
        }
        for dir in &dirs {
            writer.add_directory(dir.as_str(), options).expect("directory");
        }
        for (path, data) in files {
            writer.start_file(path.as_str(), options).expect("file");
            writer.write_all(data).expect("write");
        }
        writer.finish().expect("zip");
    }
    out.into_inner()
}
