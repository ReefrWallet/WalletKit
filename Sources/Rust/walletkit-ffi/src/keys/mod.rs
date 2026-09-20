//! Software key management. See
//! `Walletkit/Docs/Design Specification/Keys/` for the target shape:
//! `MnemonicFfi`, `SeedFfi`, `ExtendedKeyFfi`, `PublicKeyFfi`, `PrivateKeyFfi`.

mod extended_key;
mod mnemonic;
mod private_key;
mod public_key;
mod seed;

pub use extended_key::ExtendedKeyFfi;
pub use mnemonic::MnemonicFfi;
pub use private_key::{PrivateKeyFfi, RecoverableSignatureFfi};
pub use public_key::PublicKeyFfi;
pub use seed::SeedFfi;
