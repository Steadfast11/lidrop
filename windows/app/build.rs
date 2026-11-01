//! Icon, manifest and, when `windows/vendor/dumbpipe.exe` is there, the tunnel binary inside the one .exe.
use std::path::Path;

fn main() {
    println!("cargo:rustc-check-cfg=cfg(embedded_dumbpipe)");
    println!("cargo:rerun-if-changed=lidrop.rc");
    println!("cargo:rerun-if-changed=lidrop.exe.manifest");
    println!("cargo:rerun-if-changed=../vendor/dumbpipe.exe");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    embed_resource::compile("lidrop.rc", embed_resource::NONE).manifest_required().unwrap();
    let vendored = Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../vendor/dumbpipe.exe");
    if vendored.exists() {
        println!("cargo:rustc-cfg=embedded_dumbpipe");
        println!("cargo:rustc-env=LIDROP_DUMBPIPE={}", vendored.display());
    }
}
