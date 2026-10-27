import Foundation
import WalletKitRust

/// One address of the account that has on-chain history.
public struct CardanoUsedAddress: Equatable, Sendable {
    public let address: CardanoAddress
    public let index: UInt32
    public let role: UInt32
}

/// Which of an account's addresses have been used, from ``CardanoClient/addressUsage(_:)``.
public struct CardanoAddressUsage: Equatable, Sendable {
    /// Ordered by (role, index).
    public let used: [CardanoUsedAddress]

    /// Highest used index per role, for the signer resolver's key scan.
    var indices: [CardanoUsedIndicesFfi] {
        [0, 1].map { role in
            CardanoUsedIndicesFfi(maxUsedIndex: used.filter { $0.role == role }.map(\.index).max(), role: role)
        }
    }

    /// The first external address with no history.
    public func firstUnusedExternalIndex() -> UInt32 {
        (used.filter { $0.role == 0 }.map(\.index).max()).map { $0 + 1 } ?? 0
    }
}

/// Script bodies and references are content-addressed, so they are shared
/// across clients and networks for the life of the process.
actor CardanoScriptCache {
    static let shared = CardanoScriptCache()

    private var references: [String: Data] = [:]
    private var scripts: [String: CardanoResolvedScriptFfi] = [:]

    func reference(_ hash: String) -> Data? { references[hash] }

    func script(_ hash: String) -> CardanoResolvedScriptFfi? { scripts[hash] }

    func store(reference: Data, for hash: String) { references[hash] = reference }

    func store(script: CardanoResolvedScriptFfi, for hash: String) { scripts[hash] = script }
}

extension CardanoClient {
    /// Gap limit: unused indices scanned past the last used one.
    static let discoveryGap = 20
    /// Hard cap on derivation indices scanned per role.
    static let discoveryCap = 1_000

    /// Used addresses of `owner`: every address Blockfrost lists for the
    /// stake key (spent-out ones included), matched against the account's
    /// derived addresses. Scans both roles up to ``discoveryGap`` past the
    /// last used index, and keeps going — up to ``discoveryCap`` — while a
    /// known address is unmatched. If any remain, the ownership view would
    /// be incomplete, so this throws instead of omitting them.
    public func addressUsage(_ owner: CardanoAccountDescriptor) async throws -> CardanoAddressUsage {
        let known = Set(try await ownedAddresses(owner))
        var remaining = known
        var used: [CardanoUsedAddress] = []
        var lastUsed: [UInt32: Int] = [0: -1, 1: -1]
        var index = 0

        while index < Self.discoveryCap {
            for role: UInt32 in [0, 1] {
                let string = try remappingWalletKitError {
                    try cardanoBaseAddress(
                        accountXpub: owner.xpub,
                        networkId: owner.network.addressNetworkId,
                        paymentRole: role,
                        paymentIndex: UInt32(index)
                    )
                }

                if known.contains(string) {
                    used.append(CardanoUsedAddress(
                        address: try CardanoAddress(string: string, network: owner.network),
                        index: UInt32(index),
                        role: role
                    ))
                    lastUsed[role] = index
                    remaining.remove(string)
                }
            }

            index += 1

            let gapReached = lastUsed.values.allSatisfy { index > $0 + Self.discoveryGap }
            if gapReached && remaining.isEmpty {
                break
            }
        }

        guard remaining.isEmpty else {
            throw WalletKitError.internalError(
                message: "Cardano discovery could not match \(remaining.count) known address(es) "
                    + "within \(Self.discoveryCap) indices: \(remaining.sorted().joined(separator: ", "))"
            )
        }

        return CardanoAddressUsage(used: used.sorted { ($0.role, $0.index) < ($1.role, $1.index) })
    }

    /// The account's UTxOs in CIP-30 form: datum and reference script
    /// included, in a stable (tx hash, index) order.
    public func dappUtxos(_ owner: CardanoAccountDescriptor) async throws -> [CardanoDappUtxoFfi] {
        var result: [CardanoDappUtxoFfi] = []

        for entry in try await accountUTxOs(owner) {
            guard
                let lovelace = entry.amount.first(where: { $0.unit == "lovelace" }),
                let hash = try? Data(hexString: entry.txHash)
            else {
                continue
            }

            let assets = entry.amount.compactMap { amount -> CardanoAssetFfi? in
                guard amount.unit != "lovelace", let parsed = CardanoAssetId(unit: amount.unit) else {
                    return nil
                }

                return parsed.ffi(quantity: amount.quantity)
            }

            result.append(CardanoDappUtxoFfi(
                address: entry.address,
                assets: assets,
                datumHash: try entry.dataHash.map { try Data(hexString: $0) },
                inlineDatum: try entry.inlineDatum.map { try Data(hexString: $0) },
                lovelace: lovelace.quantity,
                outputIndex: entry.outputIndex,
                scriptRef: try await entry.referenceScriptHash.asyncMap { try await scriptReference(hash: $0) },
                txHash: hash
            ))
        }

        return result.sorted { ($0.txHash.lowercaseHex, $0.outputIndex) < ($1.txHash.lowercaseHex, $1.outputIndex) }
    }

