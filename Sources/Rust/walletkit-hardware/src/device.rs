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
    /// `call_value` is native TRX (in SUN) sent along with the call.
    TriggerSmartContract { owner_address: Vec<u8>, contract_address: Vec<u8>, call_value: Option<u64>, data: Vec<u8> },
    /// Stake 2.0 stake (`FreezeBalanceV2Contract`): `balance` SUN for `resource`.
    FreezeBalanceV2 { owner_address: Vec<u8>, balance: u64, resource: TronResource },
    /// Stake 2.0 unstake (`UnfreezeBalanceV2Contract`).
    UnfreezeBalanceV2 { owner_address: Vec<u8>, balance: u64, resource: TronResource },
    /// Stake 2.0 withdrawal of expired unstakes (`WithdrawExpireUnfreezeContract`).
    WithdrawExpireUnfreeze { owner_address: Vec<u8> },
}

/// The `ResourceCode`s Trezor can stake for (it has no `TRON_POWER`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TronResource {
    Bandwidth,
    Energy,
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

/// Largest fee, amount or collateral Trezor accepts (45bn ADA).
const CARDANO_LOVELACE_MAX_SUPPLY: u64 = 45_000_000_000 * 1_000_000;
const CARDANO_KEY_HASH_SIZE: usize = 28;
const CARDANO_HASH_SIZE: usize = 32;
const CARDANO_MULTISIG_PURPOSE: u32 = 1854;
const CARDANO_MINT_PURPOSE: u32 = 1855;
/// Trezor hashes a 28-byte non-ASCII payload as a hash and refuses it.
const CARDANO_HASHED_PAYLOAD_SIZE: usize = 28;

/// How Trezor's firmware treats a Cardano transaction; picked from content
/// by `CardanoDappTxRequest::signing_mode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CardanoSigningMode {
    Multisig,
    Ordinary,
    Plutus,
}

