use std::sync::Arc;

use walletkit_hardware as hw;

use crate::{
    blockchain_clients::{EthereumEIP1559SignTxFfi, EthereumEIP1559SignatureFfi, EthereumSignTxFfi, EthereumSignatureFfi},
    common::{BigIntFfi, CurveFfi, DerivationPath},
    errors::WalletKitErrorFfi,
    keys::PublicKeyFfi,
};

use super::types::HardwareDeviceInfoFfi;

/// A connected hardware wallet — a source of public keys and signatures,
/// read from / produced by the device rather than derived or computed
/// in-process. Obtained from `HardwareDeviceManagerFfi::connect`.
#[derive(uniffi::Object)]
pub struct HardwareDeviceFfi {
    pub(super) inner: Arc<dyn hw::HardwareDevice>,
}

#[uniffi::export(async_runtime = "tokio")]
impl HardwareDeviceFfi {
    /// Static metadata describing this device.
    pub fn info(&self) -> HardwareDeviceInfoFfi {
        self.inner.info().into()
    }

    /// Whether this device is still connected.
    pub fn is_connected(&self) -> bool {
        self.inner.is_connected()
    }

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// Throws `.unsupportedDevice` for a curve the device can't derive
    /// (Trezor only supports secp256k1 today), `.deviceDisconnected` if
    /// the device has gone away, `.userCancelled`/`.userRejectedOnDevice`
    /// if the user backs out of a PIN/passphrase/confirmation prompt, or
    /// other hardware-wallet `WalletKitError` cases.
    pub async fn public_key(
        &self,
        path: DerivationPath,
        curve: CurveFfi,
    ) -> Result<Arc<PublicKeyFfi>, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let raw_bytes = self.inner.public_key(segments, to_hardware_curve(curve)).await?;
        Ok(Arc::new(PublicKeyFfi::new(curve, raw_bytes)))
    }

    /// Signs an Ethereum transaction on the device, showing `tx`'s fields
    /// (as `decode_signing_data` on `EthereumSignerFfi` recovered them)
    /// on its trusted screen for the user to confirm.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs
    /// out, `.deviceDisconnected` if the device goes away mid-signature,
    /// or `.signingFailed` if the device reports a protocol-level failure.
    pub async fn ethereum_sign_tx(
        &self,
        path: DerivationPath,
        tx: EthereumSignTxFfi,
    ) -> Result<EthereumSignatureFfi, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let fields = to_ethereum_tx_fields(tx)?;
        let signature = self.inner.ethereum_sign_tx(segments, fields).await?;
        Ok(EthereumSignatureFfi { v: signature.v, r: signature.r, s: signature.s })
    }

    /// Signs an EIP-1559 (type-2) Ethereum transaction on the device, showing
    /// `tx`'s fields on its trusted screen for the user to confirm.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs out,
    /// `.deviceDisconnected` if the device goes away mid-signature, or
    /// `.signingFailed` if the device reports a protocol-level failure.
    pub async fn ethereum_sign_tx_eip1559(
        &self,
        path: DerivationPath,
        tx: EthereumEIP1559SignTxFfi,
    ) -> Result<EthereumEIP1559SignatureFfi, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let fields = to_ethereum_eip1559_tx_fields(tx)?;
        let signature = self.inner.ethereum_sign_tx_eip1559(segments, fields).await?;
        Ok(EthereumEIP1559SignatureFfi { y_parity: signature.y_parity, r: signature.r, s: signature.s })
    }

    /// Disconnects from this device.
    pub async fn disconnect(&self) {
        self.inner.disconnect().await
    }
}

fn to_hardware_segments(path: &DerivationPath) -> Vec<hw::HardwarePathSegment> {
    path.segments.iter().map(|segment| hw::HardwarePathSegment { index: segment.index, hardened: segment.hardened }).collect()
}

fn to_hardware_curve(curve: CurveFfi) -> hw::HardwareCurve {
    match curve {
        CurveFfi::Secp256k1 => hw::HardwareCurve::Secp256k1,
        CurveFfi::Ed25519 => hw::HardwareCurve::Ed25519,
    }
}

fn to_ethereum_tx_fields(tx: EthereumSignTxFfi) -> Result<hw::EthereumTxFields, WalletKitErrorFfi> {
    Ok(hw::EthereumTxFields {
        nonce: nonnegative_be_bytes(&tx.nonce)?,
        gas_price: nonnegative_be_bytes(&tx.gas_price)?,
        gas_limit: nonnegative_be_bytes(&tx.gas_limit)?,
        to: tx.to,
        value: nonnegative_be_bytes(&tx.value)?,
        data: tx.data,
        chain_id: tx.chain_id,
    })
}

