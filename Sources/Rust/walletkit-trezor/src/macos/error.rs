use trezor_client::{
    protos::{failure::FailureType, Failure},
    transport::error::Error as TransportError,
};
use walletkit_hardware::{hw_log, HardwareError};

/// Maps a `trezor-client` error onto the vendor-agnostic `HardwareError`
/// `walletkit-hardware` (and, through it, `WalletKitErrorFfi`) expects.
pub(super) fn map_trezor_error(error: trezor_client::Error) -> HardwareError {
    let mapped = map_error_kind(&error);
    hw_log!("trezor error {error:?} ({error}) -> {mapped:?}");
    mapped
}

/// Whether a transport error means the device itself is gone, as opposed to
/// a transient read/write problem on a device that is still attached.
fn is_device_gone(error: &TransportError) -> bool {
    matches!(
        error,
        TransportError::DeviceNotFound
            | TransportError::DeviceDisconnected
            | TransportError::Usb(rusb::Error::NoDevice | rusb::Error::Io | rusb::Error::Pipe)
    )
}

fn map_error_kind(error: &trezor_client::Error) -> HardwareError {
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
        | trezor_client::Error::TransportEndSession(_) => HardwareError::Disconnected,
        trezor_client::Error::TransportSendMessage(source) | trezor_client::Error::TransportReceiveMessage(source) => {
            if is_device_gone(source) {
                HardwareError::Disconnected
            } else {
                HardwareError::TransportUnavailable { reason: error.to_string() }
            }
        }
        trezor_client::Error::FailureResponse(failure) => map_failure(failure),
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
    fn read_timeout_is_not_a_disconnect() {
        let error = trezor_client::Error::TransportReceiveMessage(TransportError::DeviceReadTimeout);
        assert!(matches!(map_trezor_error(error), HardwareError::TransportUnavailable { .. }));
    }

    #[test]
    fn missing_usb_device_is_a_disconnect() {
        let error = trezor_client::Error::TransportSendMessage(TransportError::Usb(rusb::Error::NoDevice));
        assert_eq!(map_trezor_error(error), HardwareError::Disconnected);
    }

    #[test]
    fn no_device_found_maps_to_not_found() {
        assert_eq!(map_trezor_error(trezor_client::Error::NoDeviceFound), HardwareError::NotFound);
    }
}
