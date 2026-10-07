//
//  UnsignedEIP1559Transaction.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 29/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// An unsigned EIP-1559 (type-2) Ethereum transaction, serialized as the
/// `0x02`-prefixed type envelope accepted by
/// ``EthereumPKeySigner/sign(transaction:)``.
///
/// The signing preimage is:
/// ```
/// 0x02 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas,
///              gasLimit, to, value, data, []])
/// ```
/// where `[]` is an empty access list (`0xC0`). Wallet transfers never set
/// access-list entries; WalletKit transfer builders use an empty list.
///
/// ``EthereumTransactionBuilder`` builds this structure when the default
/// options are used (i.e. `options` does not contain `.legacyEip155`).
/// Cross-checked against `WalletKit/TestVectors/ethereum-tx.json` vectors
/// (those with `"type": 2`) in `EIP1559TransactionTests.swift`.
public struct UnsignedEIP1559Transaction: Sendable {
    /// The sending address's transaction count.
    public let nonce: BigUInt
    /// EIP-1559 miner tip cap in wei per gas unit — from
    /// ``EthereumRPCClient/feeRates()``.
    public let maxPriorityFeePerGas: BigUInt
    /// EIP-1559 total fee cap in wei per gas unit — `baseFee * 2 + tip` from
    /// ``EthereumRPCClient/feeRates()``.
    public let maxFeePerGas: BigUInt
    /// Maximum gas units this transaction may consume.
    public let gasLimit: BigUInt
    /// The destination address, or `nil` for contract creation.
    public let to: EthereumAddress?
    /// Native ETH value in wei.
    public let value: BigUInt
    /// ABI-encoded call data for contract calls, or empty for plain ETH transfers.
    public let data: Data
    /// The EVM chain ID — embedded in the signing preimage for EIP-2718 typed
    /// envelopes.
    public let chainId: UInt64

    public init(
        nonce: BigUInt,
        maxPriorityFeePerGas: BigUInt,
        maxFeePerGas: BigUInt,
        gasLimit: BigUInt,
        to: EthereumAddress?,
        value: BigUInt,
        data: Data,
        chainId: UInt64
    ) {
        self.nonce = nonce
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
        self.chainId = chainId
    }

    /// `0x02 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas,
    ///               gasLimit, to, value, data, []])` — exactly what
    /// ``EthereumPKeySigner/sign(transaction:)`` and
    /// ``EthereumTrezorSigner/sign(transaction:)`` expect for EIP-1559
    /// transactions.
    ///
    /// The trailing `[]` (encoded as `0xC0`) is the empty access list
    /// required by the EIP-1559 signing spec.
    public var signingData: Data {
        Data([0x02]) + RLP.encodeList([
            RLP.encode(BigUInt(chainId).serialize()),
            RLP.encode(nonce.serialize()),
            RLP.encode(maxPriorityFeePerGas.serialize()),
            RLP.encode(maxFeePerGas.serialize()),
            RLP.encode(gasLimit.serialize()),
            RLP.encode(to?.rawBytes ?? Data()),
            RLP.encode(value.serialize()),
            RLP.encode(data),
            RLP.encodeList([]) // empty access list = 0xC0
        ])
    }
}