/// A stake/reward credential: derived on-device from `Path`, or given as a
/// hash (foreign key or script).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CardanoCredential {
    KeyHash(Vec<u8>),
    Path(Vec<HardwarePathSegment>),
    ScriptHash(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CardanoDRep {
    Abstain,
    KeyHash(Vec<u8>),
    NoConfidence,
    ScriptHash(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CardanoCertificateKind {
    StakeDelegation,
    StakeDeregistration,
    StakeDeregistrationConway,
    StakeRegistration,
    StakeRegistrationConway,
    /// A certificate the firmware can't sign (pool, committee, DRep, ...).
    Unsupported { name: String },
    VoteDelegation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoCertificate {
    pub credential: CardanoCredential,
    /// Conway registration/deregistration refund or deposit.
    pub deposit: Option<u64>,
    pub drep: Option<CardanoDRep>,
    pub kind: CardanoCertificateKind,
    /// Pool key hash of a stake delegation.
    pub pool: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoWithdrawal {
    pub amount: u64,
    pub credential: CardanoCredential,
}

/// A datum attached to an output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CardanoDatum {
    Hash(Vec<u8>),
    /// CBOR of the datum (the content of the tag-24 byte string).
    Inline(Vec<u8>),
}

/// An output of a dApp transaction. Assets are grouped by policy in order of
/// first appearance, so pass them in the original body order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoDappOutput {
    pub address: String,
    pub assets: Vec<CardanoAsset>,
    pub datum: Option<CardanoDatum>,
    pub lovelace: u64,
    /// Serialized as a post-Alonzo (map) output. Implied by a datum
    /// of the inline kind or a reference script.
    pub post_alonzo: bool,
    /// CBOR of the reference script (the content of the tag-24 byte string).
    pub reference_script: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoMintToken {
    pub amount: i64,
    pub name: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoMintGroup {
    pub policy_id: Vec<u8>,
    pub tokens: Vec<CardanoMintToken>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CardanoRequiredSigner {
    KeyHash(Vec<u8>),
    Path(Vec<HardwarePathSegment>),
}

/// A dApp (CIP-30) Cardano transaction presented to the device. Every field
/// the body carries must be here: the device re-serializes the body from
/// them, and the host compares the device-reported hash with the original.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoDappTxRequest {
    pub auxiliary_data_hash: Option<Vec<u8>>,
    pub certificates: Vec<CardanoCertificate>,
    pub collateral_inputs: Vec<CardanoTxInput>,
    pub collateral_return: Option<CardanoDappOutput>,
    pub fee: u64,
    /// The body carries an explicit network id (key 15).
    pub include_network_id: bool,
    pub inputs: Vec<CardanoTxInput>,
    pub mint: Vec<CardanoMintGroup>,
    pub network_id: u8,
    pub outputs: Vec<CardanoDappOutput>,
    pub protocol_magic: u32,
    pub reference_inputs: Vec<CardanoTxInput>,
    pub required_signers: Vec<CardanoRequiredSigner>,
    pub script_data_hash: Option<Vec<u8>>,
    /// Sets are serialized with tag 258.
    pub tag_cbor_sets: bool,
    pub total_collateral: Option<u64>,
    pub ttl: Option<u64>,
    /// Names of body items the firmware can't sign (voting procedures,
    /// proposals, treasury fields, ...). Any entry rejects the request.
    pub unsupported_content: Vec<String>,
    /// `invalid_before`.
    pub validity_start: Option<u64>,
    pub withdrawals: Vec<CardanoWithdrawal>,
    pub witness_paths: Vec<Vec<HardwarePathSegment>>,
}

/// Result of a dApp transaction signature. `body_hash` is the hash of the
/// body the device streamed back; the caller must compare it with the hash of
/// the dApp's original body before using `witnesses`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoDappTxSignature {
    pub body_hash: Vec<u8>,
    pub witnesses: Vec<CardanoWitness>,
}

/// Content the firmware can't sign, found before any device prompt.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CardanoTxRejection {
    #[error("invalid {field}")]
    Invalid { field: String },
    #[error("unsupported {item}")]
    Unsupported { item: String },
}

impl From<CardanoTxRejection> for HardwareError {
    fn from(rejection: CardanoTxRejection) -> Self {
        HardwareError::UnsupportedDevice { reason: format!("Trezor can't sign this Cardano transaction: {rejection}") }
    }
}

fn is_purpose(path: &[HardwarePathSegment], purpose: u32) -> bool {
    path.first().is_some_and(|segment| segment.hardened && segment.index == purpose)
}

impl CardanoDappTxRequest {
    fn has_plutus_content(&self) -> bool {
        self.script_data_hash.is_some()
            || !self.collateral_inputs.is_empty()
            || self.collateral_return.is_some()
            || self.total_collateral.is_some()
            || !self.reference_inputs.is_empty()
    }

    fn credentials(&self) -> impl Iterator<Item = &CardanoCredential> {
        self.certificates.iter().map(|certificate| &certificate.credential).chain(self.withdrawals.iter().map(|withdrawal| &withdrawal.credential))
    }

    /// Signing mode by content: Plutus fields select PLUTUS_TRANSACTION;
    /// otherwise script credentials or 1854' (multisig) witnesses select
    /// MULTISIG_TRANSACTION; everything else is ORDINARY_TRANSACTION.
    pub fn signing_mode(&self) -> CardanoSigningMode {
        if self.has_plutus_content() {
            return CardanoSigningMode::Plutus;
        }
        let has_script_credential = self.credentials().any(|credential| matches!(credential, CardanoCredential::ScriptHash(_)));
        let has_multisig_witness = self.witness_paths.iter().any(|path| is_purpose(path, CARDANO_MULTISIG_PURPOSE));
        if has_script_credential || has_multisig_witness {
            CardanoSigningMode::Multisig
        } else {
            CardanoSigningMode::Ordinary
        }
    }

    /// Checks the request against what the firmware accepts in the chosen
    /// signing mode, returning that mode. Nothing has been sent to the
    /// device yet.
    pub fn validate(&self) -> Result<CardanoSigningMode, CardanoTxRejection> {
        fn invalid(field: &str) -> CardanoTxRejection {
            CardanoTxRejection::Invalid { field: field.to_string() }
        }
        fn hash_is(bytes: &[u8], size: usize) -> bool {
            bytes.len() == size
        }

        if let Some(item) = self.unsupported_content.first() {
            return Err(CardanoTxRejection::Unsupported { item: item.clone() });
        }
        if self.fee > CARDANO_LOVELACE_MAX_SUPPLY {
            return Err(invalid("fee"));
        }
        if self.total_collateral.is_some_and(|total| total > CARDANO_LOVELACE_MAX_SUPPLY) {
            return Err(invalid("total collateral"));
        }
        if self.inputs.is_empty() || self.outputs.is_empty() {
            return Err(invalid("inputs or outputs"));
        }
        if self.witness_paths.is_empty() {
            return Err(invalid("witness paths"));
        }
        for input in self.inputs.iter().chain(&self.collateral_inputs).chain(&self.reference_inputs) {
            if !hash_is(&input.tx_hash, CARDANO_HASH_SIZE) {
                return Err(invalid("input hash"));
            }
        }
        for output in self.outputs.iter().chain(&self.collateral_return) {
            Self::validate_output(output)?;
        }
        if let Some(output) = &self.collateral_return {
            if output.datum.is_some() || output.reference_script.is_some() {
                return Err(invalid("collateral return"));
            }
        }
        if self.script_data_hash.as_deref().is_some_and(|hash| !hash_is(hash, CARDANO_HASH_SIZE)) {
            return Err(invalid("script data hash"));
        }
        if self.auxiliary_data_hash.as_deref().is_some_and(|hash| !hash_is(hash, CARDANO_HASH_SIZE)) {
            return Err(invalid("auxiliary data hash"));
        }
        for group in &self.mint {
            if !hash_is(&group.policy_id, CARDANO_KEY_HASH_SIZE) || group.tokens.is_empty() || group.tokens.iter().any(|token| token.name.len() > 32) {
                return Err(invalid("mint"));
            }
        }
        for signer in &self.required_signers {
            if let CardanoRequiredSigner::KeyHash(hash) = signer {
                if !hash_is(hash, CARDANO_KEY_HASH_SIZE) {
                    return Err(invalid("required signer"));
                }
            }
        }
        for certificate in &self.certificates {
            Self::validate_certificate(certificate)?;
        }
        for withdrawal in &self.withdrawals {
            Self::validate_credential(&withdrawal.credential).map_err(|_| invalid("withdrawal"))?;
        }

        let mode = self.signing_mode();
        match mode {
            CardanoSigningMode::Ordinary => {
                // Firmware: ordinary transactions take only path-derived stake credentials.
                if self.credentials().any(|credential| !matches!(credential, CardanoCredential::Path(_))) {
                    return Err(CardanoTxRejection::Unsupported { item: "foreign stake credential in a non-Plutus transaction".to_string() });
                }
            }
            CardanoSigningMode::Multisig => {
                if self.credentials().any(|credential| !matches!(credential, CardanoCredential::ScriptHash(_))) {
                    return Err(CardanoTxRejection::Unsupported { item: "mixed script and key credentials in a non-Plutus transaction".to_string() });
                }
                let only_multisig = self.witness_paths.iter().all(|path| is_purpose(path, CARDANO_MULTISIG_PURPOSE) || (is_purpose(path, CARDANO_MINT_PURPOSE) && !self.mint.is_empty()));
                if !only_multisig {
                    return Err(CardanoTxRejection::Unsupported { item: "non-multisig witness in a multisig transaction".to_string() });
                }
            }
            CardanoSigningMode::Plutus => {}
        }
        Ok(mode)
    }

    fn validate_output(output: &CardanoDappOutput) -> Result<(), CardanoTxRejection> {
        let invalid = || CardanoTxRejection::Invalid { field: "output".to_string() };
        if output.address.is_empty() || output.lovelace > CARDANO_LOVELACE_MAX_SUPPLY {
            return Err(invalid());
        }
        if output.assets.iter().any(|asset| asset.policy_id.len() != CARDANO_KEY_HASH_SIZE || asset.name.len() > 32) {
            return Err(invalid());
        }
        match &output.datum {
            Some(CardanoDatum::Hash(hash)) if hash.len() != CARDANO_HASH_SIZE => return Err(invalid()),
            Some(CardanoDatum::Inline(data)) if data.is_empty() || !output.post_alonzo => return Err(invalid()),
            _ => {}
        }
        if let Some(script) = &output.reference_script {
            if script.is_empty() || !output.post_alonzo {
                return Err(invalid());
            }
        }
        Ok(())
    }

    fn validate_credential(credential: &CardanoCredential) -> Result<(), ()> {
        match credential {
            CardanoCredential::KeyHash(hash) | CardanoCredential::ScriptHash(hash) if hash.len() == CARDANO_KEY_HASH_SIZE => Ok(()),
            CardanoCredential::Path(path) if !path.is_empty() => Ok(()),
            _ => Err(()),
        }
    }

    fn validate_certificate(certificate: &CardanoCertificate) -> Result<(), CardanoTxRejection> {
        let invalid = || CardanoTxRejection::Invalid { field: "certificate".to_string() };
        if let CardanoCertificateKind::Unsupported { name } = &certificate.kind {
            return Err(CardanoTxRejection::Unsupported { item: format!("{name} certificate") });
        }
        Self::validate_credential(&certificate.credential).map_err(|_| invalid())?;
        match certificate.kind {
            CardanoCertificateKind::StakeDelegation if certificate.pool.as_ref().is_none_or(|pool| pool.len() != CARDANO_KEY_HASH_SIZE) => Err(invalid()),
            CardanoCertificateKind::StakeRegistrationConway | CardanoCertificateKind::StakeDeregistrationConway if certificate.deposit.is_none() => Err(invalid()),
            CardanoCertificateKind::VoteDelegation => match &certificate.drep {
                None => Err(invalid()),
                Some(CardanoDRep::KeyHash(hash) | CardanoDRep::ScriptHash(hash)) if hash.len() != CARDANO_KEY_HASH_SIZE => Err(invalid()),
                Some(_) => Ok(()),
            },
            _ => Ok(()),
        }
    }
}

/// Which address a CIP-8 message header commits to, when it isn't the
/// signing key's own hash. Trezor accepts key-based types only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CardanoMessageAddressType {
    Base,
    BaseKeyScript,
    Enterprise,
    Reward,
}

/// Address derivation parameters of a CIP-8 message header address.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoMessageAddress {
    pub address_type: CardanoMessageAddressType,
    pub network_id: u8,
    pub path: Vec<HardwarePathSegment>,
    pub protocol_magic: u32,
    pub staking_key_hash: Option<Vec<u8>>,
    pub staking_path: Vec<HardwarePathSegment>,
}

/// CIP-8 `signData`: the raw `payload` is signed un-hashed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoMessageRequest {
    /// `None` signs for the key's own hash (CIP-8 reward/stake keys included).
    pub address: Option<CardanoMessageAddress>,
    pub payload: Vec<u8>,
    pub prefer_hex_display: bool,
    pub signing_path: Vec<HardwarePathSegment>,
}

