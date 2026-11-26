import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

/// Offline coverage of the "ever used" checks account discovery relies on.
@Suite(.timeLimit(.minutes(1)))
struct AccountActivityTests {
    // MARK: EVM

    @Test func evmBatchReadsNoncesThenBalancesOfTheRest() async throws {
        let addresses = try (1...3).map { try EthereumAddress(rawBytes: Data(repeating: UInt8($0), count: 20)) }
        let stub = StubURLProtocol.makeSession { body in
            let text = body.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            // Address 1 has sent; address 2 only holds a balance; address 3 is unused.
            let reply = text.contains("eth_getTransactionCount")
                ? #"[{"jsonrpc":"2.0","id":1,"result":"0x2"},{"jsonrpc":"2.0","id":2,"result":"0x0"},"#
                    + #"{"jsonrpc":"2.0","id":3,"result":"0x0"}]"#
                : #"[{"jsonrpc":"2.0","id":1,"result":"0x5"},{"jsonrpc":"2.0","id":2,"result":"0x0"}]"#
            return .success(body: Data(reply.utf8))
        }

        let client = EthereumRPCClient(endpoint: URL(string: "https://example.com/rpc")!, session: stub.urlSession)

        #expect(try await client.activity(of: addresses) == [true, true, false])
        #expect(stub.capturedRequests.count == 2)
    }

    @Test func evmFallsBackPerAddressWhenBatchesAreRejected() async throws {
        let address = try EthereumAddress(rawBytes: Data(repeating: 7, count: 20))
        let stub = StubURLProtocol.makeSession { body in
            let text = body.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""

            guard !text.hasPrefix("[") else {
                return .success(statusCode: 400, body: Data(#"{"error":"batch not supported"}"#.utf8))
            }

            let result = text.contains("eth_getBalance") ? "0x0" : "0x1"
            return .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"\#(result)"}"#.utf8))
        }

        let client = EthereumRPCClient(endpoint: URL(string: "https://example.com/rpc")!, session: stub.urlSession)

        #expect(try await client.activity(of: [address]) == [true])
    }

    // MARK: Solana

    @Test func solanaTokenOnlyOwnerIsUsed() async throws {
        let owner = try SolanaAddress(rawBytes: Data(repeating: 3, count: 32))
        let stub = StubURLProtocol.makeSession { body in
            let text = body.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            let result = if text.contains("getMultipleAccounts") {
                #"{"context":{"slot":1},"value":[null]}"#
            } else if text.contains("getSignaturesForAddress") {
                "[]"
            } else if text.contains(SolanaProgram.token.string) {
                #"{"context":{"slot":1},"value":[]}"#
            } else {
                Self.solanaTokenAccounts(owner: owner)
            }

            return .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":\#(result)}"#.utf8))
        }

        let client = SolanaRPCClient(endpoint: URL(string: "https://example.com/rpc")!, session: stub.urlSession)

        #expect(try await client.activity(of: [owner]) == [true])
    }

    @Test func solanaOwnerWithoutLamportsHistoryOrTokensIsUnused() async throws {
        let owner = try SolanaAddress(rawBytes: Data(repeating: 4, count: 32))
        let stub = StubURLProtocol.makeSession { body in
            let text = body.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            let result = if text.contains("getMultipleAccounts") {
                #"{"context":{"slot":1},"value":[null]}"#
            } else if text.contains("getSignaturesForAddress") {
                "[]"
            } else {
                #"{"context":{"slot":1},"value":[]}"#
            }

            return .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":\#(result)}"#.utf8))
        }

        let client = SolanaRPCClient(endpoint: URL(string: "https://example.com/rpc")!, session: stub.urlSession)

        #expect(try await client.activity(of: [owner]) == [false])
    }

    @Test func aShortSolanaAccountsPageIsRejected() async throws {
        let owners = try (5...6).map { try SolanaAddress(rawBytes: Data(repeating: UInt8($0), count: 32)) }
        let oneAccount = #"{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":1},"value":[null]}}"#
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(oneAccount.utf8)))

        let client = SolanaRPCClient(endpoint: URL(string: "https://example.com/rpc")!, session: stub.urlSession)

