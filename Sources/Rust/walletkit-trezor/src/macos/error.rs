use trezor_client::protos::{failure::FailureType, Failure};
use walletkit_hardware::HardwareError;

/// Maps a `trezor-client` error onto the vendor-agnostic `HardwareError`
/// `walletkit-hardware` (and, through it, `WalletKitErrorFfi`) expects.
pub(super) fn map_trezor_error(error: trezor_client::Error) -> HardwareError {
    match error {
        trezor_client::Error::NoDeviceFound => HardwareError::NotFound,
        trezor_client::Error::DeviceNotUnique => {
            HardwareError::UnsupportedDevice { reason: "multiple Trezor devices found".to_string() }
        }
        trezor_client::Error::MalformedSignature => {
            HardwareError::SigningFailed { reason: "device returned an invalid signature".to_string() }
        }
        trezor_client::Error::TransportConnect(_)
        | trezor_client::Error::TransportBeginSession(_)
        | trezor_client::Error::TransportEndSession(_)
        | trezor_client::Error::TransportSendMessage(_)
        | trezor_client::Error::TransportReceiveMessage(_) => HardwareError::Disconnected,
        trezor_client::Error::FailureResponse(failure) => map_failure(&failure),
        other => HardwareError::TransportUnavailable { reason: other.to_string() },
    }
}

pub(super) fn map_failure(failure: &Failure) -> HardwareError {
    match failure.code() {
        FailureType::Failure_ActionCancelled => HardwareError::UserRejectedOnDevice,
        FailureType::Failure_Busy | FailureType::Failure_InProgress => HardwareError::Busy,
        FailureType::Failure_PinInvalid | FailureType::Failure_PinMismatch => HardwareError::Locked,
        FailureType::Failure_NotInitialized => {
            HardwareError::UnsupportedDevice { reason: "device is not initialized".to_string() }
        }
        _ => HardwareError::SigningFailed {
            reason: format!("device returned a failure: {}", failure.message()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_cancelled_maps_to_user_rejected_on_device() {
        let mut failure = Failure::new();
        failure.set_code(FailureType::Failure_ActionCancelled);
        assert_eq!(map_failure(&failure), HardwareError::UserRejectedOnDevice);
    }

    #[test]
    fn busy_maps_to_busy() {
        let mut failure = Failure::new();
        failure.set_code(FailureType::Failure_Busy);
        assert_eq!(map_failure(&failure), HardwareError::Busy);
    }

    #[test]
    fn no_device_found_maps_to_not_found() {
        assert_eq!(map_trezor_error(trezor_client::Error::NoDeviceFound), HardwareError::NotFound);
    }
}
