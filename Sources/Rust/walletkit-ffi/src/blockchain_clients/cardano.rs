//! Cardano CIP-1852 account and Shelley address primitives.
//!
//! Cardano uses Icarus Ed25519-BIP32, which is intentionally distinct from
//! the SLIP-0010 Ed25519 tree used by Solana and Sui in this crate.

use blake2::digest::consts::U32;
use blake2::{Blake2b, Digest};
use cardano_serialization_lib::{
    make_vkey_witness, Address, BaseAddress, BigNum, Bip32PrivateKey, Bip32PublicKey,
    min_ada_for_output, AssetName, Assets, Certificate, CertificatesBuilder, ChangeConfig, CoinSelectionStrategyCIP2, Credential,
    DRep, DataCost, Ed25519KeyHash, LinearFee, MultiAsset, RewardAddress, ScriptHash, StakeDelegation,
    StakeDeregistration, StakeRegistration, Transaction, TransactionBody, VoteDelegation, WithdrawalsBuilder,
    TransactionBuilder, TransactionBuilderConfigBuilder, TransactionHash, TransactionInput,
    Ed25519Signature, PublicKey, TransactionOutput, TransactionUnspentOutput, TransactionUnspentOutputs,
    TransactionWitnessSet, Value, Vkey, Vkeywitness, Vkeywitnesses,
};

use crate::errors::WalletKitErrorFfi;

