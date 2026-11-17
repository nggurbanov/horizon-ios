//! Compiles the touch overlay (objc/, adapted from Amethyst-iOS) into the iOS app.
use std::path::{Path, PathBuf};

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "m") {
            out.push(path);
        }
    }
}

fn main() {
    let objc = Path::new(env!("CARGO_MANIFEST_DIR")).join("objc");
    println!("cargo:rerun-if-changed={}", objc.display());
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("ios") {
        return;
    }
    let mut files = Vec::new();
    sources(&objc, &mut files);
    files.sort();
    cc::Build::new()
        .files(&files)
        .include(&objc)
        .flag("-fobjc-arc")
        .flag("-fmodules")
        .flag("-Wno-deprecated-declarations")
        .flag("-Wno-unused-parameter")
        .flag("-Wno-unused-variable")
        .flag("-Wno-unused-function")
        .warnings(false)
        .compile("horizon_ios_overlay");
    for framework in [
        "UIKit",
        "Foundation",
        "CoreMotion",
        "GameController",
        "QuartzCore",
        "CoreGraphics",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    // The overlay's Objective-C categories must load though nothing in Rust names them.
    println!("cargo:rustc-link-arg=-ObjC");
}