/// What the device returned for a message. `address` is the header address
/// bytes the device signed; `pub_key` is the 32-byte signing key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardanoMessageSignature {
    pub address: Vec<u8>,
    pub pub_key: Vec<u8>,
    pub signature: Vec<u8>,
}

/// Reasons a message can't be signed raw. Never worked around by hashing
/// the payload. Maps to `HardwareError::SigningFailed` with a stable reason.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CardanoMessageError {
    #[error("empty signing path")]
    EmptySigningPath,
    #[error("payload is too large to stream ({size} bytes)")]
    PayloadTooLarge { size: usize },
    #[error("the device refuses a non-ASCII 28-byte payload (it reads it as a hash)")]
    PayloadLooksHashed,
}

impl From<CardanoMessageError> for HardwareError {
    fn from(error: CardanoMessageError) -> Self {
        HardwareError::SigningFailed { reason: format!("Trezor can't sign this Cardano message: {error}") }
    }
}

impl CardanoMessageRequest {
    /// Checks what the firmware would refuse, before any device prompt.
    pub fn validate(&self) -> Result<(), CardanoMessageError> {
        if self.signing_path.is_empty() {
            return Err(CardanoMessageError::EmptySigningPath);
        }
        if u32::try_from(self.payload.len()).is_err() {
            return Err(CardanoMessageError::PayloadTooLarge { size: self.payload.len() });
        }
        if self.payload.len() == CARDANO_HASHED_PAYLOAD_SIZE && !self.payload.iter().all(|byte| (0x20..0x7f).contains(byte)) {
            return Err(CardanoMessageError::PayloadLooksHashed);
        }
        Ok(())
    }

