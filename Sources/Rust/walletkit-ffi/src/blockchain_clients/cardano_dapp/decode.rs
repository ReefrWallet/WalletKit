//! Fail-closed decoding of a dapp-supplied transaction for the approval preview.

use cardano_serialization_lib::{Address, Certificate, CertificateKind, Credential, FixedTransaction, TransactionOutput};

use crate::blockchain_clients::cardano::{invalid_address, signing_failed, value_assets, CardanoAssetFfi};
use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoDappInputFfi {
    pub output_index: u32,
    pub tx_hash: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoDappOutputFfi {
    pub address: String,
    pub assets: Vec<CardanoAssetFfi>,
    pub datum_hash: Option<Vec<u8>>,
    pub has_reference_script: bool,
    pub inline_datum: Option<Vec<u8>>,
    pub lovelace: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoDappCertificateFfi {
    pub credential: Option<Vec<u8>>,
    pub credential_is_script: bool,
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoDappWithdrawalFfi {
    pub lovelace: String,
    pub reward_address: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoDappTransactionFfi {
    pub auxiliary_data_hash: Option<Vec<u8>>,
    pub body_hash: Vec<u8>,
    pub certificates: Vec<CardanoDappCertificateFfi>,
    pub collateral: Vec<CardanoDappInputFfi>,
    pub collateral_return: Option<CardanoDappOutputFfi>,
    pub fee: String,
    pub has_scripts: bool,
    pub inputs: Vec<CardanoDappInputFfi>,
    pub is_valid: bool,
    /// Signed quantities: negative means burn.
    pub mint: Vec<CardanoAssetFfi>,
    pub network_id: Option<u8>,
    pub outputs: Vec<CardanoDappOutputFfi>,
    pub reference_inputs: Vec<CardanoDappInputFfi>,
    pub required_signers: Vec<Vec<u8>>,
    pub script_data_hash: Option<Vec<u8>>,
    pub total_collateral: Option<String>,
    pub ttl: Option<String>,
    pub validity_start: Option<String>,
    pub voting_procedure_count: u32,
    pub voting_proposal_count: u32,
    pub withdrawals: Vec<CardanoDappWithdrawalFfi>,
}

/// What a certificate demands from the signer.
pub(crate) enum CertificateRequirement {
    /// Needs no witness (legacy registration).
    None,
    /// Needs a witness for this stake credential.
    Credential(Credential),
    /// Pool, governance and genesis certificates: keys we don't derive.
    Foreign,
}

/// Parses `transaction`, rejecting anything that doesn't round-trip to the
/// same length, which catches trailing bytes after the transaction array.
pub(crate) fn parse_transaction(transaction: &[u8]) -> Result<FixedTransaction, WalletKitErrorFfi> {
    let fixed = FixedTransaction::from_bytes(transaction.to_vec()).map_err(signing_failed)?;
    if fixed.to_bytes().len() != transaction.len() {
        return Err(signing_failed("Cardano transaction has trailing bytes"));
    }

    Ok(fixed)
}

pub(crate) fn certificate_requirement(certificate: &Certificate) -> CertificateRequirement {
    match certificate.kind() {
        CertificateKind::StakeRegistration => certificate
            .as_reg_cert()
            .map_or(CertificateRequirement::None, |c| CertificateRequirement::Credential(c.stake_credential())),
        CertificateKind::StakeDeregistration => certificate
            .as_stake_deregistration()
            .map_or(CertificateRequirement::Foreign, |c| CertificateRequirement::Credential(c.stake_credential())),
        CertificateKind::StakeDelegation => certificate
            .as_stake_delegation()
            .map_or(CertificateRequirement::Foreign, |c| CertificateRequirement::Credential(c.stake_credential())),
        CertificateKind::StakeAndVoteDelegation => certificate
            .as_stake_and_vote_delegation()
            .map_or(CertificateRequirement::Foreign, |c| CertificateRequirement::Credential(c.stake_credential())),
        CertificateKind::StakeRegistrationAndDelegation => {
            certificate.as_stake_registration_and_delegation().map_or(CertificateRequirement::Foreign, |c| {
                CertificateRequirement::Credential(c.stake_credential())
            })
        }
        CertificateKind::StakeVoteRegistrationAndDelegation => certificate
            .as_stake_vote_registration_and_delegation()
            .map_or(CertificateRequirement::Foreign, |c| CertificateRequirement::Credential(c.stake_credential())),
        CertificateKind::VoteDelegation => certificate
            .as_vote_delegation()
            .map_or(CertificateRequirement::Foreign, |c| CertificateRequirement::Credential(c.stake_credential())),
        CertificateKind::VoteRegistrationAndDelegation => certificate
            .as_vote_registration_and_delegation()
            .map_or(CertificateRequirement::Foreign, |c| CertificateRequirement::Credential(c.stake_credential())),
        CertificateKind::PoolRegistration
        | CertificateKind::PoolRetirement
        | CertificateKind::GenesisKeyDelegation
        | CertificateKind::MoveInstantaneousRewardsCert
        | CertificateKind::CommitteeHotAuth
        | CertificateKind::CommitteeColdResign
        | CertificateKind::DRepDeregistration
        | CertificateKind::DRepRegistration
        | CertificateKind::DRepUpdate => CertificateRequirement::Foreign,
    }
}

fn address_string(address: &Address) -> Result<String, WalletKitErrorFfi> {
    match address.to_bech32(None) {
        Ok(bech32) => Ok(bech32),
        // Byron addresses have no bech32 form.
        Err(_) => Ok(hex::encode(address.to_bytes())),
    }
}

fn decode_output(output: &TransactionOutput) -> Result<CardanoDappOutputFfi, WalletKitErrorFfi> {
    let amount = output.amount();

    Ok(CardanoDappOutputFfi {
        address: address_string(&output.address())?,
        assets: value_assets(&amount),
        datum_hash: output.data_hash().map(|hash| hash.to_bytes()),
        has_reference_script: output.script_ref().is_some(),
        inline_datum: output.plutus_data().map(|data| data.to_bytes()),
        lovelace: amount.coin().to_str(),
    })
}

fn decode_inputs(inputs: &cardano_serialization_lib::TransactionInputs) -> Vec<CardanoDappInputFfi> {
    (0..inputs.len())
        .map(|index| {
            let input = inputs.get(index);
            CardanoDappInputFfi {
                output_index: input.index(),
                tx_hash: input.transaction_id().to_bytes(),
            }
        })
        .collect()
}

fn credential_bytes(credential: &Credential) -> (Option<Vec<u8>>, bool) {
    match (credential.to_keyhash(), credential.to_scripthash()) {
        (Some(hash), _) => (Some(hash.to_bytes()), false),
        (_, Some(hash)) => (Some(hash.to_bytes()), true),
        _ => (None, false),
    }
}

/// Returns the transaction hash of the dapp's original body bytes.
#[uniffi::export]
pub fn cardano_transaction_hash(transaction: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    Ok(parse_transaction(&transaction)?.transaction_hash().to_bytes())
}

/// Decodes `transaction` for the approval preview. Fails on trailing bytes
/// and on anything the underlying parser rejects; unknown optional fields are
/// never silently dropped because the preview carries the raw bytes too.
#[uniffi::export]
pub fn cardano_decode_transaction(transaction: Vec<u8>) -> Result<CardanoDappTransactionFfi, WalletKitErrorFfi> {
    let fixed = parse_transaction(&transaction)?;
    let body = fixed.body();
    let witnesses = fixed.witness_set();

    let outputs = body.outputs();
    let outputs = (0..outputs.len())
        .map(|index| decode_output(&outputs.get(index)))
        .collect::<Result<Vec<_>, _>>()?;

    let mut mint = vec![];
    if let Some(body_mint) = body.mint() {
        let policies = body_mint.keys();
        for policy_index in 0..policies.len() {
            let policy = policies.get(policy_index);
            let Some(assets) = body_mint.get(&policy) else {
                continue;
            };
            for assets in (0..assets.len()).map(|index| assets.get(index)) {
                let Some(assets) = assets else {
                    continue;
                };
                let names = assets.keys();
                for name_index in 0..names.len() {
                    let name = names.get(name_index);
                    let Some(quantity) = assets.get(&name) else {
                        continue;
                    };
                    mint.push(CardanoAssetFfi {
                        name: name.name(),
                        policy_id: policy.to_bytes(),
                        quantity: quantity.to_str(),
                    });
                }
            }
        }
    }

    let certificates = body.certs().map_or(Ok(vec![]), |certs| {
        (0..certs.len())
            .map(|index| {
                let certificate = certs.get(index);
                let credential = match certificate_requirement(&certificate) {
                    CertificateRequirement::Credential(credential) => credential_bytes(&credential),
                    CertificateRequirement::None | CertificateRequirement::Foreign => (None, false),
                };
                Ok(CardanoDappCertificateFfi {
                    credential: credential.0,
                    credential_is_script: credential.1,
                    kind: format!("{:?}", certificate.kind()),
                })
            })
            .collect::<Result<Vec<_>, WalletKitErrorFfi>>()
    })?;

    let withdrawals = body.withdrawals().map_or(Ok(vec![]), |withdrawals| {
        let accounts = withdrawals.keys();
        (0..accounts.len())
            .filter_map(|index| {
                let account = accounts.get(index);
                withdrawals.get(&account).map(|lovelace| (account, lovelace))
            })
            .map(|(account, lovelace)| {
                Ok(CardanoDappWithdrawalFfi {
                    lovelace: lovelace.to_str(),
                    reward_address: account.to_address().to_bech32(None).map_err(invalid_address)?,
                })
            })
            .collect::<Result<Vec<_>, WalletKitErrorFfi>>()
    })?;

    let required_signers = body.required_signers().map_or(vec![], |signers| {
        (0..signers.len()).map(|index| signers.get(index).to_bytes()).collect()
    });

    Ok(CardanoDappTransactionFfi {
        auxiliary_data_hash: body.auxiliary_data_hash().map(|hash| hash.to_bytes()),
        body_hash: fixed.transaction_hash().to_bytes(),
        certificates,
        collateral: body.collateral().map_or(vec![], |inputs| decode_inputs(&inputs)),
        collateral_return: body.collateral_return().map(|output| decode_output(&output)).transpose()?,
        fee: body.fee().to_str(),
        has_scripts: witnesses.native_scripts().is_some_and(|scripts| scripts.len() > 0)
            || witnesses.plutus_scripts().is_some_and(|scripts| scripts.len() > 0)
            || body.script_data_hash().is_some(),
        inputs: decode_inputs(&body.inputs()),
        is_valid: fixed.is_valid(),
        mint,
        network_id: body.network_id().map(|id| id.kind() as u8),
        outputs,
        reference_inputs: body.reference_inputs().map_or(vec![], |inputs| decode_inputs(&inputs)),
        required_signers,
        script_data_hash: body.script_data_hash().map(|hash| hash.to_bytes()),
        total_collateral: body.total_collateral().map(|coin| coin.to_str()),
        ttl: body.ttl_bignum().map(|slot| slot.to_str()),
        validity_start: body.validity_start_interval_bignum().map(|slot| slot.to_str()),
        voting_procedure_count: body.voting_procedures().map_or(0, |votes| votes.get_voters().len() as u32),
        voting_proposal_count: body.voting_proposals().map_or(0, |proposals| proposals.len() as u32),
        withdrawals,
    })
}
