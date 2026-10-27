//! Builds Trezor's dApp requests from the raw CIP-30 inputs: a transaction's
//! original bytes, or a `signData` address and payload.
//!
//! The device re-serializes the body from the fields it is streamed, so every
//! field of the dapp's body is mapped here and the caller compares the
//! device-reported body hash with the original. Anything the firmware can't
//! sign is rejected by `walletkit-hardware` before any device prompt.

use std::collections::HashMap;

use cardano_serialization_lib::{
    Address, BaseAddress, Bip32PublicKey, ByronAddress, Certificate, CertificateKind, CborContainerType, Credential,
    DRepKind, Ed25519Signature, FixedTransaction, PublicKey, RewardAddress, TransactionOutput, TransactionWitnessSet,
    Value, Vkey, Vkeywitness, Vkeywitnesses,
};
use walletkit_hardware as hw;

use crate::blockchain_clients::cardano::{invalid_address, normalize_account_xpub, signing_failed, CardanoSigningPathFfi};
use crate::common::DerivationPathFfi;
use crate::errors::WalletKitErrorFfi;

/// Who is signing: the account's path and public key, and the network.
pub(super) struct Account {
    pub(super) path: Vec<hw::HardwarePathSegment>,
    pub(super) protocol_magic: u32,
    pub(super) network_id: u8,
    xpub: Bip32PublicKey,
}

impl Account {
    pub(super) fn new(
        path: &DerivationPathFfi,
        xpub: &str,
        network_id: u8,
        protocol_magic: u32,
    ) -> Result<Self, WalletKitErrorFfi> {
        Ok(Self {
            network_id,
            path: path
                .segments
                .iter()
                .map(|segment| hw::HardwarePathSegment { index: segment.index, hardened: segment.hardened })
                .collect(),
            protocol_magic,
            xpub: Bip32PublicKey::from_bech32(&normalize_account_xpub(xpub)?).map_err(invalid_address)?,
        })
    }

    pub(super) fn key_path(&self, role: u32, index: u32) -> Vec<hw::HardwarePathSegment> {
        let mut path = self.path.clone();
        path.push(hw::HardwarePathSegment { index: role, hardened: false });
        path.push(hw::HardwarePathSegment { index, hardened: false });
        path
    }

    fn key_hash(&self, role: u32, index: u32) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let key = self
            .xpub
            .derive(role)
            .and_then(|key| key.derive(index))
            .map_err(invalid_address)?
            .to_raw_key();

        Ok(key.hash().to_bytes())
    }
}

fn number(text: &str, what: &str) -> Result<u64, WalletKitErrorFfi> {
    text.parse().map_err(|_| signing_failed(format!("Cardano {what} exceeds Trezor's supported range")))
}

fn address_string(address: &Address) -> Result<String, WalletKitErrorFfi> {
    if let Ok(bech32) = address.to_bech32(None) {
        return Ok(bech32);
    }

    ByronAddress::from_address(address)
        .map(|byron| byron.to_base58())
        .ok_or_else(|| signing_failed("Cardano output address has no Trezor-supported form"))
}

fn assets(value: &Value) -> Result<Vec<hw::CardanoAsset>, WalletKitErrorFfi> {
    let mut result = vec![];
    let Some(multiasset) = value.multiasset() else {
        return Ok(result);
    };
    let policies = multiasset.keys();
    for policy_index in 0..policies.len() {
        let policy = policies.get(policy_index);
        let Some(group) = multiasset.get(&policy) else {
            continue;
        };
        let names = group.keys();
        for name_index in 0..names.len() {
            let name = names.get(name_index);
            let Some(quantity) = group.get(&name) else {
                continue;
            };
            result.push(hw::CardanoAsset {
                name: name.name(),
                policy_id: policy.to_bytes(),
                quantity: number(&quantity.to_str(), "native asset quantity")?,
            });
        }
    }

    Ok(result)
}