const HARDENED: u32 = 0x8000_0000;
const CARDANO_COIN_TYPE: u32 = 1815;
const CIP1852_PURPOSE: u32 = 1852;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoSigningPathFfi {
    pub index: u32,
    pub role: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoAssetFfi {
    pub name: Vec<u8>,
    pub policy_id: Vec<u8>,
    pub quantity: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoUtxoFfi {
    pub address: String,
    pub assets: Vec<CardanoAssetFfi>,
    pub lovelace: String,
    pub output_index: u32,
    pub tx_hash: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoProtocolParametersFfi {
    pub coins_per_utxo_byte: u64,
    pub key_deposit: u64,
    pub max_tx_size: u32,
    pub max_value_size: u32,
    pub min_fee_a: u64,
    pub min_fee_b: u64,
    pub pool_deposit: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoUnsignedTransactionFfi {
    pub fee: String,
    pub inputs: Vec<CardanoTransactionInputFfi>,
    pub network_id: u8,
    pub outputs: Vec<CardanoTransactionOutputFfi>,
    pub signing_paths: Vec<CardanoSigningPathFfi>,
    pub transaction_body: Vec<u8>,
    pub ttl: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoTransactionInputFfi {
    pub output_index: u32,
    pub tx_hash: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoTransactionOutputFfi {
    pub address: String,
    pub assets: Vec<CardanoAssetFfi>,
    pub is_change: bool,
    pub lovelace: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoWitnessFfi {
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

pub(crate) fn invalid_address(reason: impl ToString) -> WalletKitErrorFfi {
    WalletKitErrorFfi::InvalidAddress {
        reason: reason.to_string(),
    }
}

pub(crate) fn signing_failed(reason: impl ToString) -> WalletKitErrorFfi {
    WalletKitErrorFfi::SigningFailed {
        reason: reason.to_string(),
    }
}

pub(crate) fn account_public_key(entropy: &[u8], account_index: u32) -> Bip32PublicKey {
    Bip32PrivateKey::from_bip39_entropy(entropy, &[])
        .derive(CIP1852_PURPOSE | HARDENED)
        .derive(CARDANO_COIN_TYPE | HARDENED)
        .derive(account_index | HARDENED)
        .to_public()
}

/// Trezor's Cardano protocol returns the 64-byte account extended public key
/// as hexadecimal, while CSL uses bech32. Accept both forms at the boundary
/// and keep WalletKit's stored descriptor representation canonical.
pub(crate) fn normalize_account_xpub(account_xpub: &str) -> Result<String, WalletKitErrorFfi> {
    if let Ok(account) = Bip32PublicKey::from_bech32(account_xpub) {
        return Ok(account.to_bech32());
    }

    let bytes = hex::decode(account_xpub).map_err(invalid_address)?;
    Bip32PublicKey::from_bytes(&bytes)
        .map(|account| account.to_bech32())
        .map_err(invalid_address)
}

/// Returns the public CIP-1852 account key derived from BIP-39 entropy.
#[uniffi::export]
pub fn cardano_account_xpub_from_entropy(
    entropy: Vec<u8>,
    account_index: u32,
) -> Result<String, WalletKitErrorFfi> {
    if entropy.is_empty() {
        return Err(WalletKitErrorFfi::InvalidEntropy);
    }

    Ok(account_public_key(&entropy, account_index).to_bech32())
}

/// Derives a Shelley base address from a public CIP-1852 account key.
#[uniffi::export]
pub fn cardano_base_address(
    account_xpub: String,
    network_id: u8,
    payment_role: u32,
    payment_index: u32,
) -> Result<String, WalletKitErrorFfi> {
    let account = Bip32PublicKey::from_bech32(&normalize_account_xpub(&account_xpub)?).map_err(invalid_address)?;
    let payment = account
        .derive(payment_role)
        .map_err(invalid_address)?
        .derive(payment_index)
        .map_err(invalid_address)?
        .to_raw_key();
    let stake = account
        .derive(2)
        .map_err(invalid_address)?
        .derive(0)
        .map_err(invalid_address)?
        .to_raw_key();
    let payment = Credential::from_keyhash(&payment.hash());
    let stake = Credential::from_keyhash(&stake.hash());

    BaseAddress::new(network_id, &payment, &stake)
        .to_address()
        .to_bech32(None)
        .map_err(invalid_address)
}

/// Derives the reward account address for a public CIP-1852 account key.
#[uniffi::export]
pub fn cardano_stake_address(
    account_xpub: String,
    network_id: u8,
) -> Result<String, WalletKitErrorFfi> {
    let account = Bip32PublicKey::from_bech32(&normalize_account_xpub(&account_xpub)?).map_err(invalid_address)?;
    let stake = account
        .derive(2)
        .map_err(invalid_address)?
        .derive(0)
        .map_err(invalid_address)?
        .to_raw_key();
    let credential = Credential::from_keyhash(&stake.hash());

    RewardAddress::new(network_id, &credential)
        .to_address()
        .to_bech32(None)
        .map_err(invalid_address)
}

/// Signs a transaction body with the payment/change keys that own its inputs.
#[uniffi::export]
pub fn cardano_sign_transaction(
    entropy: Vec<u8>,
    account_index: u32,
    signing_paths: Vec<CardanoSigningPathFfi>,
    transaction_body: Vec<u8>,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    if entropy.is_empty() {
        return Err(WalletKitErrorFfi::InvalidEntropy);
    }
    if signing_paths.is_empty() {
        return Err(signing_failed("Cardano transaction has no signing paths"));
    }

    let body = TransactionBody::from_bytes(transaction_body).map_err(signing_failed)?;
    let digest = Blake2b::<U32>::digest(body.to_bytes());
    let body_hash = TransactionHash::from_bytes(digest.to_vec()).map_err(signing_failed)?;
    let account = Bip32PrivateKey::from_bip39_entropy(&entropy, &[])
        .derive(CIP1852_PURPOSE | HARDENED)
        .derive(CARDANO_COIN_TYPE | HARDENED)
        .derive(account_index | HARDENED);
    let mut witnesses = Vkeywitnesses::new();

    for path in signing_paths {
        let key = account.derive(path.role).derive(path.index).to_raw_key();
        witnesses.add(&make_vkey_witness(&body_hash, &key));
    }

    let mut witness_set = TransactionWitnessSet::new();
    witness_set.set_vkeys(&witnesses);
    Ok(Transaction::new(&body, &witness_set, None).to_bytes())
}

#[uniffi::export]
pub fn cardano_assemble_transaction(
    transaction_body: Vec<u8>,
    witnesses: Vec<CardanoWitnessFfi>,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    if witnesses.is_empty() {
        return Err(signing_failed("Cardano device returned no witnesses"));
    }
    let body = TransactionBody::from_bytes(transaction_body).map_err(signing_failed)?;
    let mut vkeys = Vkeywitnesses::new();
    for witness in witnesses {
        let key = PublicKey::from_bytes(&witness.public_key).map_err(signing_failed)?;
        let signature = Ed25519Signature::from_bytes(witness.signature).map_err(signing_failed)?;
        vkeys.add(&Vkeywitness::new(&Vkey::new(&key), &signature));
    }
    let mut witness_set = TransactionWitnessSet::new();
    witness_set.set_vkeys(&vkeys);
    Ok(Transaction::new(&body, &witness_set, None).to_bytes())
}

/// Wraps `transaction_body` with an empty witness set, the shape a device
/// signs through the transaction-level protocol.
#[uniffi::export]
pub fn cardano_unsigned_transaction(transaction_body: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let body = TransactionBody::from_bytes(transaction_body).map_err(signing_failed)?;
    Ok(Transaction::new(&body, &TransactionWitnessSet::new(), None).to_bytes())
}

/// Attaches a device-returned witness set to the canonical `transaction_body`.
#[uniffi::export]
pub fn cardano_assemble_with_witness_set(
    transaction_body: Vec<u8>,
    witness_set: Vec<u8>,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let body = TransactionBody::from_bytes(transaction_body).map_err(signing_failed)?;
    let witness_set = TransactionWitnessSet::from_bytes(witness_set).map_err(signing_failed)?;
    if witness_set.vkeys().map_or(true, |vkeys| vkeys.len() == 0) {
        return Err(signing_failed("Cardano device returned no witnesses"));
    }
    Ok(Transaction::new(&body, &witness_set, None).to_bytes())
}

/// Returns the Blake2b-256 transaction identifier a signer must authorize.
#[uniffi::export]
pub fn cardano_transaction_body_hash(transaction_body: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let body = TransactionBody::from_bytes(transaction_body).map_err(signing_failed)?;
    Ok(Blake2b::<U32>::digest(body.to_bytes()).to_vec())
}

/// Builds an ADA or native-asset transfer from `utxos`. `signing_paths` assumes
/// external address 0; callers spending from other addresses replace it.
#[uniffi::export]
pub fn cardano_build_transfer(
    amount: String,
    change_address: String,
    recipient_lovelace: String,
    protocol_parameters: CardanoProtocolParametersFfi,
    recipient: String,
    token: Option<CardanoAssetFfi>,
    utxos: Vec<CardanoUtxoFfi>,
) -> Result<CardanoUnsignedTransactionFfi, WalletKitErrorFfi> {
    let amount = BigNum::from_str(&amount).map_err(signing_failed)?;
    if amount.is_zero() {
        return Err(signing_failed(
            "Cardano transfer amount must be greater than zero",
        ));
    }
    let recipient = Address::from_bech32(&recipient).map_err(invalid_address)?;
    let change_address = Address::from_bech32(&change_address).map_err(invalid_address)?;
    let fee = LinearFee::new(
        &BigNum::from(protocol_parameters.min_fee_a),
        &BigNum::from(protocol_parameters.min_fee_b),
    );
    let config = TransactionBuilderConfigBuilder::new()
        .coins_per_utxo_byte(&BigNum::from(protocol_parameters.coins_per_utxo_byte))
        .fee_algo(&fee)
        .key_deposit(&BigNum::from(protocol_parameters.key_deposit))
        .max_tx_size(protocol_parameters.max_tx_size)
        .max_value_size(protocol_parameters.max_value_size)
        .pool_deposit(&BigNum::from(protocol_parameters.pool_deposit))
        .build()
        .map_err(signing_failed)?;
    let recipient_lovelace = BigNum::from_str(&recipient_lovelace).map_err(signing_failed)?;
    let token_value = token.map(|asset| multiasset_value(vec![asset])).transpose()?;
    let mut available = TransactionUnspentOutputs::new();
    for utxo in utxos {
        let address = Address::from_bech32(&utxo.address).map_err(invalid_address)?;
        let tx_hash = TransactionHash::from_bytes(utxo.tx_hash).map_err(signing_failed)?;
        let input = TransactionInput::new(&tx_hash, utxo.output_index);
        let mut value = Value::new(&BigNum::from_str(&utxo.lovelace).map_err(signing_failed)?);
        if !utxo.assets.is_empty() {
            value.set_multiasset(&multiasset(utxo.assets)?);
        }
        let output = TransactionOutput::new(&address, &value);
        available.add(&TransactionUnspentOutput::new(&input, &output));
    }

    let mut builder = TransactionBuilder::new(&config);
    let mut recipient_value = Value::new(&if token_value.is_some() { recipient_lovelace } else { amount.clone() });
    if let Some(token_value) = token_value {
        recipient_value.set_multiasset(&token_value);
    }
    builder
        .add_output(&TransactionOutput::new(&recipient, &recipient_value))
        .map_err(signing_failed)?;
    builder
        .add_inputs_from(&available, CoinSelectionStrategyCIP2::LargestFirstMultiAsset)
        .map_err(signing_failed)?;
    builder
        .add_change_if_needed(&change_address)
        .map_err(signing_failed)?;

    let body = builder.build().map_err(signing_failed)?;
    let inputs = (0..body.inputs().len())
        .map(|index| {
            let input = body.inputs().get(index);
            CardanoTransactionInputFfi {
                output_index: input.index(),
                tx_hash: input.transaction_id().to_bytes(),
            }
        })
        .collect();
    let outputs = (0..body.outputs().len())
        .map(|index| {
            let output = body.outputs().get(index);
            let address = output.address().to_bech32(None).map_err(signing_failed)?;
            Ok(CardanoTransactionOutputFfi {
                assets: value_assets(&output.amount()),
                is_change: address == change_address.to_bech32(None).map_err(signing_failed)?,
                lovelace: output.amount().coin().to_str(),
                address,
            })
        })
        .collect::<Result<Vec<_>, WalletKitErrorFfi>>()?;
    Ok(CardanoUnsignedTransactionFfi {
        fee: body.fee().to_str(),
        inputs,
        network_id: change_address.network_id().map_err(signing_failed)?,
        outputs,
        signing_paths: vec![CardanoSigningPathFfi { index: 0, role: 0 }],
        transaction_body: body.to_bytes(),
        ttl: body
            .ttl_bignum()
            .map(|ttl| ttl.to_str().parse::<u64>().map_err(signing_failed))
            .transpose()?,
    })
}

/// A DRep a stake key delegates its vote to.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CardanoDRepFfi {
    Abstain,
    /// CIP-129 or CIP-105 bech32 id.
    Id { bech32: String },
    NoConfidence,
}

/// One staking certificate. Certificates are always emitted separately.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CardanoStakingCertificateFfi {
    Delegation { pool_id: String },
    /// Returns `refund` lovelace.
    Deregistration { refund: String },
    /// Conway `reg_cert` paying `deposit` lovelace.
    Registration { deposit: String },
    VoteDelegation { drep: CardanoDRepFfi },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoStakingTransactionFfi {
    pub deposit: String,
    /// Signed lovelace change to the account: refund + withdrawal - fee - deposit.
    pub net_lovelace: String,
    pub refund: String,
    /// Includes the stake key path (`2/0`); callers add the input payment paths.
    pub unsigned: CardanoUnsignedTransactionFfi,
    pub withdrawal: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CardanoStakingBuildFfi {
    Built { transaction: CardanoStakingTransactionFfi },
    /// The signable UTxOs can't fund the transaction; `shortfall` is in lovelace.
    InsufficientFunds { shortfall: String },
}

/// Builds a staking transaction from `utxos` (signable UTxOs only): the
/// ordered `certificates` and an optional full-balance `withdrawal`.
#[uniffi::export]
pub fn cardano_build_staking(
    certificates: Vec<CardanoStakingCertificateFfi>,
    change_address: String,
    protocol_parameters: CardanoProtocolParametersFfi,
    stake_address: String,
    ttl: u64,
    utxos: Vec<CardanoUtxoFfi>,
    withdrawal: Option<String>,
) -> Result<CardanoStakingBuildFfi, WalletKitErrorFfi> {
    let withdrawal = withdrawal.map(|value| BigNum::from_str(&value).map_err(signing_failed)).transpose()?;
    if certificates.is_empty() && withdrawal.is_none() {
        return Err(signing_failed("Cardano staking transaction has no certificates or withdrawal"));
    }
    let change_address = Address::from_bech32(&change_address).map_err(invalid_address)?;
    let reward_address = RewardAddress::from_address(&Address::from_bech32(&stake_address).map_err(invalid_address)?)
        .ok_or_else(|| invalid_address("not a reward address"))?;
    let stake_credential = reward_address.payment_cred();
    let fee = LinearFee::new(
        &BigNum::from(protocol_parameters.min_fee_a),
        &BigNum::from(protocol_parameters.min_fee_b),
    );
    let config = TransactionBuilderConfigBuilder::new()
        .coins_per_utxo_byte(&BigNum::from(protocol_parameters.coins_per_utxo_byte))
        .fee_algo(&fee)
        .key_deposit(&BigNum::from(protocol_parameters.key_deposit))
        .max_tx_size(protocol_parameters.max_tx_size)
        .max_value_size(protocol_parameters.max_value_size)
        .pool_deposit(&BigNum::from(protocol_parameters.pool_deposit))
        // Never turn change that can't make an output into fee: add inputs until it can.
        .do_not_burn_extra_change(true)
        .build()
        .map_err(signing_failed)?;

    let mut certs = CertificatesBuilder::new();
    for certificate in certificates {
        let certificate = match certificate {
            CardanoStakingCertificateFfi::Delegation { pool_id } => {
                Certificate::new_stake_delegation(&StakeDelegation::new(&stake_credential, &pool_key_hash(&pool_id)?))
            }
            CardanoStakingCertificateFfi::Deregistration { refund } => {
                Certificate::new_stake_deregistration(&StakeDeregistration::new_with_explicit_refund(
                    &stake_credential,
                    &BigNum::from_str(&refund).map_err(signing_failed)?,
                ))
            }
            CardanoStakingCertificateFfi::Registration { deposit } => {
                Certificate::new_stake_registration(&StakeRegistration::new_with_explicit_deposit(
                    &stake_credential,
                    &BigNum::from_str(&deposit).map_err(signing_failed)?,
                ))
            }
            CardanoStakingCertificateFfi::VoteDelegation { drep } => {
                Certificate::new_vote_delegation(&VoteDelegation::new(&stake_credential, &drep_from_ffi(drep)?))
            }
        };
        certs.add(&certificate).map_err(signing_failed)?;
    }

    let mut available = TransactionUnspentOutputs::new();
    let mut total = Value::zero();
    for utxo in utxos {
        let address = Address::from_bech32(&utxo.address).map_err(invalid_address)?;
        let tx_hash = TransactionHash::from_bytes(utxo.tx_hash).map_err(signing_failed)?;
        let input = TransactionInput::new(&tx_hash, utxo.output_index);
        let lovelace = BigNum::from_str(&utxo.lovelace).map_err(signing_failed)?;
        let mut value = Value::new(&lovelace);
        if !utxo.assets.is_empty() {
            value.set_multiasset(&multiasset(utxo.assets)?);
        }
        total = total.checked_add(&value).map_err(signing_failed)?;
        available.add(&TransactionUnspentOutput::new(&input, &TransactionOutput::new(&address, &value)));
    }

    let mut builder = TransactionBuilder::new(&config);
    builder.set_certs_builder(&certs);
    if let Some(withdrawal) = &withdrawal {
        let mut withdrawals = WithdrawalsBuilder::new();
        withdrawals.add(&reward_address, withdrawal).map_err(signing_failed)?;
        builder.set_withdrawals_builder(&withdrawals);
    }
    builder.set_ttl_bignum(&BigNum::from(ttl));

    let funded = builder
        .add_inputs_from_and_change(
            &available,
            CoinSelectionStrategyCIP2::LargestFirstMultiAsset,
            &ChangeConfig::new(&change_address),
        )
        .map(|_| ());
    if let Err(error) = funded {
        let implicit = builder.get_implicit_input().ok().map(|value| value.coin());
        let output = builder.get_total_output().ok().map(|value| value.coin());
        let min_fee = builder.min_fee().ok();
        if let (Some(implicit), Some(output), Some(min_fee)) = (implicit, output, min_fee) {
            let supply = total.coin().checked_add(&implicit).map_err(signing_failed)?;
            let needed = output.checked_add(&min_fee).map_err(signing_failed)?;
            if supply.compare(&needed) < 0 {
                return Ok(CardanoStakingBuildFfi::InsufficientFunds {
                    shortfall: needed.checked_sub(&supply).map_err(signing_failed)?.to_str(),
                });
            }
            let leftover = supply.checked_sub(&needed).map_err(signing_failed)?;
            let mut change = Value::new(&leftover);
            if let Some(assets) = total.multiasset() {
                change.set_multiasset(&assets);
            }
            let minimum = min_ada_for_output(
                &TransactionOutput::new(&change_address, &change),
                &DataCost::new_coins_per_byte(&BigNum::from(protocol_parameters.coins_per_utxo_byte)),
            )
            .map_err(signing_failed)?;
            if leftover.compare(&minimum) < 0 {
                return Ok(CardanoStakingBuildFfi::InsufficientFunds {
                    shortfall: minimum.checked_sub(&leftover).map_err(signing_failed)?.to_str(),
                });
            }
        }
        return Err(signing_failed(error));
    }

    let deposit = builder.get_deposit().map_err(signing_failed)?;
    let refund = builder.get_implicit_input().map_err(signing_failed)?.coin();
    let withdrawal = withdrawal.unwrap_or_else(BigNum::zero);
    let refund = refund.checked_sub(&withdrawal).map_err(signing_failed)?;
    let body = builder.build().map_err(signing_failed)?;
    let fee = body.fee();
    let net = i128::from(u64::from(refund.clone()))
        + i128::from(u64::from(withdrawal.clone()))
        - i128::from(u64::from(fee.clone()))
        - i128::from(u64::from(deposit.clone()));
    let inputs = (0..body.inputs().len())
        .map(|index| {
            let input = body.inputs().get(index);
            CardanoTransactionInputFfi {
                output_index: input.index(),
                tx_hash: input.transaction_id().to_bytes(),
            }
        })
        .collect();
    let change_bech32 = change_address.to_bech32(None).map_err(signing_failed)?;
    let outputs = (0..body.outputs().len())
        .map(|index| {
            let output = body.outputs().get(index);
            let address = output.address().to_bech32(None).map_err(signing_failed)?;
            Ok(CardanoTransactionOutputFfi {
                assets: value_assets(&output.amount()),
                is_change: address == change_bech32,
                lovelace: output.amount().coin().to_str(),
                address,
            })
        })
        .collect::<Result<Vec<_>, WalletKitErrorFfi>>()?;
    Ok(CardanoStakingBuildFfi::Built {
        transaction: CardanoStakingTransactionFfi {
            deposit: deposit.to_str(),
            net_lovelace: net.to_string(),
            refund: refund.to_str(),
            unsigned: CardanoUnsignedTransactionFfi {
                fee: fee.to_str(),
                inputs,
                network_id: change_address.network_id().map_err(signing_failed)?,
                outputs,
                signing_paths: vec![CardanoSigningPathFfi { index: 0, role: 2 }],
                transaction_body: body.to_bytes(),
                ttl: Some(ttl),
            },
            withdrawal: withdrawal.to_str(),
        },
    })
}

fn pool_key_hash(pool_id: &str) -> Result<Ed25519KeyHash, WalletKitErrorFfi> {
    Ed25519KeyHash::from_bech32(pool_id)
        .or_else(|_| Ed25519KeyHash::from_hex(pool_id))
        .map_err(|_| signing_failed("invalid pool id"))
}

fn drep_from_ffi(drep: CardanoDRepFfi) -> Result<DRep, WalletKitErrorFfi> {
    match drep {
        CardanoDRepFfi::Abstain => Ok(DRep::new_always_abstain()),
        CardanoDRepFfi::NoConfidence => Ok(DRep::new_always_no_confidence()),
        CardanoDRepFfi::Id { bech32 } => DRep::from_bech32(&bech32).map_err(|_| signing_failed("invalid DRep id")),
    }
}

pub(crate) fn value_assets(value: &Value) -> Vec<CardanoAssetFfi> {
    let Some(multiasset) = value.multiasset() else {
        return vec![];
    };
    let policies = multiasset.keys();
    let mut result = vec![];
    for policy_index in 0..policies.len() {
        let policy = policies.get(policy_index);
        let Some(assets) = multiasset.get(&policy) else {
            continue;
        };
        let names = assets.keys();
        for name_index in 0..names.len() {
            let name = names.get(name_index);
            let Some(quantity) = assets.get(&name) else {
                continue;
            };
            result.push(CardanoAssetFfi {
                name: name.name(),
                policy_id: policy.to_bytes(),
                quantity: quantity.to_str(),
            });
        }
    }
    result
}

fn multiasset_value(assets: Vec<CardanoAssetFfi>) -> Result<MultiAsset, WalletKitErrorFfi> {
    multiasset(assets)
}

pub(crate) fn multiasset(assets: Vec<CardanoAssetFfi>) -> Result<MultiAsset, WalletKitErrorFfi> {
    let mut result = MultiAsset::new();
    for asset in assets {
        let policy = ScriptHash::from_bytes(asset.policy_id).map_err(signing_failed)?;
        let name = AssetName::new(asset.name).map_err(signing_failed)?;
        let quantity = BigNum::from_str(&asset.quantity).map_err(signing_failed)?;
        let mut group = result.get(&policy).unwrap_or_else(Assets::new);
        group.insert(&name, &quantity);
        result.insert(&policy, &group);
    }
    Ok(result)
}

/// Verifies that `address` is a Shelley-era address for `network_id`.
#[uniffi::export]
pub fn cardano_validate_address(address: String, network_id: u8) -> bool {
    Address::from_bech32(&address)
        .and_then(|address| address.network_id().map(|actual| actual == network_id))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENTROPY: [u8; 16] = [0; 16];

    fn protocol_parameters() -> CardanoProtocolParametersFfi {
        CardanoProtocolParametersFfi {
            coins_per_utxo_byte: 4_310,
            key_deposit: 2_000_000,
            max_tx_size: 16_384,
            max_value_size: 5_000,
            min_fee_a: 44,
            min_fee_b: 155_381,
            pool_deposit: 500_000_000,
        }
    }

    #[test]
    fn cip1852_account_xpub_is_deterministic_and_account_scoped() {
        let first = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        let second = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 1).unwrap();

        assert_eq!(
            first,
            cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap()
        );
        assert_ne!(first, second);
    }

    #[test]
    fn normalizes_trezor_hex_extended_public_keys_to_bech32() {
        let xpub = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        let bytes = Bip32PublicKey::from_bech32(&xpub).unwrap().as_bytes();

        assert_eq!(normalize_account_xpub(&hex::encode(bytes)).unwrap(), xpub);
    }

    #[test]
    fn base_address_is_valid_only_for_its_network() {
        let xpub = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        let mainnet = cardano_base_address(xpub, 1, 0, 0).unwrap();

        assert!(cardano_validate_address(mainnet.clone(), 1));
        assert!(!cardano_validate_address(mainnet, 0));
    }

    #[test]
    fn ada_transfer_builds_and_signs_a_payment_witness() {
        let xpub = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        let sender = cardano_base_address(xpub.clone(), 0, 0, 0).unwrap();
        let recipient = cardano_base_address(xpub, 0, 0, 1).unwrap();
        let unsigned = cardano_build_transfer(
            "1000000".to_string(),
            sender.clone(),
            "1000000".to_string(),
            protocol_parameters(),
            recipient,
            None,
            vec![CardanoUtxoFfi {
                address: sender,
                assets: vec![],
                lovelace: "5000000".to_string(),
                output_index: 0,
                tx_hash: vec![7; 32],
            }],
        )
        .unwrap();
        let signed = cardano_sign_transaction(
            ENTROPY.to_vec(),
            0,
            unsigned.signing_paths,
            unsigned.transaction_body.clone(),
        )
        .unwrap();
        let transaction = Transaction::from_bytes(signed).unwrap();

        assert_eq!(transaction.body().to_bytes(), unsigned.transaction_body);
        assert_eq!(transaction.witness_set().vkeys().unwrap().len(), 1);
    }

    #[test]
    fn native_asset_transfer_preserves_asset_signing_context() {
        let xpub = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        let sender = cardano_base_address(xpub.clone(), 0, 0, 0).unwrap();
        let recipient = cardano_base_address(xpub, 0, 0, 1).unwrap();
        let asset = CardanoAssetFfi {
            name: b"TEST".to_vec(),
            policy_id: vec![9; 28],
            quantity: "10".to_string(),
        };
        let unsigned = cardano_build_transfer(
            "3".to_string(),
            sender.clone(),
            "2000000".to_string(),
            protocol_parameters(),
            recipient,
            Some(CardanoAssetFfi { quantity: "3".to_string(), ..asset.clone() }),
            vec![CardanoUtxoFfi {
                address: sender,
                assets: vec![asset],
                lovelace: "5000000".to_string(),
                output_index: 0,
                tx_hash: vec![8; 32],
            }],
        )
        .unwrap();

        assert_eq!(unsigned.network_id, 0);
        assert_eq!(unsigned.inputs.len(), 1);
        assert!(unsigned.outputs.iter().any(|output| output.assets.iter().any(|asset| asset.quantity == "3")));
        assert!(unsigned.outputs.iter().any(|output| output.is_change));
    }

    #[test]
    fn assembled_device_witness_preserves_the_canonical_transaction_body() {
        let xpub = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        let sender = cardano_base_address(xpub.clone(), 0, 0, 0).unwrap();
        let recipient = cardano_base_address(xpub, 0, 0, 1).unwrap();
        let unsigned = cardano_build_transfer(
            "1000000".to_string(),
            sender.clone(),
            "1000000".to_string(),
            protocol_parameters(),
            recipient,
            None,
            vec![CardanoUtxoFfi {
                address: sender,
                assets: vec![],
                lovelace: "5000000".to_string(),
                output_index: 0,
                tx_hash: vec![6; 32],
            }],
        ).unwrap();
        let signed = cardano_sign_transaction(
            ENTROPY.to_vec(),
            0,
            unsigned.signing_paths,
            unsigned.transaction_body.clone(),
        ).unwrap();
        let original = Transaction::from_bytes(signed).unwrap();
        let vkey = original.witness_set().vkeys().unwrap().get(0);
        let assembled = cardano_assemble_transaction(
            unsigned.transaction_body.clone(),
            vec![CardanoWitnessFfi {
                public_key: vkey.vkey().public_key().as_bytes(),
                signature: vkey.signature().to_bytes(),
            }],
        ).unwrap();
        let assembled = Transaction::from_bytes(assembled).unwrap();

        assert_eq!(cardano_transaction_body_hash(unsigned.transaction_body).unwrap().len(), 32);
        assert_eq!(assembled.body().to_bytes(), original.body().to_bytes());
        assert_eq!(assembled.witness_set().vkeys().unwrap().len(), 1);
    }

    fn staking_fixture() -> (String, String, String) {
        let xpub = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        (
            cardano_base_address(xpub.clone(), 0, 0, 0).unwrap(),
            cardano_stake_address(xpub.clone(), 0).unwrap(),
            xpub,
        )
    }

    fn pool_id() -> String {
        Ed25519KeyHash::from_bytes(vec![3; 28]).unwrap().to_bech32("pool").unwrap()
    }

    fn drep_id(cip129: bool) -> String {
        DRep::new_key_hash(&Ed25519KeyHash::from_bytes(vec![5; 28]).unwrap()).to_bech32(cip129).unwrap()
    }

    fn utxo(address: &str, lovelace: &str, tag: u8, assets: Vec<CardanoAssetFfi>) -> CardanoUtxoFfi {
        CardanoUtxoFfi {
            address: address.to_string(),
            assets,
            lovelace: lovelace.to_string(),
            output_index: 0,
            tx_hash: vec![tag; 32],
        }
    }

    fn build(
        certificates: Vec<CardanoStakingCertificateFfi>,
        utxos: Vec<CardanoUtxoFfi>,
        withdrawal: Option<&str>,
    ) -> CardanoStakingBuildFfi {
        let (payment, stake, _) = staking_fixture();
        cardano_build_staking(
            certificates,
            payment,
            protocol_parameters(),
            stake,
            1_000,
            utxos,
            withdrawal.map(str::to_string),
        )
        .unwrap()
    }

    fn built(result: CardanoStakingBuildFfi) -> CardanoStakingTransactionFfi {
        match result {
            CardanoStakingBuildFfi::Built { transaction } => transaction,
            other => panic!("expected a built transaction, got {other:?}"),
        }
    }

    fn certificates(transaction: &CardanoStakingTransactionFfi) -> Vec<Certificate> {
        let body = TransactionBody::from_bytes(transaction.unsigned.transaction_body.clone()).unwrap();
        let certs = body.certs().unwrap();
        (0..certs.len()).map(|index| certs.get(index)).collect()
    }

    #[test]
    fn registration_and_delegation_pay_the_deposit_as_separate_certificates() {
        let (payment, ..) = staking_fixture();
        let transaction = built(build(
            vec![
                CardanoStakingCertificateFfi::Registration { deposit: "2000000".into() },
                CardanoStakingCertificateFfi::Delegation { pool_id: pool_id() },
            ],
            vec![utxo(&payment, "10000000", 1, vec![])],
            None,
        ));
        let certs = certificates(&transaction);

        assert_eq!(certs.len(), 2);
        assert!(certs[0].as_stake_registration().is_some());
        assert!(certs[1].as_stake_delegation().is_some());
        assert_eq!(transaction.deposit, "2000000");
        assert_eq!(transaction.refund, "0");
        let fee: i128 = transaction.unsigned.fee.parse().unwrap();
        assert_eq!(transaction.net_lovelace, (-fee - 2_000_000).to_string());
        let change: u64 = transaction.unsigned.outputs.iter().map(|o| o.lovelace.parse::<u64>().unwrap()).sum();
        assert_eq!(change + fee as u64 + 2_000_000, 10_000_000);
        assert!(transaction.unsigned.signing_paths.contains(&CardanoSigningPathFfi { index: 0, role: 2 }));
    }

    #[test]
    fn delegation_and_vote_delegation_build_alone() {
        let (payment, ..) = staking_fixture();
        let utxos = vec![utxo(&payment, "5000000", 1, vec![])];
        let pool = built(build(
            vec![CardanoStakingCertificateFfi::Delegation { pool_id: pool_id() }],
            utxos.clone(),
            None,
        ));
        let vote = built(build(
            vec![CardanoStakingCertificateFfi::VoteDelegation { drep: CardanoDRepFfi::Abstain }],
            utxos,
            None,
        ));

        assert!(certificates(&pool)[0].as_stake_delegation().is_some());
        assert!(certificates(&vote)[0].as_vote_delegation().is_some());
        assert_eq!(pool.deposit, "0");
    }

    #[test]
    fn drep_ids_accept_cip105_cip129_and_the_predefined_dreps() {
        for drep in [
            CardanoDRepFfi::Id { bech32: drep_id(false) },
            CardanoDRepFfi::Id { bech32: drep_id(true) },
            CardanoDRepFfi::Abstain,
            CardanoDRepFfi::NoConfidence,
        ] {
            assert!(drep_from_ffi(drep).is_ok());
        }
        assert!(drep_from_ffi(CardanoDRepFfi::Id { bech32: "drep1invalid".into() }).is_err());
    }

    #[test]
    fn withdrawal_funds_the_fee() {
        let (payment, ..) = staking_fixture();
        // The input alone covers nothing after min-ADA; the withdrawal pays the fee.
        let transaction = built(build(
            vec![CardanoStakingCertificateFfi::VoteDelegation { drep: CardanoDRepFfi::NoConfidence }],
            vec![utxo(&payment, "1000000", 1, vec![])],
            Some("3000000"),
        ));

        assert_eq!(transaction.withdrawal, "3000000");
        let fee: i128 = transaction.unsigned.fee.parse().unwrap();
        assert_eq!(transaction.net_lovelace, (3_000_000 - fee).to_string());
        let body = TransactionBody::from_bytes(transaction.unsigned.transaction_body).unwrap();
        assert_eq!(body.withdrawals().unwrap().len(), 1);
    }

    #[test]
    fn deregistration_refund_funds_the_fee_and_sweeps_rewards() {
        let (payment, ..) = staking_fixture();
        let transaction = built(build(
            vec![CardanoStakingCertificateFfi::Deregistration { refund: "2000000".into() }],
            vec![utxo(&payment, "1000000", 1, vec![])],
            Some("1500000"),
        ));
        let fee: i128 = transaction.unsigned.fee.parse().unwrap();

        assert_eq!(transaction.refund, "2000000");
        assert_eq!(transaction.deposit, "0");
        assert_eq!(transaction.net_lovelace, (2_000_000 + 1_500_000 - fee).to_string());
        assert!(certificates(&CardanoStakingTransactionFfi { ..transaction })[0].as_stake_deregistration().is_some());
    }

    #[test]
    fn unfunded_deposit_reports_the_shortfall() {
        let (payment, ..) = staking_fixture();
        let result = build(
            vec![CardanoStakingCertificateFfi::Registration { deposit: "2000000".into() }],
            vec![utxo(&payment, "1000000", 1, vec![])],
            None,
        );

        let CardanoStakingBuildFfi::InsufficientFunds { shortfall } = result else {
            panic!("expected a shortfall");
        };
        assert!(shortfall.parse::<u64>().unwrap() >= 1_000_000);
    }

    #[test]
    fn native_assets_are_preserved_in_change() {
        let (payment, ..) = staking_fixture();
        let asset = CardanoAssetFfi { name: b"TEST".to_vec(), policy_id: vec![9; 28], quantity: "10".into() };
        let transaction = built(build(
            vec![CardanoStakingCertificateFfi::Registration { deposit: "2000000".into() }],
            vec![utxo(&payment, "10000000", 1, vec![asset])],
            None,
        ));

        assert!(transaction
            .unsigned
            .outputs
            .iter()
            .any(|output| output.is_change && output.assets.iter().any(|asset| asset.quantity == "10")));
    }

    #[test]
    fn staking_requires_a_certificate_or_withdrawal() {
        let (payment, stake, _) = staking_fixture();
        let result = cardano_build_staking(
            vec![],
            payment.clone(),
            protocol_parameters(),
            stake,
            1_000,
            vec![utxo(&payment, "5000000", 1, vec![])],
            None,
        );

        assert!(result.is_err());
    }

    #[test]
    fn unsigned_transaction_round_trips_through_a_device_witness_set() {
        let (payment, ..) = staking_fixture();
        let transaction = built(build(
            vec![CardanoStakingCertificateFfi::Delegation { pool_id: pool_id() }],
            vec![utxo(&payment, "5000000", 1, vec![])],
            None,
        ));
        let body = transaction.unsigned.transaction_body.clone();
        let unsigned = cardano_unsigned_transaction(body.clone()).unwrap();
        assert_eq!(Transaction::from_bytes(unsigned).unwrap().body().to_bytes(), body);

        let signed = cardano_sign_transaction(
            ENTROPY.to_vec(),
            0,
            transaction.unsigned.signing_paths,
            body.clone(),
        )
        .unwrap();
        let witness_set = Transaction::from_bytes(signed).unwrap().witness_set().to_bytes();
        let assembled = cardano_assemble_with_witness_set(body.clone(), witness_set).unwrap();

        assert_eq!(Transaction::from_bytes(assembled).unwrap().body().to_bytes(), body);
        assert!(cardano_assemble_with_witness_set(body, TransactionWitnessSet::new().to_bytes()).is_err());
    }

    #[test]
    fn change_is_returned_instead_of_burned_as_fee() {
        let (payment, ..) = staking_fixture();
        // One 1 ADA input can't both pay the fee and leave a valid change output.
        let transaction = built(build(
            vec![CardanoStakingCertificateFfi::VoteDelegation { drep: CardanoDRepFfi::Abstain }],
            vec![utxo(&payment, "1000000", 1, vec![]), utxo(&payment, "1000000", 2, vec![])],
            None,
        ));
        let fee: u64 = transaction.unsigned.fee.parse().unwrap();

        assert_eq!(transaction.unsigned.inputs.len(), 2);
        assert!(fee < 300_000, "fee {fee}");
        assert!(transaction.unsigned.outputs.iter().any(|output| output.is_change));
    }

    #[test]
    fn a_legacy_registration_still_names_its_stake_credential() {
        use super::super::cardano_dapp::cardano_decode_transaction;
        use cardano_serialization_lib::{Certificates, TransactionInputs, TransactionOutputs};

        let (.., xpub) = staking_fixture();
        let stake_key = Bip32PublicKey::from_bech32(&xpub)
            .unwrap()
            .derive(2)
            .unwrap()
            .derive(0)
            .unwrap()
            .to_raw_key();
        let credential = Credential::from_keyhash(&stake_key.hash());
        let mut certificates = Certificates::new();
        certificates.add(&Certificate::new_stake_registration(&StakeRegistration::new(&credential)));
        let mut body = TransactionBody::new_tx_body(&TransactionInputs::new(), &TransactionOutputs::new(), &BigNum::zero());
        body.set_certs(&certificates);
        let transaction = Transaction::new(&body, &TransactionWitnessSet::new(), None).to_bytes();

        let decoded = cardano_decode_transaction(transaction).unwrap();

        // No witness is required, yet the certificate is the account's.
        assert_eq!(decoded.certificates[0].credential, None);
        assert_eq!(decoded.certificates[0].subject, Some(stake_key.hash().to_bytes()));
    }
}
