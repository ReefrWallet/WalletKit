//
//  SuiTransactionDataDecoder.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 30/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  A fail-closed, decode-side companion to BCS.swift's encoder — parses
//  just enough of a raw `TransactionData::V1` blob (BCS-encoded, as
//  produced by a dapp's own Sui SDK before handing it to the wallet for
//  `sui:signTransaction`/`sui:signAndExecuteTransaction`) to recover the
//  sender and gas fields for an approval preview, and — critically — to
//  let the caller reject anything it can't fully and confidently parse
//  before ever signing it.
//
//  Every variant/field layout this file accepts is either mirrored
//  byte-for-byte from SuiUnsignedTransactions.swift's own encoders (which
//  are validated against real signed vectors in
//  Tests/Blockchains/Sui/SuiTransactionDataTests.swift), or was cross-
//  checked against the discriminant/field-name strings embedded in the
//  `sui` CLI binary itself (1.66.2) — but Sui's wire format can grow new
//  variants over time. Any tag this reader doesn't recognize causes the
//  whole parse to fail (return `nil`), rather than guessing at its shape
//  — a transaction using such a variant is simply not decodable (and
//  therefore not signable via this decoder) until real support is added
//  and verified against Sui's current type definitions. `MoveCall` is the
//  one exception with a non-empty `typeArguments`: a generic Move call's
//  recursive `TypeTag` isn't verified against a tested vector yet, so
//  that specific shape still fails closed.

import Foundation

/// A single decoded `Command::MoveCall` — just enough to name the
/// function it invokes in an approval preview.
public struct SuiMoveCallSummary: Sendable, Equatable {
    public let package: SuiAddress
    public let module: String
    public let function: String
}

/// A best-effort but fully-validated summary of a `TransactionData::V1`
/// blob — every field is either genuinely present in the parsed bytes or
/// the whole parse fails. There is no "partially decoded" state.
public struct SuiTransactionDataSummary: Sendable, Equatable {
    /// The transaction's `sender` field — MUST be checked by callers
    /// against the account that's about to sign, before ever signing.
    /// `SuiTransactionDataDecoder` itself does not know which account is
    /// authorized; it only reports what the bytes claim.
    public let sender: SuiAddress
    /// The account paying for the transaction's gas. Wallets that do not
    /// support sponsored transactions must require this to equal `sender`.
    public let gasOwner: SuiAddress
    /// The transaction's gas budget, in MIST.
    public let gasBudget: UInt64
    /// The transaction's gas price, in MIST per gas unit.
    public let gasPrice: UInt64
    /// How many top-level PTB commands the transaction contains.
    public let commandCount: Int
    /// Every `Command::MoveCall` the transaction's PTB contains, in
    /// command order.
    public let moveCalls: [SuiMoveCallSummary]

    public static func == (lhs: SuiTransactionDataSummary, rhs: SuiTransactionDataSummary) -> Bool {
        lhs.sender == rhs.sender && lhs.gasOwner == rhs.gasOwner && lhs.gasBudget == rhs.gasBudget
            && lhs.gasPrice == rhs.gasPrice
            && lhs.commandCount == rhs.commandCount && lhs.moveCalls == rhs.moveCalls
    }
}

/// Parses a raw, dapp-supplied `TransactionData::V1` BCS blob into a
/// ``SuiTransactionDataSummary``, or fails closed.
public enum SuiTransactionDataDecoder {
    /// Above this many raw bytes, parsing isn't even attempted — no
    /// legitimate wallet-signable PTB should be anywhere near this size.
    private static let maxTotalByteCount = 256 * 1024
    /// Bounds every `Vec<T>` element count this reader walks (inputs,
    /// commands, argument vectors, gas-payment references) — rejects
    /// anything larger rather than looping that many times.
    private static let maxCollectionCount = 4096
    /// Bounds a single `CallArg::Pure` payload's length and an
    /// `ObjectRef` digest's length.
    private static let maxByteVectorLength = 64 * 1024

