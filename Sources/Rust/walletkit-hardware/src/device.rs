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

/// The fields of an EIP-712 typed-data payload a hardware device's
/// trusted screen needs — the wire-format `types`/`domain`/`message`
/// sub-objects verbatim as JSON (so a device driver can walk them without
/// any EIP-712 knowledge of its own), plus the two hashes that combine
/// into the EIP-712 signing hash (`domain_separator_hash`, `message_hash`),
/// which Trezor One's `EthereumSignTypedHash` fallback needs directly —
/// its firmware doesn't implement the full struct/value walk
/// `EthereumSignTypedData` requires on Model T/Safe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthereumTypedDataFields {
    pub primary_type: String,
    pub types_json: String,
    pub domain_json: String,
    pub message_json: String,
    pub domain_separator_hash: Vec<u8>,
    pub message_hash: Vec<u8>,
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

/// A Cardano transaction as Trezor's streamed signing protocol presents it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoTxFields {
    /// Blake2b-256 hash of the canonical transaction body the host built.
    /// The device returns the same hash after its streamed reconstruction.
    pub body_hash: Vec<u8>,
    pub fee: u64,
    pub inputs: Vec<CardanoTxInput>,
    pub network_id: u8,
    pub outputs: Vec<CardanoTxOutput>,
    pub protocol_magic: u32,
    pub ttl: Option<u64>,
    pub witness_paths: Vec<Vec<HardwarePathSegment>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoTxInput {
    pub output_index: u32,
    pub tx_hash: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoTxOutput {
    pub address: String,
    pub assets: Vec<CardanoAsset>,
    pub lovelace: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoAsset {
    pub name: Vec<u8>,
    pub policy_id: Vec<u8>,
    pub quantity: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoWitness {
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
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

    /// Signs an EIP-191 personal message on-device, returning the 65-byte
    /// `r ‖ s ‖ v` signature (legacy 27/28 `v`, no EIP-155 folding)
    /// `personal_sign` expects.
    async fn ethereum_sign_message(
        &self,
        path: Vec<HardwarePathSegment>,
        message: Vec<u8>,
    ) -> Result<EthereumSignature, HardwareError>;

    /// Signs an EIP-712 typed-data payload on-device — the full
    /// interactive `EthereumSignTypedData` struct/value walk on Trezor
    /// Model T/Safe, or `EthereumSignTypedHash` (over the two hashes
    /// `fields` already carries) on Trezor One. Returns the same 65-byte
    /// `r ‖ s ‖ v` shape as `ethereum_sign_message`.
    async fn ethereum_sign_typed_data(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTypedDataFields,
    ) -> Result<EthereumSignature, HardwareError>;

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

    /// Signs a Solana off-chain message (OCMS v1) on-device. The firmware
    /// takes structured data — a UTF-8 `message` and the 32-byte `signers`
    /// public keys (which must include the key at `path`) — and signs its
    /// own serialization (`\xffsolana offchain` ‖ version ‖ signer count ‖
    /// signers ‖ message), not the raw text. Returns the raw 64-byte
    /// ed25519 signature.
    async fn solana_sign_message(
        &self,
        path: Vec<HardwarePathSegment>,
        message: String,
        signers: Vec<Vec<u8>>,
    ) -> Result<Vec<u8>, HardwareError>;

    /// Reads the Cardano Icarus/CIP-1852 account extended public key.
    async fn cardano_xpub(&self, path: Vec<HardwarePathSegment>) -> Result<String, HardwareError>;

    /// Signs a structured Cardano transaction and returns verification-key witnesses.
    async fn cardano_sign_tx(&self, fields: CardanoTxFields) -> Result<Vec<CardanoWitness>, HardwareError>;

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
