//
//  UnsignedLegacyTransaction.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// The 9-field EIP-155 legacy Ethereum transaction, serialized as
/// `RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0])` —
/// exactly the format ``EthereumPKeySigner/sign(transaction:)`` and
/// ``EthereumTrezorSigner/sign(transaction:)`` expect as their
/// `transaction` input.
///
/// Use ``UnsignedEIP1559Transaction`` for typed transactions.
/// ``EthereumTransactionBuilder`` builds this structure when its options
/// request legacy EIP-155 signing and returns ``signingData`` ready for a
/// signer.
///
/// Cross-checked against `WalletKit/TestVectors/ethereum-tx.json` vectors
/// in `LegacyTransactionTests.swift` before ever being trusted against a
/// live Anvil node.
public struct UnsignedLegacyTransaction: Sendable {
    /// The sending address's transaction count (its next-transaction nonce).
    public let nonce: BigUInt
    /// Gas price in wei per gas unit — from `eth_gasPrice` or
    /// ``EthereumRPCClient/estimateFee(for:)``.
    public let gasPrice: BigUInt
    /// Maximum gas units this transaction may consume.
    public let gasLimit: BigUInt
    /// The destination address, or `nil` for contract creation.
    public let to: EthereumAddress?
    /// Native ETH value in wei.
    public let value: BigUInt
    /// ABI-encoded call data for contract calls, or empty for plain ETH
    /// transfers.
    public let data: Data
    /// The EVM chain ID — written into the signing preimage for EIP-155
    /// replay protection.
    public let chainId: UInt64

    public init(
        nonce: BigUInt,
        gasPrice: BigUInt,
        gasLimit: BigUInt,
        to: EthereumAddress?,
        value: BigUInt,
        data: Data,
        chainId: UInt64
    ) {
        self.nonce = nonce
        self.gasPrice = gasPrice
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
        self.chainId = chainId
    }

    /// `RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0])` —
    /// exactly what ``EthereumPKeySigner/sign(transaction:)`` expects.
    ///
    /// The trailing `[chainId, 0, 0]` is the EIP-155 replay-protection
    /// suffix; `chainId` replaces the `v` field in the unsigned preimage so
    /// the signer can embed it into the final `v` during signing.
    public var signingData: Data {
        RLP.encodeList([
            RLP.encode(nonce.serialize()),
            RLP.encode(gasPrice.serialize()),
            RLP.encode(gasLimit.serialize()),
            RLP.encode(to?.rawBytes ?? Data()),
            RLP.encode(value.serialize()),
            RLP.encode(data),
            RLP.encode(BigUInt(chainId).serialize()),
            RLP.encode(Data()),
            RLP.encode(Data())
        ])
    }
}
