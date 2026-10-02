//
//  MessageSigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 25/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
import Foundation

/// A message a dapp asked to sign, as opposed to a transaction. Each case
/// is one chain's wire format; a ``MessageSigner`` conformer only
/// implements the cases for its own chain.
public enum SignableMessage: Sendable {
    /// An EIP-191 personal message (`personal_sign`) — the raw message
    /// bytes, not yet hashed or prefixed.
    case ethereumPersonal(Data)

    /// An EIP-712 typed-data payload (`eth_signTypedData_v4`) — the
    /// `types`/`primaryType`/`domain`/`message` JSON payload, verbatim.
    case ethereumTypedData(json: String)

    /// A Solana off-chain message (`solana:signMessage`) — the raw
    /// message bytes, signed directly with no prefix (ed25519 signing
    /// hashes internally). The signer is not responsible for checking
    /// this isn't actually transaction/message-header bytes in disguise
    /// — that fail-closed check happens before signing, in
    /// `SolanaDappProvider`.
    case solanaMessage(Data)

    /// A Sui personal message (`sui:signPersonalMessage`) — the raw
    /// message bytes, not yet BCS-wrapped or intent-prefixed.
    case suiPersonal(Data)

    // Later: .tronV2, .cardanoCIP8, .bitcoinBIP322.
}

/// A ``Signer`` that can also sign a ``SignableMessage`` —
/// `personal_sign`/`eth_signTypedData_v4` and their per-chain equivalents.
/// Every chain's software and hardware signer conforms; conformers throw
/// ``WalletKitError/unsupportedFeature`` for message kinds that aren't
/// their own chain's.
public protocol MessageSigner: Signer {
    /// Signs `message` with this signer's key.
    ///
    /// - Parameter message: The message to sign.
    /// - Returns: The chain-specific signature encoding.
    /// - Throws: ``WalletKitError/unsupportedFeature`` if `message` isn't
    ///   this signer's chain's kind.
    func sign(message: SignableMessage) async throws -> Data
}