/// Content of a tag-24 byte string: `ScriptRef` is encoded `#6.24(bytes)`.
fn script_ref_content(encoded: &[u8]) -> Option<Vec<u8>> {
    let rest = encoded.strip_prefix(&[0xD8, 0x18])?;
    let (_, _, length, next) = read_head(rest, 0)?;
    rest.get(next..next + length as usize).map(<[u8]>::to_vec)
}

fn output(output: &TransactionOutput) -> Result<hw::CardanoDappOutput, WalletKitErrorFfi> {
    let amount = output.amount();
    let datum = match (output.data_hash(), output.plutus_data()) {
        (Some(hash), _) => Some(hw::CardanoDatum::Hash(hash.to_bytes())),
        (_, Some(data)) => Some(hw::CardanoDatum::Inline(data.to_bytes())),
        _ => None,
    };
    let reference_script = output
        .script_ref()
        .map(|script| {
            script_ref_content(&script.to_bytes())
                .ok_or_else(|| signing_failed("Cardano reference script has an unexpected encoding"))
        })
        .transpose()?;

    Ok(hw::CardanoDappOutput {
        address: address_string(&output.address())?,
        assets: assets(&amount)?,
        lovelace: number(&amount.coin().to_str(), "output amount")?,
        post_alonzo: matches!(output.serialization_format(), Some(CborContainerType::Map))
            || matches!(datum, Some(hw::CardanoDatum::Inline(_)))
            || reference_script.is_some(),
        datum,
        reference_script,
    })
}

fn inputs(inputs: &cardano_serialization_lib::TransactionInputs) -> Vec<hw::CardanoTxInput> {
    (0..inputs.len())
        .map(|index| {
            let input = inputs.get(index);
            hw::CardanoTxInput {
                output_index: input.index(),
                tx_hash: input.transaction_id().to_bytes(),
            }
        })
        .collect()
}

/// `(major, additional info, argument, next position)` of the CBOR head at
/// `pos`. Indefinite lengths (info 31) have argument 0.
fn read_head(data: &[u8], pos: usize) -> Option<(u8, u8, u64, usize)> {
    let first = *data.get(pos)?;
    let (major, info) = (first >> 5, first & 0x1F);
    let width = match info {
        0..=23 => return Some((major, info, u64::from(info), pos + 1)),
        24 => 1,
        25 => 2,
        26 => 4,
        27 => 8,
        31 => return Some((major, info, 0, pos + 1)),
        _ => return None,
    };
    let bytes = data.get(pos + 1..pos + 1 + width)?;

    Some((major, info, bytes.iter().fold(0, |acc, byte| (acc << 8) | u64::from(*byte)), pos + 1 + width))
}

/// Position just past the CBOR item at `pos`.
fn skip(data: &[u8], pos: usize) -> Option<usize> {
    let (major, info, argument, next) = read_head(data, pos)?;
    let indefinite = info == 31;

    match major {
        0 | 1 | 7 => Some(next),
        2 | 3 if indefinite => {
            let mut at = next;
            while *data.get(at)? != 0xFF {
                at = skip(data, at)?;
            }
            Some(at + 1)
        }
        2 | 3 => Some(next + argument as usize),
        4 | 5 => {
            let per_entry = if major == 5 { 2 } else { 1 };
            let mut at = next;
            if indefinite {
                while *data.get(at)? != 0xFF {
                    at = skip(data, at)?;
                }
                return Some(at + 1);
            }
            for _ in 0..argument * per_entry {
                at = skip(data, at)?;
            }
            Some(at)
        }
        6 => skip(data, next),
        _ => None,
    }
}

/// Whether the body's `inputs` set carries tag 258, which the device needs to
/// reproduce the original encoding (the other sets follow the same era).
fn body_uses_set_tags(raw_body: &[u8]) -> bool {
    let Some((5, info, entries, mut at)) = read_head(raw_body, 0) else {
        return false;
    };
    let mut remaining = if info == 31 { u64::MAX } else { entries };
    while remaining > 0 && raw_body.get(at).is_some_and(|byte| *byte != 0xFF) {
        let Some((0, _, key, value_at)) = read_head(raw_body, at) else {
            return false;
        };
        if key == 0 {
            return raw_body[value_at..].starts_with(&[0xD9, 0x01, 0x02]);
        }
        let Some(next) = skip(raw_body, value_at) else {
            return false;
        };
        at = next;
        remaining -= 1;
    }

    false
}

