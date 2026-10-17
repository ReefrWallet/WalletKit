import BigInt
import Foundation
import Testing
@testable import WalletKit

struct AptosClientTests {
    private let endpoint = URL(string: "https://api.testnet.aptoslabs.com/v1")!
    private let owner = try! AptosAddress( // swiftlint:disable:this force_try
        string: "0xbd8c58f3cc25767971e77f8685ed4233180215e05c73e7946c21bf90b4e2813e"
    )

    private func client(_ stub: StubURLProtocol.Session, apiKey: String? = "key") -> AptosClient {
        AptosClient(
            endpoint: endpoint,
            indexerURL: AptosNetwork.testnet.indexerURL,
            apiKey: apiKey,
            session: stub.urlSession
        )
    }

    private func json(_ text: String) -> StubURLProtocol.StubResponse {
        .success(body: Data(text.utf8))
    }

    @Test func nativeBalanceReadsTheNodeAndSendsTheApiKey() async throws {
        let stub = StubURLProtocol.makeSession(response: json("48934400"))

        #expect(try await client(stub).getNativeBalance(owner) == 48_934_400)
        #expect(stub.capturedRequest?.url?.path == "/v1/accounts/\(owner.longString)/balance/0x1::aptos_coin::AptosCoin")
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    }

    @Test func blankApiKeyIsOmitted() async throws {
        let stub = StubURLProtocol.makeSession(response: json("0"))
        _ = try await client(stub, apiKey: "  ").getNativeBalance(owner)
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func sequenceNumberDecodesStringU64() async throws {
        let stub = StubURLProtocol.makeSession(response: json(#"{"sequence_number":"17","authentication_key":"0x1"}"#))
        #expect(try await client(stub).sequenceNumber(of: owner) == 17)
    }

    @Test func ledgerInfoDecodes() async throws {
        let stub = StubURLProtocol.makeSession(response: json(
            #"{"chain_id":2,"ledger_version":"41681283","ledger_timestamp":"1791836552383680"}"#
        ))
        let info = try await client(stub).ledgerInfo()
        #expect(info.chainId == 2)
        #expect(info.ledgerVersion == 41_681_283)
        #expect(info.ledgerTimestamp == 1_791_836_552_383_680)
        #expect(stub.capturedRequest?.url?.path == "/v1")
    }

    @Test func simulationDecodesResultsWithoutAType() async throws {
        // swiftlint:disable:next line_length
        let body = #"[{"hash":"0x1","gas_used":"5414","gas_unit_price":"100","success":true,"vm_status":"Executed successfully"}]"#
        let stub = StubURLProtocol.makeSession(response: json(body))

        let simulation = try await client(stub).simulate(rawTransaction: Data([1]), authenticator: Data([4, 4]))
        #expect(simulation.success && simulation.gasUsed == 5_414 && simulation.fee == 541_400)
        #expect(stub.capturedRequest?.url?.path == "/v1/transactions/simulate")
        #expect(stub.capturedBody == Data([1, 4, 4]))
    }

    @Test func broadcastPostsBcsAndReturnsTheNodeHash() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(statusCode: 202, body: Data(#"{"hash":"0xabc"}"#.utf8))
        )

        #expect(try await client(stub).broadcast(transaction: Data([1, 2]), signature: Data([3])) == "0xabc")
        #expect(stub.capturedRequest?.url?.path == "/v1/transactions")

        #expect(
            stub.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == AptosClient.signedTransactionContentType
        )

        #expect(stub.capturedBody == Data([1, 2, 3]))
    }

    @Test func duplicateSubmissionRecoversTheLocalHash() async throws {
        let body = #"{"message":"dup","error_code":"invalid_transaction_update","vm_error_code":null}"#
        let stub = StubURLProtocol.makeSession(response: .success(statusCode: 400, body: Data(body.utf8)))
        let signed = Data([1, 2, 3])

        let hash = try await client(stub).broadcast(transaction: signed.prefix(2), signature: signed.suffix(1))
        #expect(hash == AptosClient.transactionHash(of: signed))
    }

    @Test func otherRejectionsSurface() async throws {
        let body = #"{"message":"bad","error_code":"vm_error","vm_error_code":1}"#
        let stub = StubURLProtocol.makeSession(response: .success(statusCode: 400, body: Data(body.utf8)))

        await #expect(throws: AptosHTTPError.self) {
            _ = try await client(stub).broadcast(transaction: Data([1]), signature: Data([2]))
        }
    }

    @Test func allBalancesUseCanonicalAssetTypes() async throws {
        let response = """
        {"data":{"current_fungible_asset_balances":[
          {"amount":48934400,
           "asset_type":"0x1::aptos_coin::AptosCoin",
           "asset_type_v2":"0x000000000000000000000000000000000000000000000000000000000000000a"},
          {"amount":"7",
           "asset_type":"0x00000000000000000000000000000000000000000000000000000000000000bb",
           "asset_type_v2":null}
        ]}}
        """
        let stub = StubURLProtocol.makeSession(response: json(response))
        let balances = try await client(stub).getAllBalances(owner)

        #expect(balances == [
            AptosClient.nativeCoinType: BigUInt(48_934_400),
            "0x" + String(repeating: "0", count: 62) + "bb": BigUInt(7)
        ])
        #expect(stub.capturedRequest?.url?.path == "/v1/graphql")
    }

    @Test func indexerErrorsSurface() async throws {
        let stub = StubURLProtocol.makeSession(response: json(#"{"errors":[{"message":"not a valid graphql query"}]}"#))

        await #expect(throws: BlockchainClientError.rpcError(code: 0, message: "not a valid graphql query")) {
            _ = try await client(stub).getAllBalances(owner)
        }
    }

    @Test func headIsTheSlowestHistoryProcessor() async throws {
        let response = """
        {"data":{"processor_status":[
          {"processor":"fungible_asset_processor","last_success_version":41744815},
          {"processor":"account_transactions_processor","last_success_version":41744844}
        ]}}
        """
        let stub = StubURLProtocol.makeSession(response: json(response))
        #expect(try await client(stub).indexedHead() == 41_744_815)
    }

    @Test func missingProcessorFailsTheHead() async throws {
        // swiftlint:disable:next line_length
        let response = #"{"data":{"processor_status":[{"processor":"fungible_asset_processor","last_success_version":5}]}}"#
        let stub = StubURLProtocol.makeSession(response: json(response))
        await #expect(throws: BlockchainClientError.self) { _ = try await client(stub).indexedHead() }
    }

    @Test func historyNetsActivitiesPerAsset() throws {
        let activities = """
        [
          {"transaction_version":2,"event_index":-1,"amount":1065600,"asset_type":"0x1::aptos_coin::AptosCoin",
           "type":"0x1::aptos_coin::GasFeeEvent","is_gas_fee":true,"storage_refund_amount":600},
          {"transaction_version":2,"event_index":0,"amount":50000000,
           "asset_type":"0x000000000000000000000000000000000000000000000000000000000000000a",
           "type":"0x1::fungible_asset::Withdraw","is_gas_fee":false,"storage_refund_amount":0},
          {"transaction_version":2,"event_index":1,"amount":9,"asset_type":"0xcc",
           "type":"0x1::fungible_asset::Deposit","is_gas_fee":false,"storage_refund_amount":0},
          {"transaction_version":2,"event_index":2,"amount":1,"asset_type":"0xcc",
           "type":"0x1::fungible_asset::Frozen","is_gas_fee":false,"storage_refund_amount":0}
        ]
        """
        let decoded = try JSONDecoder().decode([AptosActivity].self, from: Data(activities.utf8))
        let fungibleAsset = "0x" + String(repeating: "0", count: 62) + "cc"
        let status = AptosTransactionStatus(
            entryFunction: "0x1::aptos_account::transfer_coins", gasUnitPrice: 100, gasUsed: 5_000, hash: "0x58f7", isPending: false, sender: "0xbd8c", success: false,
            timestamp: 1_791_836_552_383_680, version: 2, vmStatus: "Move abort"
        )

        let transaction = AptosClient.normalise(
            status, version: 2, owner: owner, activities: decoded, pairs: [fungibleAsset: "0x1::usdc::USDC"]
        )

        #expect(transaction.identifier == "0x58f7")
        #expect(transaction.blockHeight == 2)
        #expect(transaction.fee == "500000")
        #expect(transaction.method == "Transfer Coins")
        #expect(transaction.status == .reverted)
        #expect(transaction.sender == "0x" + String(repeating: "0", count: 60) + "bd8c")
        #expect(transaction.effects.map(\.assetIdentifier) == [nil, "0x1::usdc::USDC"])
        #expect(transaction.effects.map(\.kind) == [.nativeTransfer, .tokenTransfer])
        #expect(transaction.effects.map(\.amount) == ["-51065000", "9"])
        #expect(transaction.effects.allSatisfy { $0.to == owner.string })
    }

    @Test func historyIsIndexerGated() {
        let noIndexer = AptosClient(endpoint: endpoint, indexerURL: nil, apiKey: nil)
        #expect(!noIndexer.isSupported(.transactionHistory))
        #expect(!noIndexer.isSupported(.allBalances))
        #expect(!noIndexer.isSupported(.transactionSubscription))
        #expect(
            AptosClient(endpoint: endpoint, indexerURL: AptosNetwork.testnet.indexerURL, apiKey: nil)
                    .isSupported(.transactionHistory)
        )
    }

    @Test func nativeAssetFormsAreRecognised() {
        #expect(AptosClient.isNativeAsset("0x1::aptos_coin::AptosCoin"))
        #expect(AptosClient.isNativeAsset("0xa"))
        #expect(AptosClient.isNativeAsset("0x" + String(repeating: "0", count: 63) + "a"))
        #expect(!AptosClient.isNativeAsset("0xb"))
        #expect(!AptosClient.isNativeAsset("0x1::usdc::USDC"))
    }

    @Test func builderRoutesTokensToTheRightEntryFunction() throws {
        let recipient = owner

        #expect(try AptosTransactionBuilder.payload(recipient: recipient, amount: 1, token: nil).identifier
                    == "0x1::aptos_account::transfer")
        #expect(try AptosTransactionBuilder.payload(recipient: recipient, amount: 1, token: "0xa").identifier
                    == "0x1::aptos_account::transfer")
        #expect(
            try AptosTransactionBuilder.payload(
                recipient: recipient,
                amount: 1,
                token: "0x1::usdc::USDC"
            ).identifier == "0x1::aptos_account::transfer_coins"
        )

        #expect(
            try AptosTransactionBuilder.payload(
                recipient: recipient,
                amount: 1,
                token: "0xbb"
            ).identifier == "0x1::primary_fungible_store::transfer"
        )
        
        #expect(throws: BlockchainTransactionBuilderError.self) {
            try AptosTransactionBuilder.payload(recipient: recipient, amount: 1, token: "nope")
        }
    }

    @Test func derivationPathsFollowTheAptosSdk() throws {
        #expect(try DerivationPath(.aptos(.mainnet), accountIndex: 3, curve: .ed25519).string == "m/44'/637'/3'/0'/0'")
        #expect(try DerivationPath(.aptos(.mainnet), accountIndex: 3, curve: .secp256k1).string == "m/44'/637'/3'/0/0")
        #expect(throws: WalletKitError.self) { try DerivationPath(.aptos(.mainnet), accountIndex: 0) }
    }

    @Test func strictAndChainAddressParsing() throws {
        let stripped = "0x6d678a7c9c2eed7f20391459d1aec5d7f532710e6455f145bf2dc790b9d2c02"
        #expect(throws: WalletKitError.self) { try AptosAddress(string: stripped) }
        #expect(try AptosAddress(chainString: stripped).longString == "0x0" + stripped.dropFirst(2))
        #expect(try AptosAddress(string: "0x1").string == "0x1")
    }
}
