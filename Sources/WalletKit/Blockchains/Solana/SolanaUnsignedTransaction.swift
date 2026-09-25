//
//  SolanaUnsignedTransaction.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// One token account a ``SolanaUnsignedTransaction``'s message touches —
/// carried alongside the raw message bytes so a Trezor's trusted screen
/// can show the mint/owner a transfer actually moves funds for, instead
/// of the opaque token-account address that appears on the wire. Unused
/// by ``SolanaPKeySigner``, which signs the message bytes directly.
public struct SolanaTokenAccountInfo: Codable, Equatable, Sendable {
    public let baseAddress: String
    public let tokenProgram: String
    public let tokenMint: String
    public let tokenAccount: String

    public init(baseAddress: String, tokenProgram: String, tokenMint: String, tokenAccount: String) {
        self.baseAddress = baseAddress
        self.tokenProgram = tokenProgram
        self.tokenMint = tokenMint
        self.tokenAccount = tokenAccount
    }
}

/// The JSON envelope ``SolanaTransactionBuilder`` returns as "unsigned
/// transaction bytes" — a legacy ``SolanaMessage``'s serialized bytes
/// (`message`, base64 via `JSONEncoder`'s default `Data` strategy) plus
/// the token-account metadata a hardware signer's trusted screen needs
/// (`tokenAccounts`, empty for a native SOL transfer).
///
/// A bare `SolanaMessage`'s bytes alone can't carry that metadata, so
/// every consumer — ``SolanaPKeySigner``, ``SolanaTrezorSigner``, and
/// ``SolanaRPCClient`` — decodes this envelope rather than treating the builder's
/// output as a raw message.
public struct SolanaUnsignedTransaction: Codable, Equatable, Sendable {
    public let message: Data
    public let tokenAccounts: [SolanaTokenAccountInfo]

    public init(message: Data, tokenAccounts: [SolanaTokenAccountInfo] = []) {
        self.message = message
        self.tokenAccounts = tokenAccounts
    }
}