fn credential(
    credential: &Credential,
    account: &Account,
    stake_hash: &[u8],
) -> Result<hw::CardanoCredential, WalletKitErrorFfi> {
    if let Some(hash) = credential.to_keyhash() {
        let bytes = hash.to_bytes();
        return Ok(if bytes == stake_hash {
            hw::CardanoCredential::Path(account.key_path(2, 0))
        } else {
            hw::CardanoCredential::KeyHash(bytes)
        });
    }

    credential
        .to_scripthash()
        .map(|hash| hw::CardanoCredential::ScriptHash(hash.to_bytes()))
        .ok_or_else(|| signing_failed("Cardano credential is neither a key nor a script"))
}

fn certificate(
    certificate: &Certificate,
    account: &Account,
    stake_hash: &[u8],
) -> Result<hw::CardanoCertificate, WalletKitErrorFfi> {
    let mapped = |credential_value: Credential,
                  kind: hw::CardanoCertificateKind,
                  deposit: Option<u64>,
                  pool: Option<Vec<u8>>,
                  drep: Option<hw::CardanoDRep>| {
        Ok(hw::CardanoCertificate {
            credential: credential(&credential_value, account, stake_hash)?,
            deposit,
            drep,
            kind,
            pool,
        })
    };
    let coin = |coin: Option<cardano_serialization_lib::Coin>| -> Result<Option<u64>, WalletKitErrorFfi> {
        coin.map(|coin| number(&coin.to_str(), "deposit")).transpose()
    };

    match certificate.kind() {
        CertificateKind::StakeRegistration => {
            let registration = certificate.as_stake_registration().ok_or_else(|| signing_failed("certificate"))?;
            let deposit = coin(registration.coin())?;
            let kind = if deposit.is_some() {
                hw::CardanoCertificateKind::StakeRegistrationConway
            } else {
                hw::CardanoCertificateKind::StakeRegistration
            };
            mapped(registration.stake_credential(), kind, deposit, None, None)
        }
        CertificateKind::StakeDeregistration => {
            let deregistration = certificate.as_stake_deregistration().ok_or_else(|| signing_failed("certificate"))?;
            let deposit = coin(deregistration.coin())?;
            let kind = if deposit.is_some() {
                hw::CardanoCertificateKind::StakeDeregistrationConway
            } else {
                hw::CardanoCertificateKind::StakeDeregistration
            };
            mapped(deregistration.stake_credential(), kind, deposit, None, None)
        }
        CertificateKind::StakeDelegation => {
            let delegation = certificate.as_stake_delegation().ok_or_else(|| signing_failed("certificate"))?;
            mapped(
                delegation.stake_credential(),
                hw::CardanoCertificateKind::StakeDelegation,
                None,
                Some(delegation.pool_keyhash().to_bytes()),
                None,
            )
        }
        CertificateKind::VoteDelegation => {
            let delegation = certificate.as_vote_delegation().ok_or_else(|| signing_failed("certificate"))?;
            let drep = delegation.drep();
            let drep = match drep.kind() {
                DRepKind::KeyHash => drep.to_key_hash().map(|hash| hw::CardanoDRep::KeyHash(hash.to_bytes())),
                DRepKind::ScriptHash => drep.to_script_hash().map(|hash| hw::CardanoDRep::ScriptHash(hash.to_bytes())),
                DRepKind::AlwaysAbstain => Some(hw::CardanoDRep::Abstain),
                DRepKind::AlwaysNoConfidence => Some(hw::CardanoDRep::NoConfidence),
            };
            mapped(delegation.stake_credential(), hw::CardanoCertificateKind::VoteDelegation, None, None, drep)
        }
        other => Ok(hw::CardanoCertificate {
            credential: hw::CardanoCredential::KeyHash(vec![]),
            deposit: None,
            drep: None,
            kind: hw::CardanoCertificateKind::Unsupported { name: format!("{other:?}") },
            pool: None,
        }),
    }
}

