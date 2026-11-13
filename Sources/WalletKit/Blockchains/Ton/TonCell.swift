//
//  TonCell.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import CryptoKit
import Foundation

/// An ordinary (level 0, non-exotic) TON cell: up to 1023 bits and 4 references.
struct TonCell: Equatable, Sendable {
    static let maxBits = 1_023
    static let maxRefs = 4
    static let empty = TonCell(unchecked: Data(), bitCount: 0, refs: [])

    /// Left-aligned data bits, zero-padded to a whole byte (no completion tag).
    let bits: Data
    let bitCount: Int
    let refs: [TonCell]
    let depth: Int
    let hash: Data

    init(bits: Data, bitCount: Int, refs: [TonCell]) throws {
        guard (0...Self.maxBits).contains(bitCount), bits.count == (bitCount + 7) / 8, refs.count <= Self.maxRefs else {
            throw WalletKitError.internalError(message: "Invalid TON cell: \(bitCount) bits, \(refs.count) refs")
        }

        self.init(unchecked: bits, bitCount: bitCount, refs: refs)
    }

    private init(unchecked bits: Data, bitCount: Int, refs: [TonCell]) {
        self.bits = bits
        self.bitCount = bitCount
        self.refs = refs
        depth = refs.map(\.depth).max().map { $0 + 1 } ?? 0

        var representation = Data([UInt8(refs.count), UInt8(bitCount / 8 + (bitCount + 7) / 8)])
        representation.append(Self.augmented(bits, bitCount: bitCount))
        refs.forEach { representation.append(contentsOf: [UInt8(($0.depth >> 8) & 0xFF), UInt8($0.depth & 0xFF)]) }
        refs.forEach { representation.append($0.hash) }
        hash = Data(SHA256.hash(data: representation))
    }

    static func == (lhs: TonCell, rhs: TonCell) -> Bool {
        lhs.hash == rhs.hash
    }

    /// Appends `data` to this cell's bits, keeping its references.
    func appending(_ data: Data) throws -> TonCell {
        var builder = TonCellBuilder()
        builder.storeBits(bits, count: bitCount)
        builder.storeBytes(data)
        refs.forEach { builder.storeRef($0) }
        return try builder.build()
    }

    /// The data with the completion tag set when the length isn't a whole number of bytes.
    static func augmented(_ bits: Data, bitCount: Int) -> Data {
        guard bitCount % 8 != 0 else {
            return bits
        }

        var result = bits
        result[result.count - 1] |= UInt8(0x80 >> (bitCount % 8))
        return result
    }
}

/// Appends bits and references to build a ``TonCell``.
struct TonCellBuilder {
    private var bitArray: [Bool] = []
    private var refs: [TonCell] = []
    private var failure: WalletKitError?

    var bitCount: Int { bitArray.count }
    var refCount: Int { refs.count }

    func build() throws -> TonCell {
        if let failure {
            throw failure
        }

        var bytes = Data(count: (bitArray.count + 7) / 8)

        for (index, bit) in bitArray.enumerated() where bit {
            bytes[index / 8] |= UInt8(0x80 >> (index % 8))
        }

        return try TonCell(bits: bytes, bitCount: bitArray.count, refs: refs)
    }

    /// `addr_std` (workchain and 256-bit hash), or `addr_none` for `nil`.
    mutating func storeAddress(_ address: TonAddress?) {
        guard let address else {
            storeUInt(0, bits: 2)
            return
        }

        storeUInt(2, bits: 2)
        storeBit(false)
        storeInt(Int64(address.workchain), bits: 8)
        storeBytes(address.hash)
    }

    /// Stores `cell` inline behind a `0` flag when its bits and references still fit, else by reference
    /// behind a `1` flag. `reserved` bits are kept free for what follows.
    mutating func storeInlineOrRef(_ cell: TonCell, reserved: Int = 0) {
        if bitCount + 1 + reserved + cell.bitCount <= TonCell.maxBits, refCount + cell.refs.count <= TonCell.maxRefs {
            storeBit(false)
            storeBits(cell.bits, count: cell.bitCount)
            cell.refs.forEach { storeRef($0) }
        } else {
            storeBit(true)
            storeRef(cell)
        }
    }

    mutating func storeBit(_ bit: Bool) {
        bitArray.append(bit)
    }

    mutating func storeBits(_ data: Data, count: Int) {
        for index in 0..<count {
            bitArray.append(data[data.startIndex + index / 8] & UInt8(0x80 >> (index % 8)) != 0)
        }
    }

    mutating func storeBytes(_ data: Data) {
        storeBits(data, count: data.count * 8)
    }

    /// `VarUInteger 16`: a 4-bit byte length, then the big-endian value.
    mutating func storeCoins(_ amount: BigUInt) {
        let bytes = amount == 0 ? Data() : amount.serialize()

        guard bytes.count < 16 else {
            failure = .internalError(message: "TON coins amount exceeds 120 bits")
            return
        }

        storeUInt(UInt64(bytes.count), bits: 4)
        storeBytes(bytes)
    }

    mutating func storeInt(_ value: Int64, bits: Int) {
        let mask = bits >= 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1
        storeUInt(UInt64(bitPattern: value) & mask, bits: bits)
    }

    mutating func storeMaybeRef(_ cell: TonCell?) {
        storeBit(cell != nil)

        if let cell {
            storeRef(cell)
        }
    }

    mutating func storeRef(_ cell: TonCell) {
        refs.append(cell)
    }

