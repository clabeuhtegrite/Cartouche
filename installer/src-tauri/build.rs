fn main() {
    tauri_build::build();
    windows_tests_take_the_apps_resources();
}

/// On Windows, tauri-build links the app's resources, its icon, its version
/// and the manifest that asks for the common controls 6, into the app
/// alone. The tests link the same code, the dialogs' TaskDialogIndirect
/// among it, which only the common controls 6 have: without the manifest,
/// Windows does not even start a test (STATUS_ENTRYPOINT_NOT_FOUND). So the
/// tests take the same resources, as embed-resource compiled them.
fn windows_tests_take_the_apps_resources() {
    let env = |name: &str| std::env::var(name).unwrap_or_default();
    if env("CARGO_CFG_TARGET_OS") != "windows" || env("CARGO_CFG_TARGET_ENV") != "msvc" {
        return;
    }
    let resources = std::path::Path::new(&env("OUT_DIR")).join("resource.lib");
    if resources.is_file() {
        println!("cargo:rustc-link-arg-tests={}", resources.display());
    } else {
        println!("cargo:warning=no {}: the tests may not start on Windows", resources.display());
    }
}