/// Maps the dapp's transaction to the device request. `signing_paths` are the
/// account keys that will witness it (from the signer resolver).
pub(super) fn transaction_request(
    transaction: &[u8],
    account: &Account,
    signing_paths: &[CardanoSigningPathFfi],
) -> Result<(hw::CardanoDappTxRequest, Vec<u8>), WalletKitErrorFfi> {
    let fixed = FixedTransaction::from_bytes(transaction.to_vec()).map_err(signing_failed)?;
    let body = fixed.body();
    let stake_hash = account.key_hash(2, 0)?;

    let mut owned: HashMap<Vec<u8>, Vec<hw::HardwarePathSegment>> = HashMap::new();
    for path in signing_paths {
        owned.insert(account.key_hash(path.role, path.index)?, account.key_path(path.role, path.index));
    }

    let mut outputs = vec![];
    let body_outputs = body.outputs();
    for index in 0..body_outputs.len() {
        outputs.push(self::output(&body_outputs.get(index))?);
    }

    let mut mint = vec![];
    if let Some(body_mint) = body.mint() {
        let policies = body_mint.keys();
        for policy_index in 0..policies.len() {
            let policy = policies.get(policy_index);
            let Some(entries) = body_mint.get(&policy) else {
                continue;
            };
            let mut tokens = vec![];
            for entry in (0..entries.len()).filter_map(|index| entries.get(index)) {
                let names = entry.keys();
                for name_index in 0..names.len() {
                    let name = names.get(name_index);
                    let Some(amount) = entry.get(&name) else {
                        continue;
                    };
                    tokens.push(hw::CardanoMintToken {
                        amount: amount
                            .to_str()
                            .parse()
                            .map_err(|_| signing_failed("Cardano mint amount exceeds Trezor's supported range"))?,
                        name: name.name(),
                    });
                }
            }
            mint.push(hw::CardanoMintGroup { policy_id: policy.to_bytes(), tokens });
        }
    }

    let mut certificates = vec![];
    if let Some(certs) = body.certs() {
        for index in 0..certs.len() {
            certificates.push(self::certificate(&certs.get(index), account, &stake_hash)?);
        }
    }

    let mut withdrawals = vec![];
    if let Some(body_withdrawals) = body.withdrawals() {
        let accounts = body_withdrawals.keys();
        for index in 0..accounts.len() {
            let reward: RewardAddress = accounts.get(index);
            let Some(amount) = body_withdrawals.get(&reward) else {
                continue;
            };
            withdrawals.push(hw::CardanoWithdrawal {
                amount: number(&amount.to_str(), "withdrawal")?,
                credential: self::credential(&reward.payment_cred(), account, &stake_hash)?,
            });
        }
    }

    let required_signers = body.required_signers().map_or(vec![], |signers| {
        (0..signers.len())
            .map(|index| {
                let hash = signers.get(index).to_bytes();
                match owned.get(&hash) {
                    Some(path) => hw::CardanoRequiredSigner::Path(path.clone()),
                    None => hw::CardanoRequiredSigner::KeyHash(hash),
                }
            })
            .collect()
    });

    let mut unsupported_content = vec![];
    if body.voting_procedures().is_some() {
        unsupported_content.push("voting procedures".to_string());
    }
    if body.voting_proposals().is_some() {
        unsupported_content.push("governance proposals".to_string());
    }
    if body.donation().is_some() {
        unsupported_content.push("treasury donation".to_string());
    }
    if body.current_treasury_value().is_some() {
        unsupported_content.push("current treasury value".to_string());
    }

    let number_option = |value: Option<String>, what: &str| -> Result<Option<u64>, WalletKitErrorFfi> {
        value.map(|value| number(&value, what)).transpose()
    };

    let request = hw::CardanoDappTxRequest {
        auxiliary_data_hash: body.auxiliary_data_hash().map(|hash| hash.to_bytes()),
        certificates,
        collateral_inputs: body.collateral().map_or(vec![], |value| inputs(&value)),
        collateral_return: body.collateral_return().map(|value| self::output(&value)).transpose()?,
        fee: number(&body.fee().to_str(), "fee")?,
        include_network_id: body.network_id().is_some(),
        inputs: inputs(&body.inputs()),
        mint,
        network_id: account.network_id,
        outputs,
        protocol_magic: account.protocol_magic,
        reference_inputs: body.reference_inputs().map_or(vec![], |value| inputs(&value)),
        required_signers,
        script_data_hash: body.script_data_hash().map(|hash| hash.to_bytes()),
        tag_cbor_sets: body_uses_set_tags(&fixed.raw_body()),
        total_collateral: number_option(body.total_collateral().map(|coin| coin.to_str()), "total collateral")?,
        ttl: number_option(body.ttl_bignum().map(|slot| slot.to_str()), "ttl")?,
        unsupported_content,
        validity_start: number_option(
            body.validity_start_interval_bignum().map(|slot| slot.to_str()),
            "validity start",
        )?,
        withdrawals,
        witness_paths: signing_paths.iter().map(|path| account.key_path(path.role, path.index)).collect(),
    };

    Ok((request, fixed.transaction_hash().to_bytes()))
}