    /// The `(length, offset)` slices of a device data request, or `None` when
    /// it reaches past the payload.
    pub fn chunk(&self, length: u32, offset: u32) -> Option<&[u8]> {
        let end = (offset as usize).checked_add(length as usize)?;
        self.payload.get(offset as usize..end)
    }
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

    /// Signs a Tron `TransferContract`, `TriggerSmartContract` or Stake 2.0
    /// stake/unstake/withdraw on-device.
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

    /// Signs a dApp Cardano transaction with certificates, withdrawals,
    /// Plutus fields, mint and the rest. Rejects firmware-unsupported content
    /// before any prompt; the caller compares `body_hash` with the original.
    async fn cardano_sign_dapp_tx(&self, request: CardanoDappTxRequest) -> Result<CardanoDappTxSignature, HardwareError>;

    /// Signs a CIP-8 message (`signData`) over the raw payload.
    async fn cardano_sign_message(&self, request: CardanoMessageRequest) -> Result<CardanoMessageSignature, HardwareError>;

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

#[cfg(test)]
mod cardano_tests {
    use super::*;

    fn seg(index: u32, hardened: bool) -> HardwarePathSegment {
        HardwarePathSegment { index, hardened }
    }

    fn shelley_path() -> Vec<HardwarePathSegment> {
        vec![seg(1852, true), seg(1815, true), seg(0, true), seg(0, false), seg(0, false)]
    }