    mutating func storeUInt(_ value: UInt64, bits: Int) {
        for index in stride(from: bits - 1, through: 0, by: -1) {
            bitArray.append(index < 64 && (value >> UInt64(index)) & 1 == 1)
        }
    }
}

/// Serialization of cell trees to and from the standard bag of cells (BoC) format.
enum TonBOC {
    private static let magic: [UInt8] = [0xB5, 0xEE, 0x9C, 0x72]

    /// A single-root BoC, no index and no checksum.
    static func serialize(_ root: TonCell) -> Data {
        var order: [TonCell] = []
        var visited = Set<Data>()

        func visit(_ cell: TonCell) {
            guard visited.insert(cell.hash).inserted else {
                return
            }

            // Last reference first, as the reference SDK orders cells.
            cell.refs.reversed().forEach(visit)
            order.append(cell)
        }

        visit(root)
        order.reverse()

        var indices: [Data: Int] = [:]
        order.enumerated().forEach { indices[$1.hash] = $0 }

        let refSize = byteCount(order.count)
        var body = Data()

        for cell in order {
            body.append(UInt8(cell.refs.count))
            body.append(UInt8(cell.bitCount / 8 + (cell.bitCount + 7) / 8))
            body.append(TonCell.augmented(cell.bits, bitCount: cell.bitCount))
            cell.refs.forEach { body.append(bigEndian(indices[$0.hash] ?? 0, size: refSize)) }
        }

        let offsetSize = byteCount(body.count)
        var result = Data(magic)
        result.append(UInt8(refSize))
        result.append(UInt8(offsetSize))
        result.append(bigEndian(order.count, size: refSize))
        result.append(bigEndian(1, size: refSize))
        result.append(bigEndian(0, size: refSize))
        result.append(bigEndian(body.count, size: offsetSize))
        result.append(bigEndian(0, size: refSize))
        result.append(body)
        return result
    }

    /// The first root of `data`.
    static func parse(_ data: Data) throws -> TonCell {
        var reader = Reader(bytes: [UInt8](data))

        guard try reader.take(4) == magic else {
            throw WalletKitError.internalError(message: "Unsupported BoC magic")
        }

        let flags = try reader.number(1)
        let refSize = flags & 0x07
        let offsetSize = try reader.number(1)
        let cellCount = try reader.number(refSize)
        let rootCount = try reader.number(refSize)
        _ = try reader.number(refSize)
        let bodySize = try reader.number(offsetSize)

        guard rootCount >= 1, cellCount >= 1, refSize >= 1 else {
            throw WalletKitError.internalError(message: "Empty BoC")
        }

        let rootIndex = try reader.number(refSize)
        _ = try reader.take((rootCount - 1) * refSize)

        if flags & 0x80 != 0 {
            _ = try reader.take(cellCount * offsetSize)
        }

        var body = Reader(bytes: try reader.take(bodySize))
        let raw = try (0..<cellCount).map { _ in try RawCell(reading: &body, refSize: refSize) }
        var cells = [TonCell?](repeating: nil, count: cellCount)

        for index in stride(from: cellCount - 1, through: 0, by: -1) {
            let refs = try raw[index].refs.map { reference -> TonCell in
                guard reference > index, reference < cellCount, let cell = cells[reference] else {
                    throw WalletKitError.internalError(message: "Invalid BoC reference")
                }

                return cell
            }

            cells[index] = try TonCell(bits: raw[index].bits, bitCount: raw[index].bitCount, refs: refs)
        }

        guard rootIndex < cellCount, let root = cells[rootIndex] else {
            throw WalletKitError.internalError(message: "Invalid BoC root")
        }

        return root
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        mutating func number(_ count: Int) throws -> Int {
            try take(count).reduce(0) { $0 << 8 | Int($1) }
        }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, position + count <= bytes.count else {
                throw WalletKitError.internalError(message: "Truncated BoC")
            }

            defer { position += count }
            return Array(bytes[position..<position + count])
        }
    }

    private struct RawCell {
        let bits: Data
        let bitCount: Int
        let refs: [Int]

        init(reading reader: inout Reader, refSize: Int) throws {
            let descriptors = try reader.take(2)
            let refCount = Int(descriptors[0] & 0x07)
            let descriptor = Int(descriptors[1])

            guard descriptors[0] & 0x08 == 0, descriptors[0] >> 5 == 0 else {
                throw WalletKitError.internalError(message: "Unsupported exotic or leveled BoC cell")
            }

            var cellBits = try reader.take((descriptor + 1) / 2)
            var count = cellBits.count * 8

            if descriptor % 2 == 1 {
                guard let last = cellBits.last, last != 0 else {
                    throw WalletKitError.internalError(message: "Invalid BoC completion tag")
                }

                let trailing = last.trailingZeroBitCount
                cellBits[cellBits.count - 1] = last & ~(UInt8(1) << UInt8(trailing))
                count -= trailing + 1
            }

            bits = Data(cellBits)
            bitCount = count
            refs = try (0..<refCount).map { _ in try reader.number(refSize) }
        }
    }

    private static func bigEndian(_ value: Int, size: Int) -> Data {
        Data((0..<size).map { UInt8((value >> (8 * (size - 1 - $0))) & 0xFF) })
    }

    private static func byteCount(_ value: Int) -> Int {
        var size = 1

        while value >> (8 * size) != 0 {
            size += 1
        }

        return size
    }
}