/// A witness set holding only the device's vkey witnesses, as CIP-30 `signTx`
/// returns it.
pub(super) fn witness_set(witnesses: Vec<hw::CardanoWitness>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let mut vkeys = Vkeywitnesses::new();
    for witness in witnesses {
        let key = PublicKey::from_bytes(&witness.public_key).map_err(signing_failed)?;
        let signature = Ed25519Signature::from_bytes(witness.signature).map_err(signing_failed)?;
        vkeys.add(&Vkeywitness::new(&Vkey::new(&key), &signature));
    }
    let mut set = TransactionWitnessSet::new();
    set.set_vkeys(&vkeys);

    Ok(set.to_bytes())
}

/// Maps a `signData` request to the device's message request, choosing the
/// header address type from the address bytes.
pub(super) fn message_request(
    address: &[u8],
    payload: Vec<u8>,
    account: &Account,
    signing_path: &CardanoSigningPathFfi,
) -> Result<hw::CardanoMessageRequest, WalletKitErrorFfi> {
    let parsed = Address::from_bytes(address.to_vec()).map_err(invalid_address)?;
    let key_path = account.key_path(signing_path.role, signing_path.index);

    let header = if let Some(base) = BaseAddress::from_address(&parsed) {
        let stake = base.stake_cred();
        let own_stake_path = account.key_path(2, 0);
        let (staking_key_hash, staking_path) = match stake.to_keyhash() {
            Some(hash) if hash.to_bytes() == account.key_hash(2, 0)? => (None, own_stake_path),
            Some(hash) => (Some(hash.to_bytes()), vec![]),
            None => return Err(signing_failed("Trezor can't sign for a script-staked base address")),
        };
        hw::CardanoMessageAddress {
            address_type: if staking_key_hash.is_some() {
                hw::CardanoMessageAddressType::BaseKeyScript
            } else {
                hw::CardanoMessageAddressType::Base
            },
            network_id: parsed.network_id().map_err(invalid_address)?,
            path: key_path.clone(),
            protocol_magic: account.protocol_magic,
            staking_key_hash,
            staking_path,
        }
    } else if let Some(reward) = RewardAddress::from_address(&parsed) {
        hw::CardanoMessageAddress {
            address_type: hw::CardanoMessageAddressType::Reward,
            network_id: reward.to_address().network_id().map_err(invalid_address)?,
            path: key_path.clone(),
            protocol_magic: account.protocol_magic,
            staking_key_hash: None,
            staking_path: vec![],
        }
    } else if cardano_serialization_lib::EnterpriseAddress::from_address(&parsed).is_some() {
        hw::CardanoMessageAddress {
            address_type: hw::CardanoMessageAddressType::Enterprise,
            network_id: parsed.network_id().map_err(invalid_address)?,
            path: key_path.clone(),
            protocol_magic: account.protocol_magic,
            staking_key_hash: None,
            staking_path: vec![],
        }
    } else {
        return Err(signing_failed("Trezor can't sign for this Cardano address type"));
    };

    Ok(hw::CardanoMessageRequest {
        address: Some(header),
        payload,
        prefer_hex_display: false,
        signing_path: key_path,
    })
}

