//! Entry point for the `uniffi-bindgen` binary target declared in
//! `Cargo.toml`. Not part of the library itself — this just gives UniFFI's
//! bindings generator a binary to run via `cargo run --features cli --bin
//! uniffi-bindgen -- generate ...`. See ../README.md.

#[cfg(feature = "cli")]
fn main() {
    uniffi::uniffi_bindgen_main()
}

#[cfg(not(feature = "cli"))]
fn main() {
    eprintln!("The UniFFI CLI binding generator requires the `cli` feature. Run `cargo run --features cli --bin uniffi-bindgen -- generate ...`");
    std::process::exit(1);
}
