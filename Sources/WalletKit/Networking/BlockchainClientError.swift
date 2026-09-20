//
//  BlockchainClientError.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Failures from talking to a blockchain node — JSON-RPC (Ethereum) or
/// gRPC (Sui).
///
/// Kept deliberately separate from ``WalletKitError``: that type's own
/// doc comment scopes it to software key-management and hardware-device
/// failures, and every one of its cases is generated 1:1 from the Rust
/// `WalletKitErrorFfi` — there is no Rust error to map from here, since
/// node clients never cross the FFI boundary.
public enum BlockchainClientError: Error, Equatable {
    /// The underlying transport (`URLSession`, a gRPC channel) failed
    /// before a response was received — no connectivity, a timeout, TLS
    /// failure, etc. `reason` is the underlying error's description.
    case transportError(reason: String)

    /// The transport succeeded but the response wasn't usable — a
    /// non-2xx HTTP status, or a response missing both `result` and
    /// `error`. `reason` describes what went wrong.
    case invalidResponse(reason: String)

    /// The node explicitly rejected the call — a JSON-RPC `error` object
    /// or a gRPC `Status`. `code` is the JSON-RPC error code or the gRPC
    /// status code's raw value; `message` is the node's message.
    case rpcError(code: Int, message: String)

    /// The call succeeded and returned a result, but it couldn't be
    /// parsed into the shape the caller expected (bad hex, wrong ABI word
    /// count, ...). `reason` describes what went wrong.
    case decodingFailed(reason: String)
}
