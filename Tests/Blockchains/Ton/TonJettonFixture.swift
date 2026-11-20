import BigInt
import CryptoKit
import Foundation
@testable import WalletKit

/// A six-decimal Jetton on the TON testnet that account 0 of `REEFR_TESTNET_MNEMONIC` administers and holds,
/// deployed on first use. The address follows from the admin key and the fixed content, so every run finds
/// the same Jetton.
///
/// The minter code is the standard token-contract minter (the code of an existing testnet minter, whose wallet code
/// hash is that of ton-blockchain/token-contract's `ft/build/jetton-wallet.boc`); the wallet code is that file.
struct TonJettonFixture {
    static let decimals = 6
    static let minted = BigUInt(1_000_000_000)
    /// Gram attached to the mint for deploying the owner's Jetton wallet.
    private static let walletAttachment = BigUInt(50_000_000)
    private static let minterAttachment = BigUInt(100_000_000)

    // swiftlint:disable line_length
    private static let minterCodeBase64 = "te6cckECDgEAAqMAART/APSkE/S88sgLAQIBYgIDAgLMBAUCA3pgDA0B9dkGOASS+B8ADoaYGAuNhJL4HwfSB9IBj9ABi465D9ABj9ABg51NoAAWmP6Z/2omh9AH0gamoYQAqpOF1HGZqamxsommOC+XAkgX0gfQBqGBBoQDBrkP0AGBKIGigheASKUCgZ5CgCfQEsZ4tmZmT2qnBBCD3uy+8pOF1AYAk7PwUIgG4KhAJqgoB5CgCfQEsZ4sA54tmZJFkZYCJegB6AGWAZJB8gDg6ZGWBZQPl/+ToO8AMZGWCrGeLKAJ9AQnltYlmZmS4/YBBPSO4DY3NwH6APpA+ChUEgZwVCATVBQDyFAE+gJYzxYBzxbMySLIywES9AD0AMsAyfkAcHTIywLKB8v/ydBQBscF8uBKoQNFRchQBPoCWM8WzMzJ7VQB+kAwINcLAcMAkVvjDeCCECx2uXNScLrjAjU3NyPAA+MCNQLABAcICQoAPoIQ1TJ223CAEMjLBVADzxYi+gISy2rLH8s/yYBC+wAB/jZfA4IImJaAFaAVvPLgSwL6QNMAMJXIIc8WyZFt4oIQ0XNUAHCAGMjLBVAFzxYk+gIUy2oTyx8Uyz8j+kQwcLqOM/goRANwVCATVBQDyFAE+gJYzxYBzxbMySLIywES9AD0AMsAyfkAcHTIywLKB8v/ydDPFpZsInABywHi9AALADQzUDXHBfLgSQP6QDBZyFAE+gJYzxbMzMntVABCjhhRJMcF8uBJ1DBDAMhQBPoCWM8WzMzJ7VTgXwWED/LwAArJgED7AAB9rbz2omh9AH0gamoYNhj8FAC4KhAJqgoB5CgCfQEsZ4sA54tmZJFkZYCJegB6AGWAZPyAODpkZYFlA+X/5OhAAB+vFvaiaH0AfSBqahg/qpBANJ/9Yw=="
    private static let walletCodeBase64 = "te6cckECEgEAAzQAART/APSkE/S88sgLAQIBYgIDAgLMBAUAG6D2BdqJofQB9IH0gahhAgHUBgcCAUgICQDDCDHAJJfBOAB0NMDAXGwlRNfA/AL4PpA+kAx+gAxcdch+gAx+gAwc6m0AALTH4IQD4p+pVIgupUxNFnwCOCCEBeNRRlSILqWMUREA/AJ4DWCEFlfB7y6k1nwCuBfBIQP8vCAAET6RDBwuvLhTYAIBIAoLAgEgEBEB8QD0z/6APpAIfAB7UTQ+gD6QPpA1DBRNqFSKscF8uLBKML/8uLCVDRCcFQgE1QUA8hQBPoCWM8WAc8WzMkiyMsBEvQA9ADLAMkg+QBwdMjLAsoHy//J0AT6QPQEMfoAINdJwgDy4sR3gBjIywVQCM8WcPoCF8trE8yAMA/c7UTQ+gD6QPpA1DAI0z/6AFFRoAX6QPpAU1vHBVRzbXBUIBNUFAPIUAT6AljPFgHPFszJIsjLARL0APQAywDJ+QBwdMjLAsoHy//J0FANxwUcsfLiwwr6AFGooYIImJaAggiYloAStgihggjk4cCgGKEn4w8l1wsBwwAjgDQ4PAK6CEBeNRRnIyx8Zyz9QB/oCIs8WUAbPFiX6AlADzxbJUAXMI5FykXHiUAioE6CCCOThwKoAggiYloCgoBS88uLFBMmAQPsAECPIUAT6AljPFgHPFszJ7VQAcFJ5oBihghBzYtCcyMsfUjDLP1j6AlAHzxZQB88WyXGAEMjLBSTPFlAG+gIVy2oUzMlx+wAQJBAjAA4QSRA4N18EAHbCALCOIYIQ1TJ223CAEMjLBVAIzxZQBPoCFstqEssfEss/yXL7AJM1bCHiA8hQBPoCWM8WAc8WzMntVADbO1E0PoA+kD6QNQwB9M/+gD6QDBRUaFSSccF8uLBJ8L/8uLCggjk4cCqABagFrzy4sOCEHvdl97Iyx8Vyz9QA/oCIs8WAc8WyXGAGMjLBSTPFnD6AstqzMmAQPsAQBPIUAT6AljPFgHPFszJ7VSAAgyAINch7UTQ+gD6QPpA1DAE0x+CEBeNRRlSILqCEHvdl94TuhKx8uLF0z8x+gAwE6BQI8hQBPoCWM8WAc8WzMntVIJMVCtQ="
    // swiftlint:enable line_length