    /// Fully parses `data` as a `TransactionData::V1` BCS blob.
    ///
    /// - Returns: The decoded summary, or `nil` if `data` uses any
    ///   variant/shape this parser doesn't recognize, is truncated, has
    ///   trailing bytes after the last field, uses non-canonical
    ///   ULEB128, or exceeds a bounded collection count/payload size.
    ///   Never traps — `data` originates from an untrusted web page.
    public static func summarize( // swiftlint:disable:this function_body_length
        _ data: Data
    ) -> SuiTransactionDataSummary? {
        guard data.count <= maxTotalByteCount else {
            return nil
        }

        var reader = Reader(data)

        // TransactionData::V1 — no other TransactionData variant exists
        // to reject here (V1 is, as of this writing, the only one), but
        // an unrecognized future variant still must not be silently
        // treated as V1.
        guard reader.readByte() == 0x00 else {
            return nil
        }

        // TransactionKind::ProgrammableTransaction — every other kind
        // (ChangeEpoch, Genesis, ConsensusCommitPrologue*, ...) is a
        // system transaction, not something a dapp should ever ask a
        // wallet to sign.
        guard reader.readByte() == 0x00 else {
            return nil
        }

        guard let inputCount = reader.readCount(max: maxCollectionCount) else {
            return nil
        }

        for _ in 0..<inputCount {
            guard reader.skipCallArg(maxPureLength: maxByteVectorLength) else {
                return nil
            }
        }

        guard let commandCount = reader.readCount(max: maxCollectionCount) else {
            return nil
        }

        var moveCalls: [SuiMoveCallSummary] = []

        for _ in 0..<commandCount {
            guard reader.skipCommand(
                maxArgumentVectorCount: maxCollectionCount,
                maxIdentifierLength: maxByteVectorLength,
                moveCalls: &moveCalls
            ) else {
                return nil
            }
        }

        guard let senderBytes = reader.readBytes(32), let sender = try? SuiAddress(rawBytes: senderBytes) else {
            return nil
        }

        // GasData: payment: Vec<ObjectRef>, owner: address, price: u64, budget: u64.
        guard let paymentCount = reader.readCount(max: maxCollectionCount) else {
            return nil
        }

        for _ in 0..<paymentCount {
            guard reader.skipObjectRef(maxDigestLength: maxByteVectorLength) else {
                return nil
            }
        }

        guard let gasOwnerBytes = reader.readBytes(32), let gasOwner = try? SuiAddress(rawBytes: gasOwnerBytes) else {
            return nil
        }
        guard let gasPrice = reader.readU64() else {
            return nil
        }

        guard let gasBudget = reader.readU64() else {
            return nil
        }

        // TransactionExpiration::None — `Epoch(u64)` and `ValidDuring`
        // both exist in current Sui but aren't accepted here; a
        // non-`None` expiration changes how the transaction should be
        // interpreted, so support for it is deferred until genuinely
        // needed and verified.
        guard reader.readByte() == 0x00 else {
            return nil
        }

        // Every byte must be accounted for — leftover trailing bytes are
        // exactly the symptom a missed/misread variant produces.
        guard reader.isAtEnd else {
            return nil
        }

        return SuiTransactionDataSummary(
            sender: sender,
            gasOwner: gasOwner,
            gasBudget: gasBudget,
            gasPrice: gasPrice,
            commandCount: commandCount,
            moveCalls: moveCalls
        )
    }
}

/// A bounds-checked cursor over `Data` — every read either returns a
/// value and advances, or returns `nil`/`false` and leaves the reader in
/// an unspecified (but never out-of-bounds) state, since callers always
/// abort the whole parse on the first failure.
private struct Reader {
    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func readByte() -> UInt8? {
        guard offset < data.endIndex else {
            return nil
        }

        let byte = data[offset]
        offset += 1
        return byte
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, let end = data.index(offset, offsetBy: count, limitedBy: data.endIndex) else {
            return nil
        }

        let result = Data(data[offset..<end])
        offset = end
        return result
    }

    mutating func readU64() -> UInt64? {
        guard let bytes = readBytes(8) else {
            return nil
        }

        return bytes.enumerated().reduce(UInt64(0)) { accumulator, element in
            accumulator | (UInt64(element.element) << (8 * element.offset))
        }
    }

    /// Reads a ULEB128-encoded value and requires it be both within
    /// `[0, max]` and canonically encoded (re-encoding the decoded value
    /// must reproduce exactly the bytes that were read) — rejects
    /// overlong encodings that would otherwise decode to the same value
    /// via extra, redundant continuation bytes.
    mutating func readCount(max: Int) -> Int? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var consumed = Data()
        // 5 bytes covers any value up to 2^35, comfortably beyond `max`
        // for every caller in this file — a canonical encoding of a
        // value that small never needs more.
        for _ in 0..<5 {
            guard let byte = readByte() else {
                return nil
            }

            consumed.append(byte)
            guard shift < 64 else {
                return nil
            }

            value |= UInt64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 {
                guard let intValue = Int(exactly: value), intValue <= max, intValue >= 0 else {
                    return nil
                }

                guard BCS.uleb128(intValue) == consumed else {
                    return nil
                }

                return intValue
            }
        }

