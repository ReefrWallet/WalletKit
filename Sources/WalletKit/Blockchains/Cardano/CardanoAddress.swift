import Foundation
import WalletKitRust

/// A validated Shelley-era Cardano recipient address.
public struct CardanoAddress: BlockchainAddress {
    public let string: String
    public let network: CardanoNetwork

    public var rawBytes: Data { Data(string.utf8) }

    public init(string: String) throws {
        let network: CardanoNetwork = string.hasPrefix("addr1") ? .mainnet : .preprod

        guard cardanoValidateAddress(address: string, networkId: network.addressNetworkId) else {
            throw WalletKitError.invalidAddress(reason: "Invalid Cardano address")
        }

        self.string = string
        self.network = network
    }

    public init(string: String, network: CardanoNetwork) throws {
        guard cardanoValidateAddress(address: string, networkId: network.addressNetworkId) else {
            throw WalletKitError.invalidAddress(reason: "Address does not belong to \(network.name)")
        }

        self.string = string
        self.network = network
    }

    public init(rawBytes: Data) throws {
        guard let string = String(data: rawBytes, encoding: .utf8) else {
            throw WalletKitError.invalidAddress(reason: "Cardano address bytes are not UTF-8")
        }

        try self.init(string: string)
    }
}

/// A CIP-1852 Cardano account identity backed by a public account key.
///
/// The descriptor is stored in `Account.address`, while ``receiveAddress`` is
/// the human-facing address shown to the person using the wallet.
public struct CardanoAccountDescriptor: BlockchainAddress {
    public let network: CardanoNetwork
    public let xpub: String

    public var rawBytes: Data { Data(string.utf8) }

    public var string: String { "cardano:\(network.storageIdentifier):\(xpub)" }

    public init(string: String) throws {
        let components = string.split(separator: ":", maxSplits: 2).map(String.init)
        guard components.count == 3, components[0] == "cardano",
              let network = CardanoNetwork(storageIdentifier: components[1]) else {
            throw WalletKitError.invalidAddress(reason: "Invalid Cardano account descriptor")
        }

        _ = try cardanoBaseAddress(
            accountXpub: components[2],
            networkId: network.addressNetworkId,
            paymentRole: 0,
            paymentIndex: 0
        )

        self.network = network
        xpub = components[2]
    }

    public init(entropy: Data, network: CardanoNetwork, accountIndex: UInt32) throws {
        self.network = network
        xpub = try cardanoAccountXpubFromEntropy(entropy: entropy, accountIndex: accountIndex)
    }

    public init(xpub: String, network: CardanoNetwork) throws {
        _ = try cardanoBaseAddress(
            accountXpub: xpub,
            networkId: network.addressNetworkId,
            paymentRole: 0,
            paymentIndex: 0
        )

        self.network = network
        self.xpub = xpub
    }

    public init(rawBytes: Data) throws {
        guard let string = String(data: rawBytes, encoding: .utf8) else {
            throw WalletKitError.invalidAddress(reason: "Cardano account descriptor bytes are not UTF-8")
        }

        try self.init(string: string)
    }

    public func address(role: UInt32, index: UInt32) throws -> CardanoAddress {
        let string = try cardanoBaseAddress(
            accountXpub: xpub,
            networkId: network.addressNetworkId,
            paymentRole: role,
            paymentIndex: index
        )

        return try CardanoAddress(string: string, network: network)
    }

    /// The CIP-1852 external (role 0) and internal (role 1) paths of the
    /// `addresses` this account owns, searched up to `searchLimit` indices per role.
    func signingPaths(
        for addresses: Set<String>,
        searchLimit: UInt32 = 1_000
    ) throws -> [String: CardanoSigningPathFfi] {
        var paths: [String: CardanoSigningPathFfi] = [:]

        for index in 0..<searchLimit where paths.count < addresses.count {
            for role: UInt32 in [0, 1] {
                let address = try address(role: role, index: index).string
                if addresses.contains(address) {
                    paths[address] = CardanoSigningPathFfi(index: index, role: role)
                }
            }
        }

        return paths
    }

    public var receiveAddress: CardanoAddress {
        try! address(role: 0, index: 0) // swiftlint:disable:this force_try
    }

    public var stakeAddress: String {
        try! cardanoStakeAddress( // swiftlint:disable:this force_try
            accountXpub: xpub,
            networkId: network.addressNetworkId
        )
    }
}

/// An account descriptor for a sender or a validated recipient address.
public enum CardanoTransactionAddress: BlockchainAddress {
    case account(CardanoAccountDescriptor)
    case recipient(CardanoAddress)

    public var rawBytes: Data { Data(string.utf8) }

    public var string: String {
        switch self {
        case let .account(descriptor): descriptor.string
        case let .recipient(address): address.string
        }
    }

    public init(string: String) throws {
        if string.hasPrefix("cardano:") {
            self = .account(try CardanoAccountDescriptor(string: string))
        } else {
            self = .recipient(try CardanoAddress(string: string))
        }
    }

    public init(rawBytes: Data) throws {
        guard let string = String(data: rawBytes, encoding: .utf8) else {
            throw WalletKitError.invalidAddress(reason: "Cardano transaction address bytes are not UTF-8")
        }

        try self.init(string: string)
    }
}

/// Matches a built transaction's inputs back to the payment paths of the UTxOs they spend.
enum CardanoInputPaths {
    static func key(txHash: Data, outputIndex: UInt32) -> String {
        "\(txHash.base64EncodedString())#\(outputIndex)"
    }

    /// One witness path per distinct address the inputs spend from.
    static func signingPaths(
        of inputs: [CardanoTransactionInputFfi],
        pathsByInput: [String: CardanoSigningPathFfi]
    ) throws -> [CardanoSigningPathFfi] {
        var paths: [CardanoSigningPathFfi] = []

        for input in inputs {
            guard let path = pathsByInput[key(txHash: input.txHash, outputIndex: input.outputIndex)] else {
                throw WalletKitError.internalError(message: "Cardano input has no signing path")
            }

            if !paths.contains(path) {
                paths.append(path)
            }
        }

        return paths
    }
}