    let client: TonClient
    let admin: TonPKeySigner

    var minter: TonAddress {
        get throws {
            let hash = try Self.stateInit(admin: admin.address()).hash
            return try TonAddress(workchain: 0, hash: hash, isBounceable: true, isTestOnly: true)
        }
    }

    /// Deploys the minter and mints `minted` to the admin if the minter is not active yet.
    func ensureDeployed() async throws {
        let master = try minter

        if try await client.accountState(master) == .active {
            return
        }

        let owner = try admin.address()
        let message = try deployMessage(owner: owner, master: master)
        _ = try await send(message, to: master, value: Self.minterAttachment)

        let deadline = ContinuousClock.now.advanced(by: .seconds(90))

        while try await client.accountState(master) != .active {
            guard ContinuousClock.now < deadline else {
                throw BlockchainClientError.transportError(reason: "the Jetton minter was not deployed in time")
            }

            try await Task.sleep(for: .seconds(3))
        }
    }

    /// Sends `amount` Jettons from the admin's wallet to `recipient`'s owner wallet with `attached` Gram, and
    /// returns the request's normalized hash.
    func transfer(amount: BigUInt, to recipient: TonAddress, attached: BigUInt) async throws -> String {
        let owner = try admin.address()
        let wallets = try await client.jettonWalletAddress(owner: owner, master: minter)
        let body = try TonJetton.transferBody(
            queryId: UInt64.random(in: 1 ... UInt64.max),
            amount: amount,
            destination: recipient,
            responseDestination: owner,
            forwardAmount: 1,
            comment: nil
        )

        let message = try TonWalletV5R1.internalMessage(to: wallets, amount: attached, bounce: true, body: body)
        return try await send(message, to: wallets, value: attached)
    }

    /// Signs and broadcasts an external request from the admin's wallet carrying `message`.
    private func send(_ message: TonCell, to destination: TonAddress, value: BigUInt) async throws -> String {
        let owner = try admin.address()
        let seqno = try await client.seqno(owner)
        let validUntil = UInt32(Date().timeIntervalSince1970 + 300)
        let body = try TonWalletV5R1.signingBody(
            network: .testnet,
            validUntil: validUntil,
            seqno: seqno,
            message: message
        )

        let request = TonUnsignedTransaction(
            body: TonBOC.serialize(body),
            network: .testnet,
            recipient: destination.string,
            sender: owner.string,
            seqno: seqno,
            stateInit: nil,
            validUntil: validUntil,
            value: String(value)
        )

        let data = try JSONEncoder().encode(request)
        let signature = try await admin.sign(transaction: data)
        return try await client.broadcast(transaction: data, signature: signature)
    }

