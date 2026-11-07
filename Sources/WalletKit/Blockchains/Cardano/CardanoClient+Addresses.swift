import BigInt
import Foundation
import WalletKitRust

/// One complete read of an account's UTxOs: totals per unit and ADA per address.
public struct CardanoUTxOSnapshot: Equatable, Sendable {
    /// Totals per asset unit (`lovelace` for ADA).
    public let balances: [String: BigUInt]
    /// Lovelace per payment address holding a UTxO.
    public let lovelaceByAddress: [String: BigUInt]

    public var addresses: Set<String> { Set(lovelaceByAddress.keys) }

    public static let empty = CardanoUTxOSnapshot(balances: [:], lovelaceByAddress: [:])
}

/// One external (receive) address of an account.
public struct CardanoReceiveAddress: Equatable, Sendable {
    public let address: CardanoAddress
    public let index: UInt32
    /// Whether the address has on-chain history or holds a UTxO.
    public let isUsed: Bool
    public let lovelace: BigUInt
}

extension CardanoClient {
    /// Reads every UTxO of `owner` once.
    public func utxoSnapshot(_ owner: CardanoAccountDescriptor) async throws -> CardanoUTxOSnapshot {
        let entries = try await accountUTxOs(owner)
        var balances: [String: BigUInt] = [:]
        var lovelaceByAddress: [String: BigUInt] = [:]

        for entry in entries {
            for amount in entry.amount {
                guard let quantity = BigUInt(amount.quantity) else {
                    continue
                }

                balances[amount.unit, default: 0] += quantity

                if amount.unit == "lovelace" {
                    lovelaceByAddress[entry.address, default: 0] += quantity
                }
            }
        }

        return CardanoUTxOSnapshot(balances: balances, lovelaceByAddress: lovelaceByAddress)
    }

    /// The external addresses for `{0} ∪ used ∪ indices`, sorted by index.
    ///
    /// Addresses Blockfrost associates with the stake key but the account didn't derive
    /// are ignored.
    public func receiveAddresses(
        _ owner: CardanoAccountDescriptor,
        including indices: Set<UInt32>,
        snapshot: CardanoUTxOSnapshot
    ) async throws -> [CardanoReceiveAddress] {
        guard indices.allSatisfy({ $0 < CardanoAccountDescriptor.addressIndexLimit }) else {
            throw WalletKitError.internalError(
                message: "Cardano address index must be below \(CardanoAccountDescriptor.addressIndexLimit)."
            )
        }

        let usage = try await scanUsage(owner, utxoAddresses: snapshot.addresses)
        let used = Set(usage.used.filter { $0.role == 0 }.map(\.index))
        var rows: [CardanoReceiveAddress] = []

        for index in used.union(indices).union([0]).sorted() {
            let address = try owner.address(role: 0, index: index)

            rows.append(CardanoReceiveAddress(
                address: address,
                index: index,
                isUsed: used.contains(index),
                lovelace: snapshot.lovelaceByAddress[address.string] ?? 0
            ))
        }

        return rows
    }
}
