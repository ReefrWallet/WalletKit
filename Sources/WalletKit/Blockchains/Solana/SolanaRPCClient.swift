//
//  SolanaRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A client for a Solana JSON-RPC node — balances, mint/token-account
/// reads, fee/rent queries, transaction submission, and account history.
/// Pairs with ``SolanaTransactionBuilder``/``SolanaPKeySigner``/
/// ``SolanaTrezorSigner``, which produce the ``SolanaUnsignedTransaction``
/// envelope this client's ``estimateFee(for:)`` and
/// ``broadcast(transaction:signature:)`` consume.
public struct SolanaRPCClient: Sendable {
    let rpc: JSONRPCClient

    /// Creates a client for the node at `endpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: The node's JSON-RPC HTTPS endpoint.
    ///   - session: The `URLSession` to issue requests on. Defaults to
    ///     `.shared`.
    public init(endpoint: URL, session: URLSession = .shared) {
        rpc = JSONRPCClient(endpoint: endpoint, session: session)
    }
}

// MARK: - Response envelopes

/// Wraps the `{context, value}` envelope most Solana RPC methods use.
struct SolanaRPCValue<Value: Decodable>: Decodable {
    let value: Value
}

// MARK: - Balances

extension SolanaRPCClient {
    private struct CommitmentParams: Encodable {
        let pubkey: String

        private struct Config: Encodable { let commitment = "confirmed" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(pubkey)
            try container.encode(Config())
        }
    }

    /// Returns `owner`'s native SOL balance, in lamports — `getBalance`
    /// at `confirmed` commitment.
    ///
    /// `confirmed` (not the RPC default of `finalized`, which lags
    /// `confirmed` by design — roughly the ~32-slot optimistic-
    /// confirmation lockout window, ~15-25s even on an idle single-node
    /// `solana-test-validator`) so a balance read immediately after a
    /// broadcast this client itself confirmed doesn't appear stale.
    func lamportBalance(of owner: SolanaAddress) async throws -> UInt64 {
        let response: SolanaRPCValue<UInt64> = try await rpc.call(
            method: "getBalance", params: CommitmentParams(pubkey: owner.string)
        )
        return response.value
    }

    private struct TokenAccountsParams: Encodable {
        let owner: String
        let programId: String

        private struct Filter: Encodable { let programId: String }
        private struct Config: Encodable { let encoding = "jsonParsed"; let commitment = "confirmed" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(owner)
            try container.encode(Filter(programId: programId))
            try container.encode(Config())
        }
    }

    private struct TokenAmount: Decodable {
        let amount: String
        let decimals: UInt8
    }

    private struct ParsedTokenInfo: Decodable {
        let mint: String
        let owner: String
        let tokenAmount: TokenAmount
    }

    private struct ParsedTokenAccountData: Decodable {
        let parsed: ParsedTokenAccount

        struct ParsedTokenAccount: Decodable {
            let info: ParsedTokenInfo
        }
    }

    private struct TokenAccountEntry: Decodable {
        let pubkey: String
        let account: Account

        struct Account: Decodable {
            let data: ParsedTokenAccountData
        }
    }

    /// Returns every SPL token account `owner` holds under `tokenProgram`
    /// — `getTokenAccountsByOwner`, `jsonParsed` encoding.
    ///
    /// - Returns: `(tokenAccount, mint, amount)` triples, one per owned
    ///   token account (an owner can hold more than one account for the
    ///   same mint, so this doesn't dedupe by mint).
    func tokenAccounts(
        of owner: SolanaAddress,
        tokenProgram: SolanaAddress
    ) async throws -> [(tokenAccount: SolanaAddress, mint: SolanaAddress, amount: BigUInt)] {
        let response: SolanaRPCValue<[TokenAccountEntry]> = try await rpc.call(
            method: "getTokenAccountsByOwner",
            params: TokenAccountsParams(owner: owner.string, programId: tokenProgram.string)
        )
        return try response.value.map { entry in
            let info = entry.account.data.parsed.info
            guard let amount = BigUInt(info.tokenAmount.amount) else {
                throw BlockchainClientError.decodingFailed(reason: "invalid SPL token amount: \(info.tokenAmount.amount)")
            }
            return (
                tokenAccount: try SolanaAddress(string: entry.pubkey),
                mint: try SolanaAddress(string: info.mint),
                amount: amount
            )
        }
    }
}