#[cfg(test)]
mod tests {
    use cardano_serialization_lib::{
        BigNum, Certificates, Ed25519KeyHash, Ed25519KeyHashes, StakeDelegation, Transaction, TransactionBody,
        TransactionHash, TransactionInput, TransactionInputs, TransactionOutput, TransactionOutputs,
        TransactionWitnessSet,
    };

    use super::*;
    use crate::blockchain_clients::cardano::{cardano_account_xpub_from_entropy, cardano_base_address};
    use crate::common::Segment;

    const ENTROPY: [u8; 16] = [0; 16];

    fn account() -> Account {
        let path = DerivationPathFfi::new(vec![
            Segment { index: 1852, hardened: true },
            Segment { index: 1815, hardened: true },
            Segment { index: 0, hardened: true },
        ]);

        Account::new(&path, &cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap(), 0, 1).unwrap()
    }

    fn base_body() -> TransactionBody {
        let xpub = cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap();
        let mut inputs = TransactionInputs::new();
        inputs.add(&TransactionInput::new(&TransactionHash::from_bytes(vec![1; 32]).unwrap(), 0));
        let mut outputs = TransactionOutputs::new();
        outputs.add(&TransactionOutput::new(
            &Address::from_bech32(&cardano_base_address(xpub, 0, 0, 0).unwrap()).unwrap(),
            &Value::new(&BigNum::from_str("2000000").unwrap()),
        ));

        TransactionBody::new_tx_body(&inputs, &outputs, &BigNum::from_str("170000").unwrap())
    }

    fn bytes(body: &TransactionBody) -> Vec<u8> {
        Transaction::new(body, &TransactionWitnessSet::new(), None).to_bytes()
    }

    fn path(role: u32, index: u32) -> CardanoSigningPathFfi {
        CardanoSigningPathFfi { index, role }
    }

    #[test]
    fn plain_transfer_maps_and_validates_as_ordinary() {
        let account = account();
        let (request, hash) = transaction_request(&bytes(&base_body()), &account, &[path(0, 0)]).unwrap();

        assert_eq!(hash, cardano_serialization_lib::FixedTransaction::from_bytes(bytes(&base_body())).unwrap().transaction_hash().to_bytes());
        assert_eq!(request.fee, 170_000);
        assert_eq!(request.inputs.len(), 1);
        assert_eq!(request.outputs[0].lovelace, 2_000_000);
        assert_eq!(request.network_id, 0);
        assert_eq!(request.protocol_magic, 1);
        assert_eq!(request.witness_paths, vec![account.key_path(0, 0)]);
        assert_eq!(request.validate(), Ok(hw::CardanoSigningMode::Ordinary));
    }

    #[test]
    fn delegating_the_own_stake_key_uses_its_path() {
        let account = account();
        let own = Credential::from_keyhash(&Ed25519KeyHash::from_bytes(account.key_hash(2, 0).unwrap()).unwrap());
        let mut certs = Certificates::new();
        certs.add(&Certificate::new_stake_delegation(&StakeDelegation::new(
            &own,
            &Ed25519KeyHash::from_bytes(vec![5; 28]).unwrap(),
        )));
        let mut body = base_body();
        body.set_certs(&certs);

        let (request, _) = transaction_request(&bytes(&body), &account, &[path(0, 0), path(2, 0)]).unwrap();

        assert_eq!(request.certificates.len(), 1);
        assert_eq!(request.certificates[0].credential, hw::CardanoCredential::Path(account.key_path(2, 0)));
        assert_eq!(request.certificates[0].pool, Some(vec![5; 28]));
        assert_eq!(request.validate(), Ok(hw::CardanoSigningMode::Ordinary));
    }