        await #expect(throws: BlockchainClientError.self) {
            try await client.activity(of: owners)
        }
    }

    private static func solanaTokenAccounts(owner: SolanaAddress) -> String {
        let mint = SolanaProgram.token.string
        return #"{"context":{"slot":1},"value":[{"pubkey":"\#(owner.string)","account":{"data":{"parsed":{"info":"#
            + #"{"mint":"\#(mint)","owner":"\#(owner.string)","tokenAmount":{"amount":"5","decimals":0}}}}}}]}"#
    }

    // MARK: TON

    private static let noTonTransactions = #"{"transactions":[],"address_book":{}}"#

    private func tonWallet() throws -> TonAddress {
        try TonAddress(workchain: 0, hash: Data(repeating: 0x11, count: 32))
    }

    private func tonInformation(balance: String, state: String, lt: String = "0") -> String {
        #"{"ok":true,"result":{"balance":"\#(balance)","state":"\#(state)","#
            + #""last_transaction_id":{"lt":"\#(lt)","hash":""}}}"#
    }

    @Test func tonFundedUndeployedWalletIsUsed() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", tonInformation(balance: "5", state: "uninitialized"))

        #expect(try await TonClient(network: .mainnet, transport: transport).isActiveAccount(tonWallet()))
    }

    @Test func tonDeletedWalletWithHistoryIsUsed() async throws {
        let transport = FakeTonTransport()
        let hash = Data(repeating: 1, count: 32).base64EncodedString()
        transport.route("getAddressInformation", tonInformation(balance: "0", state: "uninitialized"))
        transport.route("transactions", #"{"transactions":["#
            + #"{"hash":"\#(hash)","lt":"500","now":1700000000,"total_fees":"1","#
            + #""description":{"aborted":false,"compute_ph":{"success":true}},"in_msg":null,"out_msgs":[]}"#
            + #"],"address_book":{}}"#)

        #expect(try await TonClient(network: .mainnet, transport: transport).isActiveAccount(tonWallet()))
    }

    @Test func tonJettonOnlyWalletIsUsed() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", tonInformation(balance: "0", state: "uninitialized"))
        transport.route("transactions", Self.noTonTransactions)
        transport.route("wallets", #"{"jetton_wallets":[{"balance":"7","jetton":"\#(try tonWallet().rawString)"}]}"#)

        #expect(try await TonClient(network: .mainnet, transport: transport).isActiveAccount(tonWallet()))
    }

    @Test func tonNeverUsedWalletIsUnused() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", tonInformation(balance: "0", state: "uninitialized"))
        transport.route("transactions", Self.noTonTransactions)
        transport.route("wallets", #"{"jetton_wallets":[]}"#)

        #expect(try await !TonClient(network: .mainnet, transport: transport).isActiveAccount(tonWallet()))
    }

    // MARK: Tron

    @Test func tronTrc20OnlyAccountIsUsed() async throws {
        let owner = try TronAddress(string: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7")
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/wallet/getaccount": .success(body: Data("{}".utf8)),
            "/v1/accounts/\(owner.string)/transactions/trc20": .success(body: Data(#"{"data":[{"transaction_id":"ab"}]}"#.utf8))
        ])
        let client = TronClient(endpoint: URL(string: "https://api.trongrid.io")!, session: stub.urlSession)

        #expect(try await client.isActiveAccount(owner))
    }

    @Test func tronUnactivatedAccountWithoutTrc20IsUnused() async throws {
        let owner = try TronAddress(string: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7")
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/wallet/getaccount": .success(body: Data("{}".utf8)),
            "/v1/accounts/\(owner.string)/transactions/trc20": .success(body: Data(#"{"data":[]}"#.utf8))
        ])
        let client = TronClient(endpoint: URL(string: "https://api.trongrid.io")!, session: stub.urlSession)

        #expect(try await !client.isActiveAccount(owner))
    }

    // MARK: Cardano

    private let cardanoEndpoint = URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!
    private let cardanoPath = try! DerivationPath(string: "m/1852'/1815'/0'") // swiftlint:disable:this force_try

    private func cardanoAccount(_ byte: UInt8) throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: Data(repeating: byte, count: 16), network: .preprod, path: cardanoPath)
    }

    private func cardanoClient(owner: CardanoAccountDescriptor, listed: [String]) -> CardanoClient {
        let addresses = listed.map { #"{"address":"\#($0)"}"# }.joined(separator: ",")
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": .success(body: Data("[]".utf8)),
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": .success(body: Data("[\(addresses)]".utf8))
        ])
        return CardanoClient(endpoint: cardanoEndpoint, projectId: "project-id", session: stub.urlSession)
    }

    @Test func cardanoSpentOutOwnAddressMakesTheAccountUsed() async throws {
        let owner = try cardanoAccount(0)
        let client = cardanoClient(owner: owner, listed: [try owner.address(role: 0, index: 2).string])

        #expect(try await client.isUsedAccount(owner))
    }

    @Test func cardanoAddressOnlySharingTheStakeKeyDoesNotCount() async throws {
        let owner = try cardanoAccount(0)
        let stranger = try cardanoAccount(9).receiveAddress.string
        let client = cardanoClient(owner: owner, listed: [stranger])

        #expect(try await !client.isUsedAccount(owner))
    }

    // MARK: Bitcoin

    private func bitcoinAccount() throws -> BitcoinDescriptor {
        let seed = try Mnemonic.fromEntropy(Data(repeating: 1, count: 16)).toSeed()
        let master = try seed.masterKey(curve: .secp256k1)
        let path = try DerivationPath.bitcoinAccount(network: .regtest, scriptType: .p2wpkh, accountIndex: 0)

        return try BitcoinDescriptor(
            xpub: master.derive(path).serializedPublic(),
            scriptType: .p2wpkh,
            network: .regtest,
            masterFingerprint: BitcoinDescriptor.fingerprint(of: master.publicKey),
            accountPath: String(path.string.dropFirst(2))
        )
    }

    @Test func bitcoinSpentReceiveAddressMakesTheAccountUsed() async throws {
        let account = try bitcoinAccount()
        let backend = HistoryBitcoinBackend(used: [try account.deriveAddress(chain: 0, index: 4).scriptPubkey()])

        #expect(try await BitcoinClient(backend: backend).hasExternalHistory(account))
    }

    @Test func bitcoinChangeOnlyHistoryDoesNotCount() async throws {
        let account = try bitcoinAccount()
        let backend = HistoryBitcoinBackend(used: [try account.deriveAddress(chain: 1, index: 0).scriptPubkey()])
        let client = BitcoinClient(backend: backend)

        #expect(try await !client.hasExternalHistory(account))
        #expect(try await client.isActiveAccount(account))
    }
}