// MARK: - Mint / metadata

extension SolanaRPCClient {
    private struct AccountInfoParams: Encodable {
        let pubkey: String

        private struct Config: Encodable { let encoding = "base64"; let commitment = "confirmed" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(pubkey)
            try container.encode(Config())
        }
    }

    private struct RawAccountInfo: Decodable {
        let data: [String]
        let owner: String
    }

    /// Returns the raw account bytes and owning program for `address`, or
    /// `nil` if the account doesn't exist — `getAccountInfo`, `base64`
    /// encoding.
    func rawAccountInfo(of address: SolanaAddress) async throws -> (data: Data, owner: SolanaAddress)? {
        let response: SolanaRPCValue<RawAccountInfo?> = try await rpc.call(
            method: "getAccountInfo",
            params: AccountInfoParams(pubkey: address.string)
        )
        guard let info = response.value, let base64 = info.data.first, let data = Data(base64Encoded: base64) else {
            return nil
        }
        return (data, try SolanaAddress(string: info.owner))
    }

    /// Reads an SPL mint account's `decimals` field directly from its raw
    /// bytes — a fixed 82-byte layout (`mintAuthorityOption`(4) +
    /// `mintAuthority`(32) + `supply`(8) + `decimals`(1) + ...), so
    /// `decimals` always sits at byte offset 44 regardless of program
    /// version (Token-2022's mint layout only appends extension TLVs
    /// after this fixed prefix).
    ///
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `mint` doesn't exist or is shorter than a mint account.
    func mintDecimals(of mint: SolanaAddress) async throws -> UInt8 {
        try await mintInfo(of: mint).decimals
    }

    /// Reads an SPL mint account's `decimals` field (see ``mintDecimals(of:)``)
    /// together with the token program that owns it — ``SolanaProgram/token``
    /// or ``SolanaProgram/token2022`` — in one round trip.
    ///
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `mint` doesn't exist or is shorter than a mint account.
    func mintInfo(of mint: SolanaAddress) async throws -> (decimals: UInt8, tokenProgram: SolanaAddress) {
        guard let (data, tokenProgram) = try await rawAccountInfo(of: mint), data.count >= 45 else {
            throw BlockchainClientError.decodingFailed(reason: "\(mint.string) is not a token mint account")
        }
        return (data[44], tokenProgram)
    }

    /// Reads `mint`'s name/symbol from its Metaplex Token Metadata
    /// account, or returns `nil` if no metadata account exists (a mint is
    /// never required to have one) or its layout can't be parsed —
    /// callers fall back to a synthesized name/symbol in that case.
    ///
    /// Layout parsed (Borsh): 1-byte key + 32-byte update authority +
    /// 32-byte mint, then `name`/`symbol`/`uri` as length-prefixed (u32
    /// LE) UTF-8 strings — only `name`/`symbol` are read here.
    func metaplexTokenInfo(of mint: SolanaAddress) async throws -> (name: String, symbol: String)? {
        let metadataAddress = try SolanaProgram.metadataAddress(mint: mint)
        guard let (data, _) = try await rawAccountInfo(of: metadataAddress) else {
            return nil
        }

        var offset = 1 + 32 + 32
        func readString() -> String? {
            guard offset + 4 <= data.count else { return nil }
            let length = Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 24
            offset += 4
            guard length >= 0, offset + length <= data.count else { return nil }
            let stringData = data[offset..<(offset + length)]
            offset += length
            return String(data: stringData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        }

        guard let name = readString(), let symbol = readString() else {
            return nil
        }
        return (name, symbol)
    }
}

// MARK: - Fees / rent

extension SolanaRPCClient {
    private struct Blockhash: Decodable {
        let blockhash: String
        let lastValidBlockHeight: UInt64
    }

    private struct CommitmentOnlyParams: Encodable {
        private struct Config: Encodable { let commitment = "confirmed" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(Config())
        }
    }

