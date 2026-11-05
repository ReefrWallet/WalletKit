import BigInt
import Foundation
import Testing
@testable import WalletKit

struct TronClientStakingTests {
    private let endpoint = URL(string: "https://example.com")!
    // swiftlint:disable:next force_try
    private let owner = try! TronAddress(string: TronRawTransactionTests.owner)

    private static let account = #"""
    {"address":"TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC","balance":938295311,
     "frozenV2":[{"amount":130000000},{"type":"ENERGY","amount":240000000},{"type":"TRON_POWER"}],
     "unfrozenV2":[{"type":"ENERGY","unfreeze_amount":100000000,"unfreeze_expire_time":1763000000000},
                   {"unfreeze_amount":30000000,"unfreeze_expire_time":1762000000000}],
     "votes":[{"vote_address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","vote_count":250}]}
    """#

    private static let resources = #"""
    {"freeNetLimit":600,"freeNetUsed":100,"NetLimit":210,"NetUsed":0,"EnergyLimit":2316,"EnergyUsed":926,
     "TotalNetLimit":43200000000,"TotalNetWeight":9000000000,"TotalEnergyLimit":180000000000,"TotalEnergyWeight":10000000000}
    """#

    @Test func stakingStateReadsStakeUnstakesVotesAndAllowances() async throws {
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/wallet/getaccount": .success(body: Data(Self.account.utf8)),
            "/wallet/getaccountresource": .success(body: Data(Self.resources.utf8)),
            "/wallet/getReward": .success(body: Data(#"{"reward":685004}"#.utf8)),
            "/wallet/getcanwithdrawunfreezeamount": .success(body: Data(#"{"amount":30000000}"#.utf8))
        ])

        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let state = try await client.stakingState(for: owner, now: Date(timeIntervalSince1970: 1_762_500_000))

        #expect(state.frozen == [
            .init(amount: 130_000_000, resource: .bandwidth),
            .init(amount: 240_000_000, resource: .energy)
        ])
        #expect(state.totalStaked == 370_000_000)
        #expect(state.votePower == 370)
        #expect(state.assignedVotes == 250)
        #expect(state.rewards == 685_004)
        #expect(state.withdrawable == 30_000_000)
        #expect(state.unfrozen.map(\.amount) == [100_000_000, 30_000_000])
        #expect(state.unfrozen.map(\.resource) == [.energy, .bandwidth])
        // Free and staked bandwidth, less what's used.
        #expect(state.bandwidth == .init(limit: 810, remaining: 710))
        #expect(state.energy == .init(limit: 2_316, remaining: 1_390))
    }

    /// Delegated-out stake leaves `frozenV2` but its voting rights stay with the owner.
    @Test func votePowerIncludesStakeDelegatedToOthers() throws {
        let account = #"""
        {"frozenV2":[{"amount":100000000}],"delegated_frozenV2_balance_for_bandwidth":40000000,
         "account_resource":{"delegated_frozenV2_balance_for_energy":60000000}}
        """#

        let counted = try TronClient.stakingState(
            account: JSONSerialization.jsonObject(with: Data(account.utf8)) as? [String: Any] ?? [:],
            resources: [:],
            rewards: 0,
            withdrawable: 0
        )

        #expect(counted.totalStaked == 100_000_000)
        #expect(counted.delegated == 100_000_000)
        #expect(counted.votePower == 200)

        // The node's own total wins when it reports one.
        let reported = try TronClient.stakingState(
            account: JSONSerialization.jsonObject(with: Data(account.utf8)) as? [String: Any] ?? [:],
            resources: ["tronPowerLimit": 210],
            rewards: 0,
            withdrawable: 0
        )

        #expect(reported.votePower == 210)
    }

    @Test func fullyDelegatedAccountsStillHaveVotes() throws {
        let account = #"""
        {"account_resource":{"delegated_frozenV2_balance_for_energy":50000000}}
        """#

        let state = try TronClient.stakingState(
            account: JSONSerialization.jsonObject(with: Data(account.utf8)) as? [String: Any] ?? [:],
            resources: [:],
            rewards: 0,
            withdrawable: 0
        )

        #expect(state.totalStaked == 0)
        #expect(state.votePower == 50)
    }

    @Test func resourceUnitsAreTheShareOfTheNetworkLimitByWeight() throws {
        let state = try TronClient.stakingState(
            account: JSONSerialization.jsonObject(with: Data(Self.account.utf8)) as? [String: Any] ?? [:],
            resources: JSONSerialization.jsonObject(with: Data(Self.resources.utf8)) as? [String: Any] ?? [:],
            rewards: 0,
            withdrawable: 0
        )

        // 100 TRX × 180e9 energy / 10e9 TRX of weight.
        #expect(state.resourceUnits(sun: 100_000_000, resource: .energy) == 1_800)
        // 10 TRX × 43.2e9 bandwidth / 9e9 TRX of weight.
        #expect(state.resourceUnits(sun: 10_000_000, resource: .bandwidth) == 48)
        #expect(state.resourceUnits(sun: 10_000_000, resource: .tronPower) == 0)
    }

    @Test func buildsAStakeThroughFreezeBalanceV2() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(
            #"{"raw_data_hex":"\#(TronRawTransactionTests.freezeEnergyHex.lowercased())","txID":"00"}"#.utf8
        )))

        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let data = try await client.buildStakingTransaction(
            .freezeBalanceV2(owner: owner, amount: 100_000_000, resource: .energy)
        )

        let body = try requestBody(stub)
        #expect(stub.capturedRequest?.url?.path == "/wallet/freezebalancev2")
        #expect(body["owner_address"] as? String == owner.string)
        #expect(body["frozen_balance"] as? UInt64 == 100_000_000)
        #expect(body["resource"] as? String == "ENERGY")
        #expect(body["visible"] as? Bool == true)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["txID"] as? String == "00")
    }

    @Test(arguments: [
        (TronRawTransactionTests.voteHex, "/wallet/votewitnessaccount"),
        (TronRawTransactionTests.withdrawBalanceHex, "/wallet/withdrawbalance"),
        (TronRawTransactionTests.cancelAllUnfreezeHex, "/wallet/cancelallunfreezev2"),
        (TronRawTransactionTests.withdrawExpireUnfreezeHex, "/wallet/withdrawexpireunfreeze"),
        (TronRawTransactionTests.unfreezeEnergyHex, "/wallet/unfreezebalancev2")
    ])
    func routesEachContractToItsNodeEndpoint(hex: String, path: String) async throws {
        let contract = try TronRawTransaction(rawBytes: Data(hexString: hex)).contract
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(#"{"raw_data_hex":"\#(hex)"}"#.utf8)))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        _ = try await client.buildStakingTransaction(contract)

        #expect(stub.capturedRequest?.url?.path == path)
    }

    @Test func voteRequestListsEachRepresentativeWithItsCount() async throws {
        let contract = try TronRawTransaction(rawBytes: Data(hexString: TronRawTransactionTests.voteHex)).contract
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(
            #"{"raw_data_hex":"\#(TronRawTransactionTests.voteHex)"}"#.utf8
        )))

        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        _ = try await client.buildStakingTransaction(contract)

        let votes = try #require(try requestBody(stub)["votes"] as? [[String: Any]])
        #expect(votes.map { $0["vote_count"] as? UInt64 } == [250, 120])
        #expect(votes.first?["vote_address"] as? String == TronRawTransactionTests.usdt)
    }

    @Test func refusesATransactionThatIsNotWhatWasRequested() async throws {
        // The node answers a 100 TRX stake request with a 25 TRX one.
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(
            #"{"raw_data_hex":"\#(TronRawTransactionTests.freezeBandwidthHex.lowercased())"}"#.utf8
        )))

        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        await #expect(throws: WalletKitError.self) {
            _ = try await client.buildStakingTransaction(
                .freezeBalanceV2(owner: owner, amount: 100_000_000, resource: .bandwidth)
            )
        }
    }

    @Test func reportsTheNodesReasonWhenItBuildsNothing() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(#"{"Error":"balance is not sufficient"}"#.utf8)))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        await #expect(throws: WalletKitError.self) {
            _ = try await client.buildStakingTransaction(.withdrawBalance(owner: owner))
        }
    }

    @Test func rejectsContractsThatAreNotStaking() async throws {
        let client = TronClient(endpoint: endpoint)
        let transfer = TronRawTransaction.Contract.transfer(owner: owner, to: owner, amount: 1)

        await #expect(throws: WalletKitError.self) {
            _ = try await client.buildStakingTransaction(transfer)
        }
    }

    @Test func representativesComeFromTronScanWithNamesAndRewards() async throws {
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/vote/witness": .success(body: Data(#"""
            {"data":[
              {"address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","name":"Small","realTimeVotes":10,"annualizedRate":"3.25"},
              {"address":"\#(owner.string)","name":"P2P.ORG","url":"https://p2p.org","realTimeVotes":900,"annualizedRate":"3.27"}
            ]}
            """#.utf8))
        ])

        let client = TronClient(
            endpoint: endpoint,
            tronScanEndpoint: URL(string: "https://scan.example.com")!,
            session: stub.urlSession
        )

        let representatives = try await client.representatives()

        #expect(representatives.map(\.name) == ["P2P.ORG", "Small"])
        #expect(representatives.first?.apr == Decimal(string: "3.27"))
        #expect(representatives.first?.url == "https://p2p.org")
        #expect(representatives.first?.voteCount == 900)
    }

    @Test func representativesFallBackToTheNodeWhenTronScanFails() async throws {
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/vote/witness": .failure(.secureConnectionFailed),
            "/wallet/listwitnesses": .success(body: Data(#"""
            {"witnesses":[
              {"address":"41a614f803b6fd780986a42c78ec9c7f77e6ded13c","voteCount":5,"url":""},
              {"address":"\#(TronRawTransactionTests.representativeHex)","voteCount":50,"url":"https://huobi.example"}
            ]}
            """#.utf8))
        ])

        let client = TronClient(
            endpoint: endpoint,
            tronScanEndpoint: URL(string: "https://scan.example.com")!,
            session: stub.urlSession
        )

        let representatives = try await client.representatives()

        #expect(representatives.map(\.voteCount) == [50, 5])
        #expect(representatives.allSatisfy { $0.name == nil && $0.apr == nil })
        #expect(representatives.first?.url == "https://huobi.example")
        #expect(representatives.last?.url == nil)
    }

    private func requestBody(_ stub: StubURLProtocol.Session) throws -> [String: Any] {
        let body = try #require(stub.capturedBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
