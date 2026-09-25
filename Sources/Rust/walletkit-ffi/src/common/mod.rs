//! Low-level, chain-agnostic types. See
//! `Walletkit/Docs/Design Specification/Core/` for the target shape:
//! `CurveFfi`, `DerivationScheme`, `Wordlist`, `MnemonicWordCount`,
//! `BlockchainFfi`, `DerivationPathFfi`.
//!
//! Named `common` rather than `core` because `core` is reserved by the
//! Rust standard library. These are plain data types crossing the UniFFI
//! boundary as Records/Enums; the ergonomic computed properties/statics
//! the Swift design spec describes (`Blockchain.ethereum`,
//! `DerivationPath(string:)`, ...) are added on the Swift side, since
//! they're pure data-shuffling with no cryptography involved.

mod big_int;
mod blockchain;
mod curve;
mod derivation_path;
mod derivation_scheme;
mod mnemonic_word_count;
mod segment;
pub(crate) mod wordlist;

pub use big_int::BigIntFfi;
pub use blockchain::BlockchainFfi;
pub use curve::CurveFfi;
pub use derivation_path::DerivationPathFfi;
pub use derivation_scheme::DerivationScheme;
pub use mnemonic_word_count::MnemonicWordCount;
pub use segment::Segment;
pub use wordlist::Wordlist;