    /// Returns a recent blockhash the cluster will accept as fresh, and
    /// the block height at which it expires — `getLatestBlockhash` at
    /// `confirmed` commitment.
    ///
    /// `confirmed`, not the RPC default `finalized`: a blockhash that
    /// old can reference a bank snapshot from before a just-airdropped/
    /// just-created sender account existed, which the runtime rejects
    /// with "Attempt to debit an account but found no record of a prior
    /// credit" at simulation time — most visible moments after funding a
    /// brand-new account, exactly what account creation does.
    func latestBlockhash() async throws -> (blockhash: Data, lastValidBlockHeight: UInt64) {
        let response: SolanaRPCValue<Blockhash> = try await rpc.call(
            method: "getLatestBlockhash", params: CommitmentOnlyParams()
        )
        let decoded = try Base58.decode(response.value.blockhash)
        guard decoded.count == 32 else {
            throw BlockchainClientError.decodingFailed(reason: "invalid blockhash: \(response.value.blockhash)")
        }
        return (decoded, response.value.lastValidBlockHeight)
    }

    private struct FeeForMessageParams: Encodable {
        let message: String

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(message)
        }
    }

    /// Returns the base fee, in lamports, `message` would pay —
    /// `getFeeForMessage`. `nil` if the node can't price the message
    /// (e.g. a stale blockhash).
    func feeForMessage(_ message: Data) async throws -> UInt64? {
        let response: SolanaRPCValue<UInt64?> = try await rpc.call(
            method: "getFeeForMessage",
            params: FeeForMessageParams(message: message.base64EncodedString())
        )
        return response.value
    }

    /// Returns the minimum lamport balance an account of `dataLength`
    /// bytes needs to be exempt from rent — `getMinimumBalanceForRentExemption`.
    func minimumBalanceForRentExemption(dataLength: Int) async throws -> UInt64 {
        try await rpc.call(method: "getMinimumBalanceForRentExemption", params: [dataLength])
    }

    private struct PrioritizationFeeEntry: Decodable {
        let prioritizationFee: UInt64
    }

    /// Returns a representative recent priority fee, in micro-lamports
    /// per compute unit — the median of `getRecentPrioritizationFees`'
    /// non-zero samples, or 0 if every recent sample was 0 (an idle
    /// cluster).
    func recentPrioritizationFee() async throws -> UInt64 {
        let entries: [PrioritizationFeeEntry] = try await rpc.call(
            method: "getRecentPrioritizationFees", params: [String]()
        )
        let nonZero = entries.map(\.prioritizationFee).filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return 0 }
        return nonZero[nonZero.count / 2]
    }
}

// MARK: - Submission

/// A commitment level a Solana RPC node can be asked to preflight
/// against, or a caller can ask ``SolanaRPCClient/sendTransaction(_:options:)``
/// to wait for after broadcast.
public enum SolanaCommitment: String, Sendable {
    case processed
    case confirmed
    case finalized

    /// This commitment's position in Solana's own
    /// `processed < confirmed < finalized` lockout ordering — used to
    /// decide whether a signature status satisfies a requested commitment.
    fileprivate var rank: Int {
        switch self {
        case .processed: 0
        case .confirmed: 1
        case .finalized: 2
        }
    }
}

/// Options for ``SolanaRPCClient/sendTransaction(_:options:)`` — the
/// fields Wallet Standard's `solana:signAndSendTransaction` lets a dapp
/// request, forwarded to the RPC node's `sendTransaction` config plus an
/// optional post-broadcast confirmation wait this client performs itself
/// (the RPC method has no "wait for confirmation" option of its own).
public struct SolanaSendTransactionOptions: Sendable {
    /// If present, ``SolanaRPCClient/sendTransaction(_:options:)`` polls
    /// `getSignatureStatuses` until the transaction reaches this
    /// commitment (or fails, or the wait times out) before returning.
    public let commitment: SolanaCommitment?
    public let maxRetries: UInt?
    public let minContextSlot: UInt64?
    /// Defaults (when `nil`) to `confirmed`, matching this client's
    /// previous hardcoded behavior.
    public let preflightCommitment: SolanaCommitment?
    public let skipPreflight: Bool?

    public init(
        commitment: SolanaCommitment? = nil,
        maxRetries: UInt? = nil,
        minContextSlot: UInt64? = nil,
        preflightCommitment: SolanaCommitment? = nil,
        skipPreflight: Bool? = nil
    ) {
        self.commitment = commitment
        self.maxRetries = maxRetries
        self.minContextSlot = minContextSlot
        self.preflightCommitment = preflightCommitment
        self.skipPreflight = skipPreflight
    }
}

extension SolanaRPCClient {
    private struct SendTransactionParams: Encodable {
        let transaction: String
        let options: SolanaSendTransactionOptions