fn to_ethereum_eip1559_tx_fields(tx: EthereumEIP1559SignTxFfi) -> Result<hw::EthereumEIP1559TxFields, WalletKitErrorFfi> {
    Ok(hw::EthereumEIP1559TxFields {
        nonce: nonnegative_be_bytes(&tx.nonce)?,
        max_priority_fee_per_gas: nonnegative_be_bytes(&tx.max_priority_fee_per_gas)?,
        max_fee_per_gas: nonnegative_be_bytes(&tx.max_fee_per_gas)?,
        gas_limit: nonnegative_be_bytes(&tx.gas_limit)?,
        to: tx.to,
        value: nonnegative_be_bytes(&tx.value)?,
        data: tx.data,
        chain_id: tx.chain_id,
    })
}

/// `BigIntFfi::magnitude_be_bytes` is already the minimal big-endian
/// encoding the device's wire protocol expects; every field is
/// non-negative by construction (decoded from unsigned RLP `U256`s),
/// so this only guards against a value that shouldn't be able to occur.
fn nonnegative_be_bytes(value: &BigIntFfi) -> Result<Vec<u8>, WalletKitErrorFfi> {
    if value.negative {
        return Err(WalletKitErrorFfi::SigningFailed {
            reason: "expected a non-negative integer for a hardware-signed Ethereum field".to_string(),
        });
    }
    Ok(value.magnitude_be_bytes.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::Segment;

    #[test]
    fn to_hardware_curve_maps_every_curve() {
        assert_eq!(to_hardware_curve(CurveFfi::Secp256k1), hw::HardwareCurve::Secp256k1);
        assert_eq!(to_hardware_curve(CurveFfi::Ed25519), hw::HardwareCurve::Ed25519);
    }

    #[test]
    fn to_hardware_segments_preserves_index_and_hardened_flags() {
        let path = DerivationPath {
            segments: vec![Segment { index: 44, hardened: true }, Segment { index: 0, hardened: false }],
        };
        let segments = to_hardware_segments(&path);
        assert_eq!(segments, vec![
            hw::HardwarePathSegment { index: 44, hardened: true },
            hw::HardwarePathSegment { index: 0, hardened: false },
        ]);
    }

    #[test]
    fn nonnegative_be_bytes_passes_through_the_magnitude() {
        let value = BigIntFfi::from(42u64);
        assert_eq!(nonnegative_be_bytes(&value).unwrap(), value.magnitude_be_bytes);
    }

    #[test]
    fn nonnegative_be_bytes_rejects_a_negative_value() {
        let negative = BigIntFfi { magnitude_be_bytes: vec![1], negative: true };
        assert!(matches!(nonnegative_be_bytes(&negative), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }

    #[test]
    fn to_ethereum_tx_fields_converts_every_field() {
        let tx = EthereumSignTxFfi {
            nonce: BigIntFfi::from(1u64),
            gas_price: BigIntFfi::from(2u64),
            gas_limit: BigIntFfi::from(3u64),
            to: Some(vec![0xab; 20]),
            value: BigIntFfi::from(4u64),
            data: vec![0xde, 0xad],
            chain_id: 11_155_111,
        };
        let fields = to_ethereum_tx_fields(tx).unwrap();
        assert_eq!(fields.nonce, vec![1]);
        assert_eq!(fields.gas_price, vec![2]);
        assert_eq!(fields.gas_limit, vec![3]);
        assert_eq!(fields.to, Some(vec![0xab; 20]));
        assert_eq!(fields.value, vec![4]);
        assert_eq!(fields.data, vec![0xde, 0xad]);
        assert_eq!(fields.chain_id, 11_155_111);
    }

    #[test]
    fn to_ethereum_eip1559_tx_fields_converts_every_field() {
        let tx = EthereumEIP1559SignTxFfi {
            nonce: BigIntFfi::from(1u64),
            max_priority_fee_per_gas: BigIntFfi::from(2u64),
            max_fee_per_gas: BigIntFfi::from(3u64),
            gas_limit: BigIntFfi::from(4u64),
            to: Some(vec![0xab; 20]),
            value: BigIntFfi::from(5u64),
            data: vec![0xde, 0xad],
            chain_id: 11_155_111,
        };
        let fields = to_ethereum_eip1559_tx_fields(tx).unwrap();
        assert_eq!(fields.nonce, vec![1]);
        assert_eq!(fields.max_priority_fee_per_gas, vec![2]);
        assert_eq!(fields.max_fee_per_gas, vec![3]);
        assert_eq!(fields.gas_limit, vec![4]);
        assert_eq!(fields.to, Some(vec![0xab; 20]));
        assert_eq!(fields.value, vec![5]);
        assert_eq!(fields.data, vec![0xde, 0xad]);
        assert_eq!(fields.chain_id, 11_155_111);
    }
}
