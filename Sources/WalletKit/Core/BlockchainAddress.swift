//
//  BlockchainAddress.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation
import WalletKitRust

/// A validated, chain-specific address (e.g. ``EthereumAddress``, ``SuiAddress``).
///
/// All conformers are expected to be value types (`struct`), so `Sendable`
/// is required — this lets `FeeEstimateRequest<Address>` and
/// `AnyBlockchainClient`'s closures be `Sendable` without extra constraints.
public protocol BlockchainAddress: Equatable, Sendable {
    /// The chain's canonical string encoding of this address (e.g.
    /// EIP-55 checksummed hex for Ethereum).
    var string: String { get }

    /// The address's raw byte encoding.
    var rawBytes: Data { get }

    /// Parses and validates `string` as an address for this chain.
    ///
    /// - Parameter string: The address string to parse.
    init(string: String) throws

    /// Wraps `rawBytes` as an address for this chain.
    ///
    /// - Parameter rawBytes: The raw address bytes.
    init(rawBytes: Data) throws
}
