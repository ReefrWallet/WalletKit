//
//  EthereumSignTx.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKitRust

/// The structured fields of an Ethereum transaction, decoded from EIP-155
/// signing data — what a hardware device's trusted screen needs to display
/// before it signs. `to == nil` is a contract-creation transaction.
public struct EthereumSignTx {
    public let nonce: BigUInt
    public let gasPrice: BigUInt
    public let gasLimit: BigUInt
    public let to: EthereumAddress?
    public let value: BigUInt
    public let data: Data
    public let chainId: UInt64

    init(raw: EthereumSignTxFfi) throws {
        // EIP-155 signing data's nonce/gasPrice/gasLimit/value fields are
        // always non-negative U256s, so these conversions never fail.
        nonce = BigUInt(raw.nonce)!
        gasPrice = BigUInt(raw.gasPrice)!
        gasLimit = BigUInt(raw.gasLimit)!
        to = try raw.to.map { try EthereumAddress(rawBytes: $0) }
        value = BigUInt(raw.value)!
        data = raw.data
        chainId = raw.chainId
    }
}

/// An EIP-155 signature, in the shape a hardware device returns it — the
/// pieces ``EthereumTrezorSigner/signedTransaction(_:signature:)`` needs to
/// re-assemble a broadcastable signed transaction.
public struct EthereumSignature {
    /// The EIP-155 recovery/chain-id-encoding value.
    public let v: UInt64

    /// The 32-byte `r` component.
    public let r: Data

    /// The 32-byte `s` component.
    public let s: Data

    /// Creates a signature from its components.
    ///
    /// - Parameters:
    ///   - v: The EIP-155 recovery/chain-id-encoding value.
    ///   - r: The 32-byte `r` component.
    ///   - s: The 32-byte `s` component.
    public init(v: UInt64, r: Data, s: Data) {
        self.v = v
        self.r = r
        self.s = s
    }

    var raw: EthereumSignatureFfi { EthereumSignatureFfi(v: v, r: r, s: s) }
}

// MARK: - EIP-1559

/// The structured fields of an unsigned EIP-1559 (type-2) Ethereum
/// transaction, decoded from the `0x02`-prefixed signing preimage — what a
/// hardware device's trusted screen needs to display before it signs.
/// `to == nil` is a contract-creation transaction.
public struct EthereumEIP1559SignTx {
    public let nonce: BigUInt
    public let maxPriorityFeePerGas: BigUInt
    public let maxFeePerGas: BigUInt
    public let gasLimit: BigUInt
    public let to: EthereumAddress?
    public let value: BigUInt
    public let data: Data
    public let chainId: UInt64

    init(raw: EthereumEip1559SignTxFfi) throws {
        nonce = BigUInt(raw.nonce)!
        maxPriorityFeePerGas = BigUInt(raw.maxPriorityFeePerGas)!
        maxFeePerGas = BigUInt(raw.maxFeePerGas)!
        gasLimit = BigUInt(raw.gasLimit)!
        to = try raw.to.map { try EthereumAddress(rawBytes: $0) }
        value = BigUInt(raw.value)!
        data = raw.data
        chainId = raw.chainId
    }
}

/// An EIP-1559 signature — `yParity` is the raw secp256k1 recovery id
/// (0 or 1), without the EIP-155 `chainId * 2 + 35` folding. `r` and `s`
/// are 32-byte big-endian.
public struct EthereumEIP1559Signature {
    /// The raw secp256k1 recovery id: 0 or 1.
    public let yParity: UInt64

    /// The 32-byte `r` component.
    public let r: Data

    /// The 32-byte `s` component.
    public let s: Data

    public init(yParity: UInt64, r: Data, s: Data) {
        self.yParity = yParity
        self.r = r
        self.s = s
    }

    var raw: EthereumEip1559SignatureFfi {
        EthereumEip1559SignatureFfi(yParity: yParity, r: r, s: s)
    }
}