    // MARK: Cells

    /// The message to the minter: its `StateInit` and a mint of `minted` to `owner`.
    private func deployMessage(owner: TonAddress, master: TonAddress) throws -> TonCell {
        var transfer = TonCellBuilder()
        transfer.storeUInt(TonJetton.internalTransferOpcode, bits: 32)
        transfer.storeUInt(0, bits: 64)
        transfer.storeCoins(Self.minted)
        transfer.storeAddress(nil)
        transfer.storeAddress(owner)
        transfer.storeCoins(0)
        transfer.storeBit(false)

        var mint = TonCellBuilder()
        mint.storeUInt(21, bits: 32)
        mint.storeUInt(0, bits: 64)
        mint.storeAddress(owner)
        mint.storeCoins(Self.walletAttachment)
        mint.storeRef(try transfer.build())

        return try TonWalletV5R1.internalMessage(
            to: master,
            amount: Self.minterAttachment,
            bounce: false,
            stateInit: try Self.stateInit(admin: owner),
            body: try mint.build()
        )
    }

    private static func stateInit(admin: TonAddress) throws -> TonCell {
        var data = TonCellBuilder()
        data.storeCoins(minted)
        data.storeAddress(admin)
        data.storeRef(try content())
        data.storeRef(try TonBOC.parse(try bytes(walletCodeBase64)))

        var builder = TonCellBuilder()
        [false, false, true, true, false].forEach { builder.storeBit($0) }
        builder.storeRef(try TonBOC.parse(try bytes(minterCodeBase64)))
        builder.storeRef(try data.build())
        return try builder.build()
    }

    /// TEP-64 on-chain metadata: `0x00` and a dictionary from the SHA-256 of each key to a snake-format value.
    private static func content() throws -> TonCell {
        let entries = ["decimals": String(decimals), "name": "Reefr Test Jetton", "symbol": "RTJ"]
        let leaves = try entries.map { key, value -> (bits: [Bool], value: TonCell) in
            var text = TonCellBuilder()
            text.storeUInt(0, bits: 8)
            text.storeBytes(Data(value.utf8))
            let hash = Data(SHA256.hash(data: Data(key.utf8)))
            return (hash.flatMap { byte in (0 ..< 8).map { byte >> (7 - $0) & 1 == 1 } }, try text.build())
        }

        var builder = TonCellBuilder()
        builder.storeUInt(0, bits: 8)
        builder.storeBit(true)
        builder.storeRef(try dictionary(leaves, keyBits: 256))
        return try builder.build()
    }

    /// A `Hashmap` node over `keyBits`-bit keys whose values are references.
    private static func dictionary(_ leaves: [(bits: [Bool], value: TonCell)], keyBits: Int) throws -> TonCell {
        var builder = TonCellBuilder()

        guard leaves.count > 1 else {
            let leaf = leaves[0]
            storeLabel(leaf.bits, maxLength: keyBits, into: &builder)
            builder.storeRef(leaf.value)
            return try builder.build()
        }

        var common = 0

        while common < leaves[0].bits.count, leaves.allSatisfy({ $0.bits[common] == leaves[0].bits[common] }) {
            common += 1
        }

        storeLabel(Array(leaves[0].bits[0 ..< common]), maxLength: keyBits, into: &builder)

        for side in [false, true] {
            let part = leaves.filter { $0.bits[common] == side }
                .map { (bits: Array($0.bits[(common + 1)...]), value: $0.value) }
            builder.storeRef(try dictionary(part, keyBits: keyBits - common - 1))
        }

        return try builder.build()
    }

    /// `hml_long`: `10`, the length in `ceil(log2(maxLength + 1))` bits, then the bits.
    private static func storeLabel(_ bits: [Bool], maxLength: Int, into builder: inout TonCellBuilder) {
        builder.storeBit(true)
        builder.storeBit(false)
        var width = 0

        while 1 << width < maxLength + 1 {
            width += 1
        }

        builder.storeUInt(UInt64(bits.count), bits: width)
        bits.forEach { builder.storeBit($0) }
    }

    private static func bytes(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid fixture code")
        }

        return data
    }
}