/// History for a fixed set of scripts; everything else is unused.
private struct HistoryBitcoinBackend: BitcoinBackend {
    let used: Set<Data>

    func balance(of address: BitcoinAddressFfi) async throws -> (confirmed: UInt64, unconfirmed: Int64) {
        (0, 0)
    }

    func history(of address: BitcoinAddressFfi) async throws -> [BitcoinBackendHistoryEntry] {
        used.contains(address.scriptPubkey())
            ? [BitcoinBackendHistoryEntry(txid: String(repeating: "a", count: 64), height: 100)]
            : []
    }

    func utxos(of address: BitcoinAddressFfi, chain: UInt32, index: UInt32) async throws -> [BitcoinUTXO] {
        []
    }

    func transaction(txid: String) async throws -> BitcoinBackendTransaction {
        throw WalletKitError.unsupportedFeature
    }

    func rawTransaction(txid: String) async throws -> Data {
        throw WalletKitError.unsupportedFeature
    }

    func estimateFeeRate(blocks: Int) async throws -> Double {
        1
    }

    func broadcast(rawTransaction: Data) async throws -> String {
        throw WalletKitError.unsupportedFeature
    }

    func currentHeight() async throws -> UInt64 {
        100
    }

    func headsStream() -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        AsyncThrowingStream { $0.finish(throwing: WalletKitError.unsupportedFeature) }
    }
}
