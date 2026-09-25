//! `BitcoinNetworkFfi`: which Bitcoin network an address/descriptor/PSBT
//! belongs to. Kept local to `blockchain_clients::bitcoin` rather than
//! threaded through `common::BlockchainFfi` — `BlockchainFfi::Bitcoin`
//! still carries no network payload (pre-existing; the Swift
//! `Blockchain.raw`/`init(raw:)` round-trip always assumes mainnet,
//! tracked for a fix alongside the Swift `Networks.swift` work). Every
//! Bitcoin-specific FFI entry point below takes network explicitly instead.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BitcoinNetworkFfi {
    Mainnet,
    Testnet,
    Signet,
    Regtest,
}

impl From<BitcoinNetworkFfi> for bitcoin::Network {
    fn from(value: BitcoinNetworkFfi) -> Self {
        match value {
            BitcoinNetworkFfi::Mainnet => bitcoin::Network::Bitcoin,
            BitcoinNetworkFfi::Testnet => bitcoin::Network::Testnet,
            BitcoinNetworkFfi::Signet => bitcoin::Network::Signet,
            BitcoinNetworkFfi::Regtest => bitcoin::Network::Regtest,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_network_maps_to_a_distinct_bitcoin_network() {
        let mapped: Vec<bitcoin::Network> = [
            BitcoinNetworkFfi::Mainnet,
            BitcoinNetworkFfi::Testnet,
            BitcoinNetworkFfi::Signet,
            BitcoinNetworkFfi::Regtest,
        ]
        .into_iter()
        .map(bitcoin::Network::from)
        .collect();
        assert_eq!(mapped, vec![
            bitcoin::Network::Bitcoin,
            bitcoin::Network::Testnet,
            bitcoin::Network::Signet,
            bitcoin::Network::Regtest,
        ]);
    }
}
