use async_trait::async_trait;

use crate::{error::HardwareError, info::HardwareDeviceInfo, path::HardwarePathSegment};

/// The elliptic curve to derive a hardware-sourced public key under.
/// Mirrors `walletkit-ffi`'s `common::Curve` so vendor crates don't need to
/// depend on `walletkit-ffi`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HardwareCurve {
    Secp256k1,
    Ed25519,
}

/// The structured fields of an unsigned Ethereum transaction a hardware
/// device's trusted screen needs to display before it signs — the same
/// six semantic fields plus `chainId` `EthereumSignerFfi::decode_signing_data`
/// recovers from EIP-155 RLP. Every integer field is a big-endian byte
/// string with no leading zero byte (empty means zero), matching the wire
/// encoding hardware wallet protocols expect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthereumTxFields {
    pub nonce: Vec<u8>,
    pub gas_price: Vec<u8>,
    pub gas_limit: Vec<u8>,
    pub to: Option<Vec<u8>>,
    pub value: Vec<u8>,
    pub data: Vec<u8>,
    pub chain_id: u64,
}

/// An EIP-155 signature, in the shape a hardware device returns it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthereumSignature {
    pub v: u64,
    pub r: Vec<u8>,
    pub s: Vec<u8>,
}

/// The structured fields of an unsigned EIP-1559 (type-2) Ethereum transaction
/// a hardware device's trusted screen needs to display. Every integer field is
/// a big-endian byte string with no leading zero byte (empty means zero).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthereumEIP1559TxFields {
    pub nonce: Vec<u8>,
    pub max_priority_fee_per_gas: Vec<u8>,
    pub max_fee_per_gas: Vec<u8>,
    pub gas_limit: Vec<u8>,
    pub to: Option<Vec<u8>>,
    pub value: Vec<u8>,
    pub data: Vec<u8>,
    pub chain_id: u64,
}

/// An EIP-1559 signature in the shape a hardware device returns it.
/// `y_parity` is the raw secp256k1 recovery id (0 or 1), without EIP-155 folding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthereumEIP1559Signature {
    pub y_parity: u64,
    pub r: Vec<u8>,
    pub s: Vec<u8>,
}

/// A Tron transfer or smart-contract call displayed and signed by a hardware
/// device. Addresses include Tron's `0x41` network byte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TronTxFields {
    pub ref_block_bytes: Vec<u8>,
    pub ref_block_hash: Vec<u8>,
    pub expiration: u64,
    pub timestamp: u64,
    pub fee_limit: Option<u64>,
    pub data: Option<Vec<u8>>,
    pub contract: TronContract,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TronContract {
    Transfer { owner_address: Vec<u8>, to_address: Vec<u8>, amount: u64 },
    TriggerSmartContract { owner_address: Vec<u8>, contract_address: Vec<u8>, data: Vec<u8> },
}

/// One token account referenced by a Solana transaction's instructions —
/// the base58 addresses a hardware device's trusted screen needs in order
/// to display an SPL transfer in terms of the mint/owner it moves, rather
/// than the opaque token-account address that actually appears on the
/// wire. Mirrors Trezor's `SolanaTxTokenAccountInfo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SolanaTokenAccountInfo {
    pub base_address: String,
    pub token_program: String,
    pub token_mint: String,
    pub token_account: String,
}

/// A Solana transaction displayed and signed by a hardware device.
/// `serialized_message` is the wire-format `Message` (header + account
/// keys + blockhash + compiled instructions) exactly as it will be
/// broadcast — Solana has no separate signing-hash step, the device signs
/// these bytes directly. `token_accounts` is empty for a native SOL
/// transfer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SolanaTxFields {
    pub serialized_message: Vec<u8>,
    pub token_accounts: Vec<SolanaTokenAccountInfo>,
}

