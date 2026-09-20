//! `WalletKitErrorFfi`. See
//! `Walletkit/Docs/Design Specification/Errors/WalletKitError.swift` for
//! the target shape (a single error enum covering both software
//! key-management and hardware-device failure cases).

mod wallet_kit_error;

pub use wallet_kit_error::WalletKitErrorFfi;
