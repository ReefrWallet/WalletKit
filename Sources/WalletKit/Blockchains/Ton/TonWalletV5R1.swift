//
//  TonWalletV5R1.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// The V5R1 wallet contract (wallet-contract-v5): state init, wallet id and
/// the signed external messages that move Gram out of it.
enum TonWalletV5R1 {
    /// `+2`: ignore errors in the action phase. V5R1 requires it on externally signed requests.
    static let sendMode: UInt8 = 3

    private static let sendMessageTag: UInt64 = 0x0EC3_C86D
    private static let signedExternalOpcode: UInt64 = 0x7369_676E

    // swiftlint:disable:next line_length
    private static let codeHex = "b5ee9c7241021401000281000114ff00f4a413f4bcf2c80b01020120020d020148030402dcd020d749c120915b8f6320d70b1f2082106578746ebd21821073696e74bdb0925f03e082106578746eba8eb48020d72101d074d721fa4030fa44f828fa443058bd915be0ed44d0810141d721f4058307f40e6fa1319130e18040d721707fdb3ce03120d749810280b99130e070e2100f020120050c020120060902016e07080019adce76a2684020eb90eb85ffc00019af1df6a2684010eb90eb858fc00201480a0b0017b325fb51341c75c875c2c7e00011b262fb513435c280200019be5f0f6a2684080a0eb90fa02c0102f20e011e20d70b1f82107369676ebaf2e08a7f0f01e68ef0eda2edfb218308d722028308d723208020d721d31fd31fd31fed44d0d200d31f20d31fd3ffd70a000af90140ccf9109a28945f0adb31e1f2c087df02b35007b0f2d0845125baf2e0855036baf2e086f823bbf2d0882292f800de01a47fc8ca00cb1f01cf16c9ed542092f80fde70db3cd81003f6eda2edfb02f404216e926c218e4c0221d73930709421c700b38e2d01d72820761e436c20d749c008f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e093ed55e2d20001c000915be0ebd72c08142091709601d72c081c12e25210b1e30f20d74a111213009601fa4001fa44f828fa443058baf2e091ed44d0810141d718f405049d7fc8ca0040048307f453f2e08b8e14038307f45bf2e08c22d70a00216e01b3b0f2d090e2c85003cf1612f400c9ed54007230d72c08248e2d21f2e092d200ed44d0d2005113baf2d08f54503091319c01810140d721d70a00f2e08ee2c8ca0058cf16c9ed5493f2c08de20010935bdb31e1d74cd0b4d6c35e"

    static var code: TonCell {
        guard let data = TonAddress.data(hex: codeHex), let cell = try? TonBOC.parse(data) else {
            preconditionFailure("Invalid built-in TON V5R1 code")
        }

        return cell
    }

    /// `global_id ^ context_id` for the client context: workchain 0, wallet version 0, subwallet 0.
    static func walletId(network: TonNetwork) -> Int32 {
        network.globalId ^ Int32(bitPattern: 0x8000_0000)
    }

    /// The initial data cell: signatures allowed, `seqno` 0, wallet id, public key, no extensions.
    static func initialData(publicKey: Data, network: TonNetwork) -> TonCell {
        var builder = TonCellBuilder()
        builder.storeBit(true)
        builder.storeUInt(0, bits: 32)
        builder.storeUInt(UInt64(UInt32(bitPattern: walletId(network: network))), bits: 32)
        builder.storeBytes(publicKey)
        builder.storeBit(false)

        guard let cell = try? builder.build() else {
            preconditionFailure("V5R1 data cell exceeds limits")
        }

        return cell
    }

    /// The `StateInit` cell (code and data); its hash is the wallet's account hash.
    static func stateInit(publicKey: Data, network: TonNetwork) -> TonCell {
        var builder = TonCellBuilder()
        builder.storeBit(false)
        builder.storeBit(false)
        builder.storeBit(true)
        builder.storeBit(true)
        builder.storeBit(false)
        builder.storeRef(code)
        builder.storeRef(initialData(publicKey: publicKey, network: network))

        guard let cell = try? builder.build() else {
            preconditionFailure("V5R1 state init exceeds limits")
        }

        return cell
    }

    /// The unsigned request body: opcode, wallet id, expiry, `seqno` and one send-message action.
    static func signingBody(
        network: TonNetwork,
        validUntil: UInt32,
        seqno: UInt32,
        message: TonCell
    ) throws -> TonCell {
        var action = TonCellBuilder()
        action.storeRef(.empty)
        action.storeUInt(sendMessageTag, bits: 32)
        action.storeUInt(UInt64(sendMode), bits: 8)
        action.storeRef(message)

        var body = TonCellBuilder()
        body.storeUInt(signedExternalOpcode, bits: 32)
        body.storeUInt(UInt64(UInt32(bitPattern: walletId(network: network))), bits: 32)
        body.storeUInt(UInt64(validUntil), bits: 32)
        body.storeUInt(UInt64(seqno), bits: 32)
        body.storeMaybeRef(try action.build())
        body.storeBit(false)
        return try body.build()
    }

    /// An internal message carrying `amount` nanograms to `destination`, with an optional text comment.
    static func transferMessage(
        to destination: TonAddress,
        amount: BigUInt,
        bounce: Bool,
        comment: String?
    ) throws -> TonCell {
        var builder = TonCellBuilder()
        builder.storeBit(false)
        builder.storeBit(true)
        builder.storeBit(bounce)
        builder.storeBit(false)
        builder.storeAddress(nil)
        builder.storeAddress(destination)
        builder.storeCoins(amount)
        builder.storeBit(false)
        builder.storeCoins(0)
        builder.storeCoins(0)
        builder.storeUInt(0, bits: 64)
        builder.storeUInt(0, bits: 32)
        builder.storeBit(false)

        if let comment, !comment.isEmpty {
            var body = TonCellBuilder()
            body.storeUInt(0, bits: 32)
            body.storeBytes(Data(comment.utf8))
            let cell = try body.build()

            // Inline when it fits, as the reference SDK does; otherwise by reference.
            if builder.bitCount + 1 + cell.bitCount <= TonCell.maxBits {
                builder.storeBit(false)
                builder.storeBits(cell.bits, count: cell.bitCount)
            } else {
                builder.storeBit(true)
                builder.storeRef(cell)
            }
        } else {
            builder.storeBit(false)
        }

        return try builder.build()
    }

    /// The external-in message for `body`, with the wallet's `stateInit` when it is not yet deployed.
    static func externalMessage(
        to wallet: TonAddress,
        body: TonCell,
        stateInit: TonCell?
    ) throws -> TonCell {
        var builder = TonCellBuilder()
        builder.storeUInt(2, bits: 2)
        builder.storeAddress(nil)
        builder.storeAddress(wallet)
        builder.storeCoins(0)

        // Inline when it fits, as the reference SDK does; the body flag still has to fit after the init.
        if let stateInit {
            builder.storeBit(true)
            builder.storeInlineOrRef(stateInit, reserved: 1)
        } else {
            builder.storeBit(false)
        }

        builder.storeInlineOrRef(body)
        return try builder.build()
    }

    /// The TEP-467 normalized hash of an external-in message to `wallet`: no source, no import fee, no state init.
    static func normalizedHash(wallet: TonAddress, body: TonCell) throws -> Data {
        var builder = TonCellBuilder()
        builder.storeUInt(2, bits: 2)
        builder.storeAddress(nil)
        builder.storeAddress(wallet)
        builder.storeCoins(0)
        builder.storeBit(false)
        builder.storeBit(true)
        builder.storeRef(body)
        return try builder.build().hash
    }
}
