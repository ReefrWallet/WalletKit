//! Bitcoin address/descriptor encoding, PSBT assembly, and signing.
//! Built directly on the `bitcoin` crate's own `Address`/`Xpub`/`Psbt`/
//! `SighashCache` types rather than a hand-rolled implementation of any
//! of BIP-32/BIP-84/BIP-86/BIP-143/BIP-174/BIP-341 — see each submodule's
//! docs for exactly which pieces are ours (descriptor text parsing,
//! gluing a per-address key to the right input) versus the crate's own
//! (encoding, sighash math, the taproot key tweak).

mod address;
mod descriptor;
mod network;
mod psbt;
mod signer;

pub use address::BitcoinAddressFfi;
pub use descriptor::{BitcoinDescriptorFfi, BitcoinScriptTypeFfi};
pub use network::BitcoinNetworkFfi;
pub use psbt::{bitcoin_build_unsigned_psbt, bitcoin_estimate_vsize, BitcoinInputKindFfi, BitcoinPsbtInputFfi, BitcoinPsbtOutputFfi};
pub use signer::BitcoinSignerFfi;
