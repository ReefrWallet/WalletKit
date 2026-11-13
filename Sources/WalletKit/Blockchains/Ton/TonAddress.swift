//
//  TonAddress.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A TON `addr_std`: a workchain and a 256-bit account hash.
///
/// The friendly form is 36 bytes, base64 (standard or URL-safe): a tag byte
/// (`0x11` bounceable, `0x51` non-bounceable, `+0x80` testnet only), the
/// workchain, the hash and a CRC16-XMODEM checksum. The raw form is
/// `workchain:hex`.
public struct TonAddress: BlockchainAddress, Hashable {
    /// The account hash.
    public let hash: Data

    /// `nil` for a raw address, which carries no bounce intent.
    public let isBounceable: Bool?

    /// Whether the friendly tag marks the address as testnet only.
    public let isTestOnly: Bool

    public let workchain: Int8

    /// The friendly encoding, URL-safe base64. A raw address (no bounce
    /// intent) is rendered non-bounceable, the wallet form.
    public var string: String {
        let tag: UInt8 = (isBounceable ?? false ? 0x11 : 0x51) | (isTestOnly ? 0x80 : 0)
        var bytes = Data([tag, UInt8(bitPattern: workchain)])
        bytes.append(hash)
        let checksum = Self.crc16(bytes)
        bytes.append(contentsOf: [UInt8(checksum >> 8), UInt8(checksum & 0xFF)])
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// The raw form, `workchain:hex`.
    public var rawString: String {
        "\(workchain):\(hash.map { String(format: "%02x", $0) }.joined())"
    }

    /// The workchain byte followed by the 32-byte hash.
    public var rawBytes: Data {
        Data([UInt8(bitPattern: workchain)]) + hash
    }

    public init(workchain: Int8, hash: Data, isBounceable: Bool? = nil, isTestOnly: Bool = false) throws {
        guard hash.count == 32 else {
            throw WalletKitError.invalidAddress(reason: "expected a 32-byte account hash, got \(hash.count)")
        }

        self.workchain = workchain
        self.hash = hash
        self.isBounceable = isBounceable
        self.isTestOnly = isTestOnly
    }

    /// Parses a friendly (either base64 alphabet) or raw address.
    public init(string: String) throws {
        if string.contains(":") {
            let parts = string.split(separator: ":", omittingEmptySubsequences: false)

            guard parts.count == 2, let workchain = Int8(parts[0]), parts[1].count == 64,
                  let hash = Self.data(hex: String(parts[1]))
            else {
                throw WalletKitError.invalidAddress(reason: "malformed raw TON address")
            }

            try self.init(workchain: workchain, hash: hash)
            return
        }

        let normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard string.count == 48, let bytes = Data(base64Encoded: normalized), bytes.count == 36 else {
            throw WalletKitError.invalidAddress(reason: "expected 48 base64 characters")
        }

        let checksum = Self.crc16(bytes.prefix(34))

        guard bytes[34] == UInt8(checksum >> 8), bytes[35] == UInt8(checksum & 0xFF) else {
            throw WalletKitError.invalidAddress(reason: "bad TON address checksum")
        }

        let tag = bytes[0]

        guard tag & 0x7F == 0x11 || tag & 0x7F == 0x51 else {
            throw WalletKitError.invalidAddress(reason: "unknown TON address tag")
        }

        try self.init(
            workchain: Int8(bitPattern: bytes[1]),
            hash: bytes[2..<34],
            isBounceable: tag & 0x7F == 0x11,
            isTestOnly: tag & 0x80 != 0
        )
    }

    /// Accepts `workchain` byte plus 32-byte hash, as in ``rawBytes``.
    public init(rawBytes: Data) throws {
        guard rawBytes.count == 33 else {
            throw WalletKitError.invalidAddress(reason: "expected 33 raw bytes, got \(rawBytes.count)")
        }

        try self.init(workchain: Int8(bitPattern: rawBytes[rawBytes.startIndex]), hash: rawBytes.dropFirst())
    }

    /// The V5R1 wallet address for `publicKey` on `network`: non-bounceable, testnet tagged on testnet.
    public init(publicKey: PublicKey, network: TonNetwork) throws {
        guard publicKey.curve == .ed25519 else {
            throw WalletKitError.unsupportedCurve(curve: publicKey.curve)
        }

        try self.init(
            workchain: 0,
            hash: TonWalletV5R1.stateInit(publicKey: publicKey.rawBytes, network: network).hash,
            isBounceable: false,
            isTestOnly: network == .testnet
        )
    }

    public static func == (lhs: TonAddress, rhs: TonAddress) -> Bool {
        lhs.workchain == rhs.workchain && lhs.hash == rhs.hash
    }

    /// The same address with the given bounce intent.
    public func bounceable(_ isBounceable: Bool) throws -> TonAddress {
        try TonAddress(workchain: workchain, hash: hash, isBounceable: isBounceable, isTestOnly: isTestOnly)
    }

    /// Throws if the address can't be used on `network`: a testnet-only tag is rejected on mainnet.
    public func validate(for network: TonNetwork) throws {
        guard network == .testnet || !isTestOnly else {
            throw WalletKitError.invalidAddress(reason: "testnet-only TON address used on mainnet")
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(workchain)
        hasher.combine(hash)
    }

    static func crc16(_ data: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0

        for byte in data {
            crc ^= UInt16(byte) << 8

            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }

        return crc
    }

    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else {
            return nil
        }

        var result = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)

            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }

            result.append(byte)
            index = next
        }

        return result
    }
}
