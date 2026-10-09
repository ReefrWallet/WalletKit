//
//  SolanaWireTransaction.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 30/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Which `Message` wire layout a ``SolanaParsedMessage``/``SolanaWireTransaction``
/// was encoded with — distinguished by the high bit of the message's first
/// byte (clear: legacy, whose first byte is directly
/// ``SolanaMessageHeader/numRequiredSignatures``; set: versioned, whose
/// first byte's low 7 bits are the version number). Only version 0 is
/// supported; any other versioned prefix is rejected outright.
public enum SolanaMessageVersion: Equatable, Sendable {
    case legacy
    case v0
}

/// One version-0 address-table lookup descriptor — the accounts a v0
/// message pulls in from an on-chain lookup table by index, rather than
/// listing them directly in ``SolanaParsedMessage/staticAccountKeys``.
/// Validated structurally (bounded, fully consumed) but never resolved:
/// this codebase doesn't fetch the lookup table's contents, so the actual
/// addresses `writableIndexes`/`readonlyIndexes` refer to are unknown here
/// — see ADR-022.
public struct SolanaAddressTableLookup: Equatable, Sendable {
    public let accountKey: SolanaAddress
    public let writableIndexes: [UInt8]
    public let readonlyIndexes: [UInt8]
}

/// A fail-closed parse of a Solana `Message`'s wire bytes — legacy or
/// version 0, **without** a leading signature vector. This is the shared
/// parser both ``SolanaWireTransaction`` (a complete signed/unsigned
/// transaction) and a dapp's raw `solana:signMessage` input are checked
/// against: a `signMessage` request must never be signable as a
/// transaction message, so the safety check parses the exact same way a
/// real signer would.
///
/// Every variable-length field is length-prefixed by
/// `SolanaShortVec.decodeCanonical(_:offset:)` (canonical, ≤3 bytes,
/// ≤`0xFFFF`), every length is checked against the remaining input before
/// slicing, and the input must be consumed exactly — no trailing bytes.
/// Any structural mismatch (header counts vs. account count, an
/// instruction referencing an out-of-range or non-static program id, a
/// total account count that overflows the one-byte instruction-account
/// index space, ...) fails the parse rather than being tolerated.
public struct SolanaParsedMessage: Equatable, Sendable {
    /// Solana's own accepted transaction wire-size ceiling (the packet
    /// MTU a cluster's transaction-forwarding path is sized around) — a
    /// message this large could never be broadcast as-is, so it's
    /// rejected before any further parsing.
    public static let maxWireSize = 1_232

    /// The one-byte instruction-account-index space caps how many
    /// distinct accounts (static + loaded via address-table lookups) a
    /// message can reference.
    private static let maxTotalAccountCount = 256

    public let version: SolanaMessageVersion
    public let header: SolanaMessageHeader
    public let staticAccountKeys: [SolanaAddress]
    public let recentBlockhash: Data
    public let instructions: [SolanaCompiledInstruction]
    public let addressTableLookups: [SolanaAddressTableLookup]

    /// The exact bytes this value was parsed from — what a real signer
    /// signs directly (Solana has no separate signing-hash step),
    /// including the version-0 prefix byte when ``version`` is `.v0`.
    public let messageBytes: Data

    /// The number of accounts loaded from every lookup's
    /// `writableIndexes`, summed across ``addressTableLookups``.
    public var loadedWritableCount: Int {
        addressTableLookups.reduce(0) { $0 + $1.writableIndexes.count }
    }

    /// The number of accounts loaded from every lookup's
    /// `readonlyIndexes`, summed across ``addressTableLookups``.
    public var loadedReadonlyCount: Int {
        addressTableLookups.reduce(0) { $0 + $1.readonlyIndexes.count }
    }

    /// `staticAccountKeys.count + loadedWritableCount + loadedReadonlyCount`
    /// — every account an instruction's ``SolanaCompiledInstruction/programIdIndex``/
    /// `accountIndexes` can validly index into, static or loaded.
    public var totalAccountCount: Int {
        staticAccountKeys.count + loadedWritableCount + loadedReadonlyCount
    }