    /// What `transaction` needs from `owner`, per the CIP-30 ownership model.
    /// Reference inputs and their scripts are resolved from the chain; any
    /// that can't be is left out, which the resolver reports as unresolved.
    public func resolveSigners(transaction: Data, owner: CardanoAccountDescriptor) async throws -> CardanoSignersFfi {
        let decoded = try remappingWalletKitError { try cardanoDecodeTransaction(transaction: transaction) }
        let usage = try await addressUsage(owner)

        let ownedOutputs = try await accountUTxOs(owner).map { entry in
            CardanoResolvedOutputFfi(
                address: entry.address,
                outputIndex: entry.outputIndex,
                scriptHash: nil,
                txHash: try Data(hexString: entry.txHash)
            )
        }

        var referenceOutputs: [CardanoResolvedOutputFfi] = []
        var scripts: [CardanoResolvedScriptFfi] = []

        for input in decoded.referenceInputs {
            guard let output = try? await referenceOutput(txHash: input.txHash, index: input.outputIndex) else {
                continue
            }

            referenceOutputs.append(CardanoResolvedOutputFfi(
                address: output.address,
                outputIndex: input.outputIndex,
                scriptHash: try output.referenceScriptHash.map { try Data(hexString: $0) },
                txHash: input.txHash
            ))

            if let hash = output.referenceScriptHash, let script = try? await resolvedScript(hash: hash) {
                scripts.append(script)
            }
        }

        return try remappingWalletKitError {
            try cardanoRequiredSigners(
                transaction: transaction,
                accountXpub: owner.xpub,
                ownedOutputs: ownedOutputs,
                referenceOutputs: referenceOutputs,
                scripts: scripts,
                usedIndices: usage.indices
            )
        }
    }
}

// MARK: - Blockfrost lookups

private extension CardanoClient {
    struct ChainOutput: Decodable {
        let address: String
        let outputIndex: UInt32
        let referenceScriptHash: String?

        enum CodingKeys: String, CodingKey {
            case address
            case outputIndex = "output_index"
            case referenceScriptHash = "reference_script_hash"
        }
    }

    struct TransactionOutputs: Decodable {
        let outputs: [ChainOutput]
    }

    struct ScriptInfo: Decodable {
        let type: String
    }

    struct ScriptCbor: Decodable {
        let cbor: String?
    }

    struct ScriptJson: Decodable {
        let json: NativeScriptJson
    }

    /// cardano-cli native script JSON, re-encoded for Rust.
    struct NativeScriptJson: Codable {
        let keyHash: String?
        let required: Int?
        let scripts: [NativeScriptJson]?
        let slot: UInt64?
        let type: String
    }

    func referenceOutput(txHash: Data, index: UInt32) async throws -> ChainOutput? {
        let outputs: TransactionOutputs = try await get("txs/\(txHash.lowercaseHex)/utxos")

        return outputs.outputs.first { $0.outputIndex == index }
    }

    /// `ScriptRef` CBOR for the output field of a UTxO that carries `hash`.
    func scriptReference(hash: String) async throws -> Data {
        if let cached = await CardanoScriptCache.shared.reference(hash) {
            return cached
        }

        let info: ScriptInfo = try await get("scripts/\(hash)")
        let reference: Data

        switch info.type {
        case "timelock":
            let json = try await nativeScriptJson(hash: hash)
            reference = try remappingWalletKitError {
                try cardanoScriptRefNative(script: cardanoNativeScriptFromJson(json: json))
            }
        case "plutusV1", "plutusV2", "plutusV3":
            let script = try await plutusCbor(hash: hash)
            reference = try remappingWalletKitError {
                try cardanoScriptRefPlutus(version: info.version, script: script)
            }
        default:
            throw WalletKitError.internalError(message: "Unsupported Cardano script type \(info.type).")
        }

        await CardanoScriptCache.shared.store(reference: reference, for: hash)
        return reference
    }

    /// The script body for the signer resolver: native CBOR, or `nil` for Plutus.
    func resolvedScript(hash: String) async throws -> CardanoResolvedScriptFfi {
        if let cached = await CardanoScriptCache.shared.script(hash) {
            return cached
        }

        let info: ScriptInfo = try await get("scripts/\(hash)")
        var native: Data?
        if info.type == "timelock" {
            let json = try await nativeScriptJson(hash: hash)
            native = try remappingWalletKitError { try cardanoNativeScriptFromJson(json: json) }
        }
        let script = CardanoResolvedScriptFfi(hash: try Data(hexString: hash), nativeScript: native)

        await CardanoScriptCache.shared.store(script: script, for: hash)
        return script
    }

    func nativeScriptJson(hash: String) async throws -> String {
        let script: ScriptJson = try await get("scripts/\(hash)/json")
        let data = try JSONEncoder().encode(script.json)

        return String(decoding: data, as: UTF8.self)
    }

    func plutusCbor(hash: String) async throws -> Data {
        let script: ScriptCbor = try await get("scripts/\(hash)/cbor")

        guard let cbor = script.cbor else {
            throw WalletKitError.internalError(message: "Blockfrost has no CBOR for script \(hash).")
        }

        return try Data(hexString: cbor)
    }
}

private extension CardanoClient.ScriptInfo {
    var version: UInt8 {
        switch type {
        case "plutusV1": 1
        case "plutusV2": 2
        default: 3
        }
    }
}

private extension Data {
    var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else {
            return nil
        }

        return try await transform(self)
    }
}