    fn stake_path() -> Vec<HardwarePathSegment> {
        vec![seg(1852, true), seg(1815, true), seg(0, true), seg(2, false), seg(0, false)]
    }

    fn output() -> CardanoDappOutput {
        CardanoDappOutput {
            address: "addr1qx".to_string(),
            assets: vec![],
            datum: None,
            lovelace: 1_000_000,
            post_alonzo: false,
            reference_script: None,
        }
    }

    fn request() -> CardanoDappTxRequest {
        CardanoDappTxRequest {
            auxiliary_data_hash: None,
            certificates: vec![],
            collateral_inputs: vec![],
            collateral_return: None,
            fee: 170_000,
            include_network_id: false,
            inputs: vec![CardanoTxInput { output_index: 0, tx_hash: vec![1; 32] }],
            mint: vec![],
            network_id: 1,
            outputs: vec![output()],
            protocol_magic: 764_824_073,
            reference_inputs: vec![],
            required_signers: vec![],
            script_data_hash: None,
            tag_cbor_sets: false,
            total_collateral: None,
            ttl: Some(100),
            unsupported_content: vec![],
            validity_start: None,
            withdrawals: vec![],
            witness_paths: vec![shelley_path()],
        }
    }

    fn delegation(credential: CardanoCredential) -> CardanoCertificate {
        CardanoCertificate { credential, deposit: None, drep: None, kind: CardanoCertificateKind::StakeDelegation, pool: Some(vec![9; 28]) }
    }

    #[test]
    fn plain_transfer_is_ordinary() {
        assert_eq!(request().validate(), Ok(CardanoSigningMode::Ordinary));
    }

    #[test]
    fn owned_stake_certificates_and_withdrawals_stay_ordinary() {
        let mut tx = request();
        tx.certificates = vec![delegation(CardanoCredential::Path(stake_path()))];
        tx.withdrawals = vec![CardanoWithdrawal { amount: 5, credential: CardanoCredential::Path(stake_path()) }];
        tx.mint = vec![CardanoMintGroup { policy_id: vec![2; 28], tokens: vec![CardanoMintToken { amount: -1, name: vec![1] }] }];
        tx.validity_start = Some(7);
        assert_eq!(tx.validate(), Ok(CardanoSigningMode::Ordinary));
    }

    #[test]
    fn each_plutus_field_selects_plutus() {
        let cases: Vec<fn(&mut CardanoDappTxRequest)> = vec![
            |tx| tx.script_data_hash = Some(vec![3; 32]),
            |tx| tx.collateral_inputs = vec![CardanoTxInput { output_index: 1, tx_hash: vec![4; 32] }],
            |tx| tx.collateral_return = Some(output()),
            |tx| tx.total_collateral = Some(5_000_000),
            |tx| tx.reference_inputs = vec![CardanoTxInput { output_index: 0, tx_hash: vec![5; 32] }],
        ];
        for apply in cases {
            let mut tx = request();
            apply(&mut tx);
            assert_eq!(tx.validate(), Ok(CardanoSigningMode::Plutus));
        }
    }

    #[test]
    fn plutus_allows_foreign_credentials() {
        let mut tx = request();
        tx.script_data_hash = Some(vec![3; 32]);
        tx.certificates = vec![delegation(CardanoCredential::ScriptHash(vec![6; 28]))];
        tx.withdrawals = vec![CardanoWithdrawal { amount: 1, credential: CardanoCredential::KeyHash(vec![7; 28]) }];
        assert_eq!(tx.validate(), Ok(CardanoSigningMode::Plutus));
    }

    #[test]
    fn script_credentials_with_multisig_witness_select_multisig() {
        let mut tx = request();
        tx.certificates = vec![delegation(CardanoCredential::ScriptHash(vec![6; 28]))];
        tx.witness_paths = vec![vec![seg(1854, true), seg(1815, true), seg(0, true), seg(0, false), seg(0, false)]];
        assert_eq!(tx.validate(), Ok(CardanoSigningMode::Multisig));
    }

