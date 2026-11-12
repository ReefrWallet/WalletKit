//
//  HardwareLogging.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 13/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKitRust

/// Opt-in diagnostics from the hardware wallet code.
public enum HardwareLogging {
    /// Starts delivering hardware diagnostics to `handler`, which may be
    /// called from any thread, or stops them with `nil`. Off by default.
    public static func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        setHardwareLogger(logger: handler.map(HardwareLoggerBridge.init(handler:)))
    }
}

private final class HardwareLoggerBridge: HardwareLoggerFfi {
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func log(message: String) {
        handler(message)
    }
}