    #[test]
    fn foreign_stake_credential_is_rejected_for_ordinary_signing() {
        let mut certs = Certificates::new();
        certs.add(&Certificate::new_stake_delegation(&StakeDelegation::new(
            &Credential::from_keyhash(&Ed25519KeyHash::from_bytes(vec![9; 28]).unwrap()),
            &Ed25519KeyHash::from_bytes(vec![5; 28]).unwrap(),
        )));
        let mut body = base_body();
        body.set_certs(&certs);

        let (request, _) = transaction_request(&bytes(&body), &account(), &[path(0, 0)]).unwrap();

        assert!(matches!(request.validate(), Err(hw::CardanoTxRejection::Unsupported { .. })));
    }

    #[test]
    fn owned_required_signers_become_paths_and_foreign_ones_stay_hashes() {
        let account = account();
        let own = Ed25519KeyHash::from_bytes(account.key_hash(0, 0).unwrap()).unwrap();
        let foreign = Ed25519KeyHash::from_bytes(vec![7; 28]).unwrap();
        let mut signers = Ed25519KeyHashes::new();
        signers.add(&own);
        signers.add(&foreign);
        let mut body = base_body();
        body.set_required_signers(&signers);

        let (request, _) = transaction_request(&bytes(&body), &account, &[path(0, 0)]).unwrap();

        assert_eq!(request.required_signers.len(), 2);
        assert!(request.required_signers.contains(&hw::CardanoRequiredSigner::Path(account.key_path(0, 0))));
        assert!(request.required_signers.contains(&hw::CardanoRequiredSigner::KeyHash(vec![7; 28])));
    }

    #[test]
    fn address_types_map_to_message_headers() {
        let account = account();
        let payment = cardano_serialization_lib::Address::from_bech32(&cardano_base_address(
            cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap(),
            0,
            0,
            3,
        ).unwrap())
        .unwrap();

        let request = message_request(&payment.to_bytes(), vec![1, 2], &account, &path(0, 3)).unwrap();
        let header = request.address.clone().unwrap();

        assert_eq!(header.address_type, hw::CardanoMessageAddressType::Base);
        assert_eq!(header.path, account.key_path(0, 3));
        assert_eq!(header.staking_path, account.key_path(2, 0));
        assert_eq!(header.network_id, 0);
        assert!(request.signing_path == account.key_path(0, 3));
        assert!(request.validate().is_ok());
    }

    #[test]
    fn set_tags_are_read_from_the_inputs_entry() {
        // {0: 258([]), 2: 0}
        assert!(body_uses_set_tags(&[0xA2, 0x00, 0xD9, 0x01, 0x02, 0x80, 0x02, 0x00]));
        // {0: [], 2: 0}
        assert!(!body_uses_set_tags(&[0xA2, 0x00, 0x80, 0x02, 0x00]));
        // The inputs entry isn't first: {2: 0, 0: 258([])}
        assert!(body_uses_set_tags(&[0xA2, 0x02, 0x00, 0x00, 0xD9, 0x01, 0x02, 0x80]));
        // Truncated and non-map input are not tagged.
        assert!(!body_uses_set_tags(&[0xA2, 0x00]));
        assert!(!body_uses_set_tags(&[0x80]));
    }

    #[test]
    fn script_ref_content_unwraps_the_tag_24_byte_string() {
        // 24(h'820100')
        assert_eq!(script_ref_content(&[0xD8, 0x18, 0x43, 0x82, 0x01, 0x00]), Some(vec![0x82, 0x01, 0x00]));
        assert_eq!(script_ref_content(&[0x43, 0x82, 0x01, 0x00]), None);
    }

    #[test]
    fn skip_walks_nested_and_indefinite_items() {
        // [_ 1, {"a": h'00'}, 24(2)] followed by a marker byte
        let data = [0x9F, 0x01, 0xA1, 0x61, 0x61, 0x41, 0x00, 0xD8, 0x18, 0x02, 0xFF, 0xEE];
        assert_eq!(skip(&data, 0), Some(11));
    }
}
