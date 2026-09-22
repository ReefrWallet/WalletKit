//! Stand-in for `macos`'s real Trezor implementation on every other
//! target. See this crate's top-level doc comment for why.

use std::sync::Arc;

use async_trait::async_trait;
use walletkit_hardware::{
    CardanoTxFields, CardanoWitness, EthereumEIP1559Signature, EthereumEIP1559TxFields, EthereumSignature, EthereumTxFields,
    HardwareBitcoinNetwork, HardwareCurve, HardwareDevice as HardwareDeviceTrait, HardwareDeviceDelegate,
    HardwareDeviceInfo, HardwareDeviceManager as HardwareDeviceManagerTrait, HardwareError,
    HardwarePathSegment, HardwareTransportKind, HardwareVendor, SolanaTxFields, TronTxFields,
};

fn unavailable() -> HardwareError {
    HardwareError::TransportUnavailable {
        reason: "Trezor USB is only supported on macOS; iOS has no MFi-certified USB HID access \
                 (see Docs/Overview.md's \"Transport and platform constraints\")"
            .to_string(),
    }
}

/// Discovers and connects to Trezor devices. Always empty/unavailable on
/// this platform — see the crate-level doc comment.
#[derive(Default)]
pub struct TrezorManager;

impl TrezorManager {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl HardwareDeviceManagerTrait for TrezorManager {
    async fn scan(
        &self,
        _vendors: Vec<HardwareVendor>,
        _transports: Vec<HardwareTransportKind>,
    ) -> Result<Vec<HardwareDeviceInfo>, HardwareError> {
        Ok(Vec::new())
    }

    async fn connect(
        &self,
        _info: HardwareDeviceInfo,
        _delegate: Arc<dyn HardwareDeviceDelegate>,
    ) -> Result<Arc<dyn HardwareDeviceTrait>, HardwareError> {
        Err(unavailable())
    }
}

/// Never constructed on this platform — `TrezorManager::connect` always
/// fails before producing one. Exists only so the type name resolves the
/// same way on every platform.
pub struct TrezorDevice {
    _private: (),
}

#[async_trait]
impl HardwareDeviceTrait for TrezorDevice {
    fn info(&self) -> HardwareDeviceInfo {
        unreachable!("TrezorDevice is never constructed on this platform")
    }

    fn is_connected(&self) -> bool {
        false
    }

    async fn public_key(
        &self,
        _path: Vec<HardwarePathSegment>,
        _curve: HardwareCurve,
    ) -> Result<Vec<u8>, HardwareError> {
        Err(unavailable())
    }

    async fn ethereum_sign_tx(
        &self,
        _path: Vec<HardwarePathSegment>,
        _fields: EthereumTxFields,
    ) -> Result<EthereumSignature, HardwareError> {
        Err(unavailable())
    }

    async fn ethereum_sign_tx_eip1559(
        &self,
        _path: Vec<HardwarePathSegment>,
        _fields: EthereumEIP1559TxFields,
    ) -> Result<EthereumEIP1559Signature, HardwareError> {
        Err(unavailable())
    }

    async fn tron_sign_tx(
        &self,
        _path: Vec<HardwarePathSegment>,
        _fields: TronTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        Err(unavailable())
    }

    async fn solana_sign_tx(
        &self,
        _path: Vec<HardwarePathSegment>,
        _fields: SolanaTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        Err(unavailable())
    }

    async fn cardano_xpub(&self, _path: Vec<HardwarePathSegment>) -> Result<String, HardwareError> {
        Err(unavailable())
    }

    async fn cardano_sign_tx(&self, _fields: CardanoTxFields) -> Result<Vec<CardanoWitness>, HardwareError> {
        Err(unavailable())
    }

    async fn bitcoin_xpub(&self, _path: Vec<HardwarePathSegment>) -> Result<String, HardwareError> {
        Err(unavailable())
    }

    async fn bitcoin_sign_psbt(
        &self,
        _psbt: Vec<u8>,
        _network: HardwareBitcoinNetwork,
    ) -> Result<Vec<u8>, HardwareError> {
        Err(unavailable())
    }

    async fn disconnect(&self) {}
}