    /// Parses and fully validates `data` as a legacy or version-0
    /// `Message`'s wire bytes (no signature vector).
    ///
    /// - Throws: ``WalletKitError/internalError(message:)`` for any
    ///   structural violation — truncation, trailing bytes, a
    ///   non-canonical or oversized shortvec, an out-of-range header
    ///   count, an instruction whose `programIdIndex` isn't a static
    ///   account or whose account indexes overflow the total account
    ///   count, or an unrecognized version prefix.
    public init(validating data: Data) throws { // swiftlint:disable:this function_body_length
        func fail(_ message: String) -> WalletKitError {
            .internalError(message: "Solana message: \(message)")
        }

        guard data.count <= Self.maxWireSize else {
            throw fail("exceeds the maximum supported wire size (\(Self.maxWireSize) bytes)")
        }

        guard !data.isEmpty else {
            throw fail("empty")
        }

        var offset = 0
        let firstByte = data[0]
        let version: SolanaMessageVersion

        if firstByte & 0x80 != 0 {
            guard firstByte == 0x80 else {
                throw fail("unknown message version prefix 0x\(String(firstByte, radix: 16))")
            }

            version = .v0
            offset = 1
        } else {
            version = .legacy
        }

        guard offset + 3 <= data.count else {
            throw fail("too short for a header")
        }

        let header = SolanaMessageHeader(
            numRequiredSignatures: data[offset],
            numReadonlySignedAccounts: data[offset + 1],
            numReadonlyUnsignedAccounts: data[offset + 2]
        )

        offset += 3

        let staticAccountKeyCount = try SolanaShortVec.decodeCanonical(data, offset: &offset)
        var staticAccountKeys: [SolanaAddress] = []
        staticAccountKeys.reserveCapacity(staticAccountKeyCount)
        for _ in 0..<staticAccountKeyCount {
            guard offset + 32 <= data.count else {
                throw fail("truncated account key")
            }

            staticAccountKeys.append(try SolanaAddress(rawBytes: Data(data[offset..<(offset + 32)])))
            offset += 32
        }

        guard
            Int(header.numRequiredSignatures) <= staticAccountKeys.count,
            Int(header.numReadonlySignedAccounts) <= Int(header.numRequiredSignatures),
            Int(header.numReadonlyUnsignedAccounts) <= staticAccountKeys.count - Int(header.numRequiredSignatures)
        else {
            throw fail("header account-privilege counts are inconsistent with the static account key count")
        }

        guard offset + 32 <= data.count else {
            throw fail("truncated recent blockhash")
        }

        let recentBlockhash = Data(data[offset..<(offset + 32)])
        offset += 32

        let instructionCount = try SolanaShortVec.decodeCanonical(data, offset: &offset)
        var instructions: [SolanaCompiledInstruction] = []
        instructions.reserveCapacity(instructionCount)

        for _ in 0..<instructionCount {
            guard offset < data.count else {
                throw fail("truncated instruction")
            }

            let programIdIndex = data[offset]; offset += 1
            guard Int(programIdIndex) < staticAccountKeys.count else {
                throw fail("instruction programIdIndex does not reference a static account")
            }

            let accountIndexCount = try SolanaShortVec.decodeCanonical(data, offset: &offset)
            guard offset + accountIndexCount <= data.count else {
                throw fail("truncated instruction accounts")
            }

            let accountIndexes = Array(data[offset..<(offset + accountIndexCount)])
            offset += accountIndexCount

            let dataLength = try SolanaShortVec.decodeCanonical(data, offset: &offset)
            guard offset + dataLength <= data.count else {
                throw fail("truncated instruction data")
            }

            let instructionData = Data(data[offset..<(offset + dataLength)])
            offset += dataLength

            instructions.append(SolanaCompiledInstruction(
                programIdIndex: programIdIndex,
                accountIndexes: accountIndexes,
                data: instructionData
            ))
        }

        var addressTableLookups: [SolanaAddressTableLookup] = []
        if version == .v0 {
            let lookupCount = try SolanaShortVec.decodeCanonical(data, offset: &offset)
            addressTableLookups.reserveCapacity(lookupCount)

            for _ in 0..<lookupCount {
                guard offset + 32 <= data.count else {
                    throw fail("truncated address table lookup key")
                }

                let accountKey = try SolanaAddress(rawBytes: Data(data[offset..<(offset + 32)]))
                offset += 32

                let writableCount = try SolanaShortVec.decodeCanonical(data, offset: &offset)
                guard offset + writableCount <= data.count else {
                    throw fail("truncated writable lookup indexes")
                }

                let writableIndexes = Array(data[offset..<(offset + writableCount)])
                offset += writableCount

                let readonlyCount = try SolanaShortVec.decodeCanonical(data, offset: &offset)
                guard offset + readonlyCount <= data.count else {
                    throw fail("truncated readonly lookup indexes")
                }

                let readonlyIndexes = Array(data[offset..<(offset + readonlyCount)])
                offset += readonlyCount

                addressTableLookups.append(SolanaAddressTableLookup(
                    accountKey: accountKey, writableIndexes: writableIndexes, readonlyIndexes: readonlyIndexes
                ))
            }
        }

        guard offset == data.count else {
            throw fail("trailing bytes after a fully parsed message")
        }

        let loadedCount = addressTableLookups.reduce(0) { $0 + $1.writableIndexes.count + $1.readonlyIndexes.count }

        let totalAccountCount = staticAccountKeys.count + loadedCount

        guard totalAccountCount <= Self.maxTotalAccountCount else {
            throw fail("total account count \(totalAccountCount) exceeds the one-byte index space")
        }

        for instruction in instructions {
            for accountIndex in instruction.accountIndexes {
                guard Int(accountIndex) < totalAccountCount else {
                    throw fail("instruction account index \(accountIndex) is out of range")
                }
            }
        }

        self.version = version
        self.header = header
        self.staticAccountKeys = staticAccountKeys
        self.recentBlockhash = recentBlockhash
        self.instructions = instructions
        self.addressTableLookups = addressTableLookups
        messageBytes = data
    }
}

