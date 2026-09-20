//! Shared `#[cfg(test)]` loader for `TestVectors/bip39.json`, used by
//! `keys::Mnemonic` tests.

use serde_json::Value;

/// `[entropy_hex, mnemonic, seed_hex, master_xprv]` from the `english`
/// entries of the reference BIP39 test vectors.
pub fn english_vectors() -> Vec<(String, String, String, String)> {
    vectors_for("english")
}

/// `[entropy_hex, mnemonic, seed_hex, master_xprv]` from the `language_key`
/// entries of the reference BIP39 test vectors (e.g. `"japanese"`,
/// `"chinese_simplified"` — the snake_case keys used in the vectors file).
pub fn vectors_for(language_key: &str) -> Vec<(String, String, String, String)> {
    let raw = include_str!("../../../TestVectors/bip39.json");
    let json: Value = serde_json::from_str(raw).expect("bip39.json is valid JSON");
    json[language_key]
        .as_array()
        .unwrap_or_else(|| panic!("{language_key} vectors present"))
        .iter()
        .map(|entry| {
            let entry = entry.as_array().expect("vector is a 4-tuple");
            (
                entry[0].as_str().unwrap().to_string(),
                entry[1].as_str().unwrap().to_string(),
                entry[2].as_str().unwrap().to_string(),
                entry[3].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

