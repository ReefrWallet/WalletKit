//
//  Slip39.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 11/11/2026.
//

import Foundation
import WalletKitRust

// MARK: - Errors

/// A failure decoding, combining or decrypting SLIP-39 shares.
public enum Slip39Error: Error, Equatable, Sendable {
    /// The same share was already added.
    case duplicateShare

    /// Another share with the same group and member index was already added.
    case conflictingShare

    /// The share set doesn't combine: digest check failed.
    case invalidDigest

    /// The checksum of a share failed.
    case invalidChecksum

    /// The passphrase contains characters outside printable ASCII.
    case invalidPassphrase

    /// A share is malformed.
    case invalidShare(reason: String)

    /// The shares don't belong together.
    case invalidSet(reason: String)

    /// Decryption was cancelled.
    case cancelled

    /// A share has a word count other than 20 or 33.
    case unsupportedLength(count: UInt32)

    /// A word isn't in the SLIP-39 wordlist.
    case unknownWord(String)

    /// The set holds more or fewer groups or shares than required.
    case wrongShareCount(reason: String)

    init(raw: Slip39ErrorFfi) {
        switch raw {
        case .UnknownWord(let word): self = .unknownWord(word)
        case .InvalidChecksum: self = .invalidChecksum
        case .UnsupportedLength(let count): self = .unsupportedLength(count: count)
        case .InvalidShare(let reason): self = .invalidShare(reason: reason)
        case .InvalidSet(let reason): self = .invalidSet(reason: reason)
        case .WrongShareCount(let reason): self = .wrongShareCount(reason: reason)
        case .InvalidDigest: self = .invalidDigest
        case .InvalidPassphrase: self = .invalidPassphrase
        case .Cancelled: self = .cancelled
        }
    }
}

private func remappingSlip39Error<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as Slip39ErrorFfi {
        throw Slip39Error(raw: error)
    }
}

// MARK: - Share

/// A decoded SLIP-39 share. Only 20- and 33-word shares are supported.
public struct Slip39Share: Equatable, Hashable, Sendable {
    public let extendable: Bool
    public let groupCount: Int
    public let groupIndex: Int
    public let groupThreshold: Int
    public let identifier: UInt32
    public let iterationExponent: Int
    public let memberIndex: Int
    public let memberThreshold: Int

    /// The share's words, normalized to lowercase, single-space separated.
    public let mnemonic: String
    public let wordCount: Int

    init(mnemonic: String, raw: Slip39ShareFfi) {
        self.mnemonic = mnemonic
        extendable = raw.extendable
        groupCount = Int(raw.groupCount)
        groupIndex = Int(raw.groupIndex)
        groupThreshold = Int(raw.groupThreshold)
        identifier = raw.identifier
        iterationExponent = Int(raw.iterationExponent)
        memberIndex = Int(raw.memberIndex)
        memberThreshold = Int(raw.memberThreshold)
        wordCount = Int(raw.wordCount)
    }
}

/// The strength of a generated master secret.
public enum Slip39Strength: UInt32, Sendable {
    /// A 20-word share.
    case bits128 = 128
    /// A 33-word share.
    case bits256 = 256
}

/// A newly generated single-share backup.
public struct Slip39GeneratedShare: Sendable {
    /// The master secret the share restores.
    public let masterSecret: Data

    /// The share's words, single-space separated.
    public let mnemonic: String
}

// MARK: - Slip39

/// SLIP-39 Shamir's Secret Sharing backups.
public enum Slip39 {
    /// The 1024-word SLIP-39 wordlist, in alphabetical order.
    public static var words: [String] { slip39Words() }

    /// Decodes one share.
    ///
    /// - Throws: ``Slip39Error`` when a word is unknown, the length isn't 20
    ///   or 33 words, or the checksum or padding is invalid.
    public static func decodeShare(_ mnemonic: String) throws -> Slip39Share {
        let normalized = mnemonic.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let raw = try remappingSlip39Error { try slip39DecodeShare(mnemonic: normalized) }
        return Slip39Share(mnemonic: normalized, raw: raw)
    }

    /// Generates a random master secret and its single-share backup (no
    /// passphrase). 20 words for 128 bits, 33 words for 256 bits.
    public static func generateSingleShare(strength: Slip39Strength = .bits128) throws -> Slip39GeneratedShare {
        let raw = try remappingSlip39Error { try slip39GenerateSingleShare(strengthBits: strength.rawValue) }
        return Slip39GeneratedShare(masterSecret: raw.masterSecret, mnemonic: raw.mnemonic)
    }

    /// Combines exactly the required groups and members into the encrypted
    /// master secret.
    ///
    /// - Throws: ``Slip39Error/invalidDigest`` if the shares don't combine.
    public static func recoverEncryptedSecret(_ shares: [Slip39Share]) throws -> Slip39EncryptedSecret {
        let mnemonics = shares.map(\.mnemonic)
        _ = try remappingSlip39Error { try slip39RecoverEncryptedSecret(mnemonics: mnemonics) }
        return Slip39EncryptedSecret(mnemonics: mnemonics)
    }
}

// MARK: - Encrypted secret