        private struct Config: Encodable {
            let encoding = "base64"
            let preflightCommitment: String
            let skipPreflight: Bool?
            let maxRetries: UInt?
            let minContextSlot: UInt64?

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(encoding, forKey: .encoding)
                try container.encode(preflightCommitment, forKey: .preflightCommitment)
                try container.encodeIfPresent(skipPreflight, forKey: .skipPreflight)
                try container.encodeIfPresent(maxRetries, forKey: .maxRetries)
                try container.encodeIfPresent(minContextSlot, forKey: .minContextSlot)
            }

            enum CodingKeys: String, CodingKey {
                case encoding, preflightCommitment, skipPreflight, maxRetries, minContextSlot
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(transaction)
            // Matches `latestBlockhash()`'s `confirmed` fetch — the RPC
            // default preflight commitment is `finalized`, which lags
            // behind and doesn't yet recognize a blockhash this recent,
            // rejecting the transaction with "Blockhash not found".
            try container.encode(Config(
                preflightCommitment: options.preflightCommitment?.rawValue ?? "confirmed",
                skipPreflight: options.skipPreflight,
                maxRetries: options.maxRetries,
                minContextSlot: options.minContextSlot
            ))
        }
    }

    /// Submits a fully signed transaction (signature list + serialized
    /// message) and returns its signature — `sendTransaction`, `base64`
    /// encoding. If `options.commitment` is set, waits for that
    /// commitment (via `getSignatureStatuses` polling) before returning.
    ///
    /// - Throws: ``BlockchainClientError`` for a transport/RPC failure,
    ///   for a transaction that lands but fails on-chain, or for a
    ///   confirmation wait that exceeds ``confirmationTimeout``.
    public func sendTransaction(
        _ signedTransaction: Data, options: SolanaSendTransactionOptions = .init()
    ) async throws -> String {
        let signature: String = try await rpc.call(
            method: "sendTransaction",
            params: SendTransactionParams(transaction: signedTransaction.base64EncodedString(), options: options)
        )

        if let commitment = options.commitment {
            try await confirmTransaction(signature: signature, commitment: commitment)
        }

        return signature
    }

    private struct SignatureStatusesParams: Encodable {
        let signatures: [String]

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(signatures)
        }
    }

    /// `err` is only ever checked for presence (Solana's own
    /// `TransactionError` shape isn't consumed) — `decode` records
    /// whether the key held anything other than `null`.
    private struct SignatureStatus: Decodable {
        let confirmationStatus: String?
        let hasError: Bool

        private enum CodingKeys: String, CodingKey {
            case confirmationStatus, err
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            confirmationStatus = try container.decodeIfPresent(String.self, forKey: .confirmationStatus)
            hasError = try container.contains(.err) && !container.decodeNil(forKey: .err)
        }
    }

    /// Polls `getSignatureStatuses` for `signature` until it reaches
    /// `commitment`, fails on-chain, or ``confirmationTimeout`` elapses.
    private func confirmTransaction(signature: String, commitment: SolanaCommitment) async throws {
        let deadline = Date().addingTimeInterval(Self.confirmationTimeout)

        while true {
            let response: SolanaRPCValue<[SignatureStatus?]> = try await rpc.call(
                method: "getSignatureStatuses", params: SignatureStatusesParams(signatures: [signature])
            )

            if let status = response.value.first ?? nil {
                if status.hasError {
                    throw BlockchainClientError.rpcError(code: 0, message: "Solana transaction \(signature) failed on-chain")
                }

                if let confirmationStatus = status.confirmationStatus,
                   let rank = SolanaCommitment(rawValue: confirmationStatus)?.rank,
                   rank >= commitment.rank {
                    return
                }
            }

            guard Date() < deadline else {
                throw BlockchainClientError.transportError(
                    reason: "timed out waiting for Solana transaction \(signature) to reach \(commitment.rawValue)"
                )
            }
            
            try await Task.sleep(nanoseconds: Self.confirmationPollInterval)
        }
    }

    // `internal`, not `private`, so `@testable import WalletKit` tests can
    // shrink these for a fast confirmation-success/timeout test rather
    // than waiting out a real 30-second timeout.
    static var confirmationTimeout: TimeInterval = 30
    static var confirmationPollInterval: UInt64 = 1_000_000_000
}
