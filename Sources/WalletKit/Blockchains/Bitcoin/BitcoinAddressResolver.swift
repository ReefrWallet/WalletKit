//
//  BitcoinAddressResolver.swift
//  WalletKit
//

import Foundation
import WalletKitRust

/// Derives addresses from a ``BitcoinDescriptor`` and discovers which ones
/// have on-chain history, using a gap limit: it keeps deriving until it
/// has seen `gapLimit` consecutive unused addresses past the last used
/// one. Backend-agnostic — constructed with `any BitcoinBackend`, so the
/// same discovery logic runs unchanged over Electrum or Esplora.
///
/// A ``BitcoinScriptType/singleAddress`` descriptor (watch-only, no keys)
/// has exactly one address regardless of `chain`/`index` — discovery
/// short-circuits to checking that one address once, rather than the
/// gap-limit loop (which would either spin needlessly or, if that address
/// has history, never terminate at all).
actor BitcoinAddressResolver {
    struct DerivedAddress: Sendable {
        let address: BitcoinAddressFfi
        let chain: UInt32
        let index: UInt32
        let isUsed: Bool
    }

    private let descriptor: BitcoinDescriptor
    private let backend: any BitcoinBackend
    private let gapLimit: UInt32

    /// Addresses discovered so far, per chain, ordered by index.
    private var discovered: [UInt32: [DerivedAddress]] = [:]

    init(descriptor: BitcoinDescriptor, backend: any BitcoinBackend, gapLimit: UInt32 = 20) {
        self.descriptor = descriptor
        self.backend = backend
        self.gapLimit = gapLimit
    }

    /// Every address discovered so far for `chain` (`0` external, `1`
    /// change), extending discovery first if this chain hasn't been
    /// scanned yet.
    func addresses(chain: UInt32) async throws -> [DerivedAddress] {
        if discovered[chain] == nil {
            try await extend(chain: chain)
        }
        return discovered[chain] ?? []
    }

    /// Every discovered address across both chains.
    func allAddresses() async throws -> [DerivedAddress] {
        let external = try await addresses(chain: 0)
        let change = try await addresses(chain: 1)
        return external + change
    }

    /// The first unused address on `chain` — the receive address (chain
    /// `0`) or a fresh change address (chain `1`). For a
    /// ``BitcoinScriptType/singleAddress`` descriptor this is always its
    /// one wrapped address, used or not.
    func firstUnused(chain: UInt32) async throws -> DerivedAddress {
        let existing = try await addresses(chain: chain)

        if descriptor.scriptType == .singleAddress {
            guard let only = existing.first else {
                throw WalletKitError.internalError(message: "single-address descriptor discovered no address")
            }
            return only
        }

        if let unused = existing.first(where: { !$0.isUsed }) {
            return unused
        }

        // Every discovered address on this chain is used — grow by one
        // more gap-limit window and retry.
        try await extend(chain: chain)
        return try await firstUnused(chain: chain)
    }

    /// Every unspent output across every discovered, used address on
    /// both chains.
    func allUTXOs() async throws -> [BitcoinUTXO] {
        var result: [BitcoinUTXO] = []
        for derived in try await allAddresses() where derived.isUsed {
            result.append(contentsOf: try await backend.utxos(of: derived.address, chain: derived.chain, index: derived.index))
        }
        return result
    }

    // MARK: - Private

    /// Derives and checks addresses starting at the next undiscovered
    /// index for `chain`, continuing until `gapLimit` consecutive unused
    /// addresses have been found past the last used one.
    private func extend(chain: UInt32) async throws {
        if descriptor.scriptType == .singleAddress {
            guard discovered[chain] == nil else { return }
            let address = try descriptor.deriveAddress(chain: chain, index: 0)
            let history = try await backend.history(of: address)
            discovered[chain] = [DerivedAddress(address: address, chain: chain, index: 0, isUsed: !history.isEmpty)]
            return
        }

        var addresses = discovered[chain] ?? []
        var index = UInt32(addresses.count)

        var consecutiveUnused: UInt32 = 0
        for derived in addresses.reversed() {
            guard !derived.isUsed else { break }
            consecutiveUnused += 1
        }

        while consecutiveUnused < gapLimit {
            let address = try descriptor.deriveAddress(chain: chain, index: index)
            let history = try await backend.history(of: address)
            let isUsed = !history.isEmpty
            addresses.append(DerivedAddress(address: address, chain: chain, index: index, isUsed: isUsed))
            consecutiveUnused = isUsed ? 0 : consecutiveUnused + 1
            index += 1
        }

        discovered[chain] = addresses
    }
}