/// A complete Solana transaction's wire bytes — `compact-u16(signatureCount)
/// || signatures[signatureCount][64] || message` — fully validated via
/// ``SolanaParsedMessage``. Used for dapp-supplied (`solana:signTransaction`/
/// `solana:signAndSendTransaction`) transactions; this codebase's own
/// outbound transactions continue to use ``SolanaMessage``/
/// ``SolanaTransactionBuilder``, which don't need this level of paranoia
/// against untrusted input.
public struct SolanaWireTransaction: Equatable, Sendable {
    public let signatures: [Data]
    let parsedMessage: SolanaParsedMessage

    public var messageBytes: Data { parsedMessage.messageBytes }

    public var version: SolanaMessageVersion { parsedMessage.version }

    public var header: SolanaMessageHeader { parsedMessage.header }

    public var staticAccountKeys: [SolanaAddress] { parsedMessage.staticAccountKeys }

    public var instructions: [SolanaCompiledInstruction] { parsedMessage.instructions }

    public var addressTableLookups: [SolanaAddressTableLookup] { parsedMessage.addressTableLookups }

    public var addressTableLookupCount: Int { parsedMessage.addressTableLookups.count }

    public var totalAccountCount: Int { parsedMessage.totalAccountCount }

    /// Parses and fully validates `data` as a complete transaction:
    /// signature count matches the message header's
    /// `numRequiredSignatures`, every signature is exactly 64 bytes, and
    /// the message itself passes every ``SolanaParsedMessage`` invariant.
    ///
    /// - Throws: ``WalletKitError/internalError(message:)`` for any
    ///   structural violation, including everything
    ///   ``SolanaParsedMessage/init(validating:)`` rejects.
    public init(parsing data: Data) throws {
        func fail(_ message: String) -> WalletKitError {
            .internalError(message: "Solana transaction: \(message)")
        }

        var offset = 0
        let signatureCount = try SolanaShortVec.decodeCanonical(data, offset: &offset)
        var signatures: [Data] = []
        signatures.reserveCapacity(signatureCount)
        for _ in 0..<signatureCount {
            guard offset + 64 <= data.count else {
                throw fail("truncated signature")
            }

            signatures.append(Data(data[offset..<(offset + 64)]))
            offset += 64
        }

        let messageBytes = Data(data[offset...])
        let parsedMessage = try SolanaParsedMessage(validating: messageBytes)

        guard signatureCount == Int(parsedMessage.header.numRequiredSignatures) else {
            throw fail("signature count \(signatureCount) does not match numRequiredSignatures \(parsedMessage.header.numRequiredSignatures)")
        }

        self.signatures = signatures
        self.parsedMessage = parsedMessage
    }

    /// Replaces the signature slot belonging to `address` with `signature`,
    /// preserving every other (co-signer) signature, and re-serializes the
    /// complete transaction.
    ///
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `signature`
    ///   isn't 64 bytes, or ``WalletKitError/invalidAddress(reason:)`` if
    ///   `address` isn't one of this transaction's required signers.
    public func signed(by address: SolanaAddress, signature: Data) throws -> Data {
        guard signature.count == 64 else {
            throw WalletKitError.signingFailed(reason: "A Solana signature must be 64 bytes.")
        }

        let requiredSigners = staticAccountKeys.prefix(Int(header.numRequiredSignatures))
        guard let slot = requiredSigners.firstIndex(where: { $0 == address }) else {
            throw WalletKitError.invalidAddress(reason: "\(address.string) is not a required signer of this transaction")
        }

        var updatedSignatures = signatures
        updatedSignatures[slot] = signature

        var wire = SolanaShortVec.encode(updatedSignatures.count)
        for updatedSignature in updatedSignatures {
            wire.append(updatedSignature)
        }

        wire.append(messageBytes)
        return wire
    }
}