    #[test]
    fn multisig_rejects_shelley_witness() {
        let mut tx = request();
        tx.withdrawals = vec![CardanoWithdrawal { amount: 1, credential: CardanoCredential::ScriptHash(vec![6; 28]) }];
        assert!(matches!(tx.validate(), Err(CardanoTxRejection::Unsupported { .. })));
    }

    #[test]
    fn ordinary_rejects_foreign_stake_credential() {
        let mut tx = request();
        tx.certificates = vec![delegation(CardanoCredential::KeyHash(vec![7; 28]))];
        assert!(matches!(tx.validate(), Err(CardanoTxRejection::Unsupported { .. })));
    }

    #[test]
    fn rejects_unsupported_content_and_certificates() {
        let mut tx = request();
        tx.unsupported_content = vec!["voting procedures".to_string()];
        assert_eq!(tx.validate(), Err(CardanoTxRejection::Unsupported { item: "voting procedures".to_string() }));

        let mut tx = request();
        let mut certificate = delegation(CardanoCredential::Path(stake_path()));
        certificate.kind = CardanoCertificateKind::Unsupported { name: "pool retirement".to_string() };
        tx.certificates = vec![certificate];
        assert_eq!(tx.validate(), Err(CardanoTxRejection::Unsupported { item: "pool retirement certificate".to_string() }));
    }

    #[test]
    fn rejects_malformed_fields() {
        let mut tx = request();
        tx.inputs[0].tx_hash = vec![1; 31];
        assert!(tx.validate().is_err());

        let mut tx = request();
        tx.outputs[0].datum = Some(CardanoDatum::Inline(vec![1]));
        assert!(tx.validate().is_err(), "inline datum needs the post-Alonzo format");
        tx.outputs[0].post_alonzo = true;
        assert!(tx.validate().is_ok());

        let mut tx = request();
        tx.outputs[0].datum = Some(CardanoDatum::Hash(vec![1; 31]));
        assert!(tx.validate().is_err());

        let mut tx = request();
        tx.collateral_return = Some(CardanoDappOutput { datum: Some(CardanoDatum::Hash(vec![1; 32])), ..output() });
        assert!(tx.validate().is_err(), "collateral return can't carry a datum");

        let mut tx = request();
        tx.certificates = vec![CardanoCertificate { kind: CardanoCertificateKind::StakeRegistrationConway, deposit: None, pool: None, ..delegation(CardanoCredential::Path(stake_path())) }];
        assert!(tx.validate().is_err(), "Conway registration needs a deposit");

        let mut tx = request();
        tx.witness_paths.clear();
        assert!(tx.validate().is_err());
    }

    fn message(payload: Vec<u8>) -> CardanoMessageRequest {
        CardanoMessageRequest { address: None, payload, prefer_hex_display: false, signing_path: shelley_path() }
    }

    #[test]
    fn message_chunks_follow_device_requests() {
        let request = message((0..10).collect());
        assert_eq!(request.chunk(10, 0), Some(&(0..10).collect::<Vec<u8>>()[..]));
        assert_eq!(request.chunk(4, 3), Some(&[3, 4, 5, 6][..]));
        assert_eq!(request.chunk(0, 10), Some(&[][..]));
        assert_eq!(request.chunk(4, 8), None);
        assert_eq!(request.chunk(u32::MAX, u32::MAX), None);
    }

    #[test]
    fn message_validation_never_hashes() {
        assert_eq!(message(vec![]).validate(), Ok(()));
        assert_eq!(message(b"hello".to_vec()).validate(), Ok(()));
        assert_eq!(message(vec![0xff; 28]).validate(), Err(CardanoMessageError::PayloadLooksHashed));
        assert_eq!(message(vec![b'a'; 28]).validate(), Ok(()));
        assert_eq!(message(vec![0xff; 29]).validate(), Ok(()));
        let mut empty_path = message(vec![1]);
        empty_path.signing_path.clear();
        assert_eq!(empty_path.validate(), Err(CardanoMessageError::EmptySigningPath));
    }

    #[test]
    fn errors_map_to_hardware_errors() {
        assert!(matches!(HardwareError::from(CardanoMessageError::PayloadLooksHashed), HardwareError::SigningFailed { .. }));
        assert!(matches!(HardwareError::from(CardanoTxRejection::Unsupported { item: "x".to_string() }), HardwareError::UnsupportedDevice { .. }));
    }
}