/// Which Bitcoin network a `bitcoin_sign_psbt` call targets — mirrors
/// `walletkit-ffi`'s `blockchain_clients::bitcoin::BitcoinNetworkFfi` so
/// this crate doesn't need to depend on it (same reasoning as
/// `HardwareCurve` mirroring `common::Curve`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HardwareBitcoinNetwork {
    Mainnet,
    Testnet,
    Signet,
    Regtest,
}

/// A connected hardware wallet — a source of public keys and signatures,
/// read from / produced by the device rather than derived or computed
/// in-process.
#[async_trait]
pub trait HardwareDevice: Send + Sync {
    /// Static metadata describing this device.
    fn info(&self) -> HardwareDeviceInfo;

    /// Whether this device is still connected.
    fn is_connected(&self) -> bool;

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// Returns the key's raw bytes (compressed SEC1 for secp256k1); the
    /// caller already knows `curve`, since it supplied it.
    async fn public_key(
        &self,
        path: Vec<HardwarePathSegment>,
        curve: HardwareCurve,
    ) -> Result<Vec<u8>, HardwareError>;

    /// Signs an EIP-155 legacy Ethereum transaction on the device.
    async fn ethereum_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTxFields,
    ) -> Result<EthereumSignature, HardwareError>;

    /// Signs an EIP-1559 (type-2) Ethereum transaction on the device, showing
    /// `fields` on its trusted screen for the user to confirm. `y_parity` in
    /// the returned signature is 0 or 1 (no EIP-155 folding).
    async fn ethereum_sign_tx_eip1559(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumEIP1559TxFields,
    ) -> Result<EthereumEIP1559Signature, HardwareError>;

    /// Signs a Tron `TransferContract` or `TriggerSmartContract` on-device.
    async fn tron_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: TronTxFields,
    ) -> Result<Vec<u8>, HardwareError>;

    /// Signs a Solana transaction message on-device, returning the raw
    /// 64-byte ed25519 signature over `fields.serialized_message`.
    async fn solana_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: SolanaTxFields,
    ) -> Result<Vec<u8>, HardwareError>;

    /// Reads the account-level extended public key (xpub, including its
    /// chain code) at `path` from the device, Base58Check-encoded with
    /// mainnet (`xpub`) version bytes regardless of which Bitcoin network
    /// `path` is actually for.
    ///
    /// Unlike `public_key`, which only returns the raw key at one exact
    /// path, this carries enough material to build a `BitcoinDescriptor`
    /// capable of deriving every external/change address under `path`
    /// without a further device round-trip. Always mainnet-serialized
    /// because `walletkit-ffi`'s own `ExtendedKeyFfi::from_serialized`
    /// only recognizes `xpub`/`xprv` version bytes, never `tpub`/`tprv` —
    /// the same reason `BitcoinDescriptorFfi::from_xpub` doesn't validate
    /// its xpub's version bytes against the caller's requested network.
    async fn bitcoin_xpub(&self, path: Vec<HardwarePathSegment>) -> Result<String, HardwareError>;

    /// Signs a Bitcoin PSBT (built by `bitcoin_build_unsigned_psbt`) on
    /// the device via its interactive `SignTx`/`TxRequest`/`TxAck` flow,
    /// driven entirely from the PSBT's own `witness_utxo`/
    /// `bip32_derivation`/`tap_key_origins` fields — no separate
    /// per-input key material is needed, unlike the software signer.
    ///
    /// Returns the finalized, consensus-serialized raw transaction: the
    /// device streams the fully signed transaction back directly as it
    /// completes, rather than per-input signatures, so no separate
    /// finalize step is needed the way `BitcoinSignerFfi::sign_psbt` +
    /// `finalize_psbt` need one for a software-derived key.
    async fn bitcoin_sign_psbt(
        &self,
        psbt: Vec<u8>,
        network: HardwareBitcoinNetwork,
    ) -> Result<Vec<u8>, HardwareError>;

    /// Disconnects from this device.
    async fn disconnect(&self);
}