        return nil
    }

    mutating func readByteVector(maxLength: Int) -> Data? {
        guard let length = readCount(max: maxLength) else {
            return nil
        }

        return readBytes(length)
    }

    /// Reads a Move `Identifier` (a module or function name) — the same
    /// length-prefixed UTF-8 byte vector `BCS.byteVector` encodes.
    mutating func readIdentifier(maxLength: Int) -> String? {
        guard let bytes = readByteVector(maxLength: maxLength) else {
            return nil
        }

        return String(bytes: bytes, encoding: .utf8)
    }

    /// Skips a single BCS `Argument` — `GasCoin` (no payload), `Input`/
    /// `Result` (one `u16`), or `NestedResult` (two `u16`s). Any other
    /// tag fails closed.
    mutating func skipArgument() -> Bool {
        guard let tag = readByte() else {
            return false
        }

        switch tag {
        case 0: return true // GasCoin
        case 1: return readBytes(2) != nil // Input(u16)
        case 2: return readBytes(2) != nil // Result(u16)
        case 3: return readBytes(2) != nil && readBytes(2) != nil // NestedResult(u16, u16)
        default: return false
        }
    }

    mutating func skipArgumentVector(maxCount: Int) -> Bool {
        guard let count = readCount(max: maxCount) else {
            return false
        }

        for _ in 0..<count {
            guard skipArgument() else {
                return false
            }
        }

        return true
    }

    /// Skips a single `ObjectRef` — `objectId` (32 raw bytes), `version`
    /// (`u64`), `digest` (length-prefixed byte vector) — exactly the
    /// shape `SuiUnsignedTransactions.swift`'s `appendImmOrOwned`/
    /// `appendGasData` write.
    mutating func skipObjectRef(maxDigestLength: Int) -> Bool {
        guard readBytes(32) != nil else {
            return false
        } // objectId
        guard readU64() != nil else {
            return false
        } // version
        guard readByteVector(maxLength: maxDigestLength) != nil else {
            return false
        } // digest
        return true
    }

    /// Skips a single `CallArg`. Only `Pure` and `Object(ImmOrOwned |
    /// Receiving)` are implemented — `Object(Shared)` and
    /// `FundsWithdrawal` (both real, current Sui variants) aren't
    /// validated against this codebase's own tested encoders, so they
    /// fail closed rather than being guessed at.
    mutating func skipCallArg(maxPureLength: Int) -> Bool {
        guard let tag = readByte() else {
            return false
        }

        switch tag {
        case 0: // Pure(Vec<u8>)
            return readByteVector(maxLength: maxPureLength) != nil
        case 1: // Object(ObjectArg)
            guard let objectArgTag = readByte() else {
                return false
            }

            switch objectArgTag {
            case 0, 2: // ImmOrOwnedObject, Receiving — same ObjectRef shape
                return skipObjectRef(maxDigestLength: maxPureLength)
            default: // SharedObject(1), or any newer variant
                return false
            }

        default: // FundsWithdrawal(2), or any newer variant
            return false
        }
    }

    /// Decodes a single `Command::MoveCall(package, module, function,
    /// typeArguments: Vec<TypeTag>, arguments: Vec<Argument>)`. Only an
    /// empty `typeArguments` vector is accepted — a generic Move call's
    /// recursive `TypeTag` isn't verified against a tested vector yet,
    /// so it fails closed rather than being guessed at.
    mutating func decodeMoveCall(maxArgumentVectorCount: Int, maxIdentifierLength: Int) -> SuiMoveCallSummary? {
        guard let packageBytes = readBytes(32), let package = try? SuiAddress(rawBytes: packageBytes) else {
            return nil
        }

        guard
            let module = readIdentifier(maxLength: maxIdentifierLength),
            let function = readIdentifier(maxLength: maxIdentifierLength)
        else {
            return nil
        }

        guard let typeArgumentCount = readCount(max: maxArgumentVectorCount), typeArgumentCount == 0 else {
            return nil
        }

        guard skipArgumentVector(maxCount: maxArgumentVectorCount) else {
            return nil
        }

        return SuiMoveCallSummary(package: package, module: module, function: function)
    }

    /// Skips (or, for `MoveCall`, decodes) a single `Command`.
    /// `TransferObjects`, `SplitCoins`, and `MergeCoins` are implemented
    /// because this codebase's own encoders (`SuiUnsignedTransactions.
    /// swift`) produce them; `MoveCall` is implemented for a dapp's own
    /// PTBs, with a non-generic call only (see
    /// ``decodeMoveCall(maxArgumentVectorCount:maxIdentifierLength:)``).
    /// `Publish`, `MakeMoveVec`, and `Upgrade` aren't verified against
    /// this codebase's own tested vectors, so they fail closed.
    mutating func skipCommand(
        maxArgumentVectorCount: Int, maxIdentifierLength: Int, moveCalls: inout [SuiMoveCallSummary]
    ) -> Bool {
        guard let tag = readByte() else {
            return false
        }

        switch tag {
        case 0: // MoveCall
            guard let call = decodeMoveCall(
                maxArgumentVectorCount: maxArgumentVectorCount, maxIdentifierLength: maxIdentifierLength
            ) else {
                return false
            }

            moveCalls.append(call)
            return true
        case 1: // TransferObjects(Vec<Argument>, Argument)
            return skipArgumentVector(maxCount: maxArgumentVectorCount) && skipArgument()
        case 2: // SplitCoins(Argument, Vec<Argument>)
            return skipArgument() && skipArgumentVector(maxCount: maxArgumentVectorCount)
        case 3: // MergeCoins(Argument, Vec<Argument>)
            return skipArgument() && skipArgumentVector(maxCount: maxArgumentVectorCount)
        default: // Publish(4), MakeMoveVec(5), Upgrade(6)
            return false
        }
    }
}