/// The encrypted master secret recovered from a complete set of shares.
///
/// Decrypting applies the passphrase with PBKDF2, which is slow. One
/// decryption runs at a time process-wide, and a cancelled one stops
/// within a few milliseconds.
public final class Slip39EncryptedSecret: Sendable {
    private static let queue = DispatchQueue(label: "WalletKit.Slip39.decrypt", qos: .userInitiated)

    private let mnemonics: [String]

    init(mnemonics: [String]) {
        self.mnemonics = mnemonics
    }

    /// Returns the master secret for `passphrase`, which is used exactly as
    /// given (an empty string for no passphrase).
    ///
    /// - Throws: ``Slip39Error/invalidPassphrase`` for characters outside
    ///   printable ASCII, ``Slip39Error/cancelled`` when the task is
    ///   cancelled.
    public func decrypt(passphrase: String) async throws -> Data {
        let mnemonics = mnemonics
        let box = CancelBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    do {
                        let secret = try remappingSlip39Error {
                            try slip39RecoverEncryptedSecret(mnemonics: mnemonics)
                        }

                        box.set(secret)
                        continuation.resume(returning: try remappingSlip39Error {
                            try secret.decrypt(passphrase: passphrase)
                        })
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Lets a cancellation reach the running decryption, or stop one that
/// hasn't started yet.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var secret: Slip39EncryptedSecretFfi?

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        secret?.cancel()
    }

    func set(_ secret: Slip39EncryptedSecretFfi) {
        lock.lock()
        defer { lock.unlock() }
        self.secret = secret

        if isCancelled {
            secret.cancel()
        }
    }
}

// MARK: - Share set

/// The shares entered so far for one backup.
public struct Slip39ShareSet: Equatable, Sendable {
    /// Progress of one group.
    public struct Group: Equatable, Sendable {
        public let index: Int
        public let memberThreshold: Int
        public let shares: [Slip39Share]

        public var isComplete: Bool { shares.count >= memberThreshold }
    }

    private var entries: [Slip39Share] = []

    public init() {}

    /// The shares in the order they were added.
    public var shares: [Slip39Share] { entries }

    public var isEmpty: Bool { entries.isEmpty }

    /// Groups that have at least one share, by group index.
    public var groups: [Group] {
        Dictionary(grouping: entries, by: \.groupIndex)
            .map { index, shares in
                Group(
                    index: index,
                    memberThreshold: shares[0].memberThreshold,
                    shares: shares.sorted { $0.memberIndex < $1.memberIndex }
                )
            }
            .sorted { $0.index < $1.index }
    }

    /// The number of groups needed, or `nil` before the first share.
    public var groupThreshold: Int? { entries.first?.groupThreshold }

    public var completeGroupCount: Int { groups.filter(\.isComplete).count }

    /// Whether enough shares of enough groups were entered.
    public var isComplete: Bool {
        guard let groupThreshold else {
            return false
        }

        return completeGroupCount >= groupThreshold
    }

    /// Exactly the groups and members needed to combine, or empty before
    /// ``isComplete``.
    public var sharesToCombine: [Slip39Share] {
        guard isComplete, let groupThreshold else {
            return []
        }

        return groups
            .filter(\.isComplete)
            .prefix(groupThreshold)
            .flatMap { $0.shares.prefix($0.memberThreshold) }
    }

    /// Adds `share` after checking it against the set.
    ///
    /// - Throws: ``Slip39Error/duplicateShare``,
    ///   ``Slip39Error/conflictingShare`` or ``Slip39Error/invalidSet(reason:)``
    ///   when the identifier, extendable flag, iteration exponent, group
    ///   threshold, group count, word count or a group's member threshold
    ///   differs.
    public mutating func add(_ share: Slip39Share) throws {
        if let first = entries.first {
            guard first.identifier == share.identifier,
                  first.extendable == share.extendable,
                  first.iterationExponent == share.iterationExponent,
                  first.groupThreshold == share.groupThreshold,
                  first.groupCount == share.groupCount,
                  first.wordCount == share.wordCount else {
                throw Slip39Error.invalidSet(reason: "The share belongs to a different backup.")
            }
        }

        let sameGroup = entries.filter { $0.groupIndex == share.groupIndex }

        if let groupFirst = sameGroup.first, groupFirst.memberThreshold != share.memberThreshold {
            throw Slip39Error.invalidSet(reason: "The member threshold differs within the group.")
        }

        if let existing = sameGroup.first(where: { $0.memberIndex == share.memberIndex }) {
            throw existing == share ? Slip39Error.duplicateShare : Slip39Error.conflictingShare
        }

        entries.append(share)
    }

    /// Removes `share`, if present.
    public mutating func remove(_ share: Slip39Share) {
        entries.removeAll { $0 == share }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// Combines ``sharesToCombine``.
    ///
    /// - Throws: ``Slip39Error/wrongShareCount(reason:)`` before
    ///   ``isComplete``, ``Slip39Error/invalidDigest`` if the shares don't
    ///   combine.
    public func encryptedSecret() throws -> Slip39EncryptedSecret {
        guard isComplete else {
            throw Slip39Error.wrongShareCount(reason: "More shares are needed.")
        }

        return try Slip39.recoverEncryptedSecret(sharesToCombine)
    }
}
