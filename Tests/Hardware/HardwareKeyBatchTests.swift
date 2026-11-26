import Foundation
import Testing
@testable import WalletKit

/// Batched device reads hand back parent xpubs for EVM and Tron, whose
/// children are then derived locally: those must equal per-path keys.
struct HardwareKeyBatchTests {
    private let seed: Seed

    init() throws {
        seed = try Mnemonic.fromEntropy(Data(repeating: 5, count: 16)).toSeed()
    }

    @Test(arguments: [Blockchain.evm(.ethereum(.mainnet)), .tron(.mainnet)])
    func childrenOfTheParentXpubEqualPerPathKeys(_ blockchain: Blockchain) throws {
        let master = try seed.masterKey(curve: .secp256k1)
        let first = try DerivationPath(blockchain, accountIndex: 0, curve: .secp256k1)
        let parentPath = DerivationPath(segments: Array(first.segments.dropLast()))
        let parent = try ExtendedKey.fromSerialized(master.derive(parentPath).serializedPublic(), curve: .secp256k1)

        for index in UInt32(0)..<5 {
            let path = try DerivationPath(blockchain, accountIndex: UInt64(index), curve: .secp256k1)
            let local = try parent.deriveChild(index: index, hardened: false).publicKey.rawBytes

            #expect(local == (try master.derive(path).publicKey.rawBytes))
        }
    }

    @Test func requestsMapToTheirFfiCases() throws {
        let path = try DerivationPath(string: "m/44'/501'/0'/0'")

        #expect(HardwareKeyRequest.publicKey(path, .ed25519).raw == .publicKey(path: path.raw, curve: .ed25519))
        #expect(HardwareKeyRequest.extendedPublicKey(path).raw == .extendedPublicKey(path: path.raw))
        #expect(HardwareKeyRequest.cardanoXpub(path).raw == .cardanoXpub(path: path.raw))
    }
}
