import BigInt
import Foundation
import Testing
import WalletKitRust
@testable import WalletKit

struct CardanoStakingTests {
    private let endpoint = URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!
    private let entropy = Data(repeating: 0, count: 16)
    private let epoch = Data(#"{"epoch":512,"end_time":1900000000}"#.utf8)

    @Test func neverUsedStakeAddressIsUnregisteredWithNoRewards() async throws {
        let owner = try descriptor()
        let read = try await client(owner, [
            "accounts/\(owner.stakeAddress)": .success(statusCode: 404, body: Data("{}".utf8))
        ]).stakingRead(owner)

        #expect(!read.registered)
        #expect(read.withdrawable == 0)
        #expect(read.poolId == nil)
        #expect(read.epoch.epoch == 512)
    }

    @Test func registrationIsNotDelegation() async throws {
        let owner = try descriptor()
        let account = #"""
        {"active":false,"registered":true,"controlled_amount":"5000000","rewards_sum":"0",
         "withdrawable_amount":"0","pool_id":null,"drep_id":null}
        """#
        let read = try await client(owner, [
            "accounts/\(owner.stakeAddress)": ok(account),
            "accounts/\(owner.stakeAddress)/registrations": ok(#"[{"action":"registered","deposit":"2000000"}]"#),
            "accounts/\(owner.stakeAddress)/rewards": ok("[]")
        ]).stakingRead(owner)

        #expect(read.registered)
        #expect(read.poolId == nil)
        #expect(read.refundDeposit == 2_000_000)
        #expect(read.controlled == 5_000_000)
        #expect(read.latestReward == nil)
    }

    @Test func refundIsTheLatestRegistrationsDepositAndNeverAFallback() async throws {
        let owner = try descriptor()
        let account = #"""
        {"active":true,"registered":true,"controlled_amount":"1","rewards_sum":"9","withdrawable_amount":"7",
         "pool_id":"pool1x","drep_id":"drep_always_abstain"}
        """#
        let missing = try await client(owner, [
            "accounts/\(owner.stakeAddress)": ok(account),
            "accounts/\(owner.stakeAddress)/registrations": .success(statusCode: 500, body: Data("{}".utf8)),
            "accounts/\(owner.stakeAddress)/rewards": ok(#"[{"epoch":510,"amount":"123","type":"member"}]"#)
        ]).stakingRead(owner)

        #expect(missing.refundDeposit == nil)
        #expect(missing.drep == .abstain)
        #expect(missing.latestReward == CardanoReward(amount: 123, epoch: 510))
        #expect(throws: CardanoStakingError.missingRefund) {
            try CardanoClient.parts(of: .stopStaking, read: missing, keyDeposit: 2_000_000)
        }
    }

    @Test func actionsMapToSeparateCertificates() throws {
        let unregistered = read(registered: false)
        let registered = read(registered: true, refund: 2_000_000, withdrawable: 5)

        let stake = try CardanoClient.parts(
            of: .stake(pool: "pool1x", drep: .noConfidence),
            read: unregistered,
            keyDeposit: 2
        )
        #expect(stake.certificates.count == 3)
        #expect(stake.withdrawal == nil)

        let sweep = try CardanoClient.parts(of: .stopStaking, read: registered, keyDeposit: 2)
        #expect(sweep.certificates.count == 1)
        #expect(sweep.withdrawal == 5)

        let withdraw = try CardanoClient.parts(of: .withdraw, read: registered, keyDeposit: 2)
        #expect(withdraw.certificates.isEmpty)
        #expect(withdraw.withdrawal == 5)

        #expect(throws: CardanoStakingError.unregistered) {
            try CardanoClient.parts(of: .changePool("pool1x"), read: unregistered, keyDeposit: 2)
        }
    }

    @Test func withdrawalsNeedADRepFirst() {
        let withoutDRep = read(registered: true, refund: 2, withdrawable: 5)
        let withDRep = read(registered: true, refund: 2, withdrawable: 5, drep: .abstain)
        let noRewards = read(registered: true, refund: 2, withdrawable: 0)

        #expect(CardanoClient.needsDRep(.withdraw, read: withoutDRep))
        #expect(CardanoClient.needsDRep(.stopStaking, read: withoutDRep))
        #expect(!CardanoClient.needsDRep(.withdraw, read: withDRep))
        #expect(!CardanoClient.needsDRep(.stopStaking, read: noRewards))
    }

    @Test func submissionIsResolvedOnceTheTransactionExists() async throws {
        let owner = try descriptor()
        let state = try await client(owner, ["txs/abc": ok(#"{"hash":"abc"}"#)]).submissionState(hash: "abc", ttl: 100)

        #expect(state == .confirmed)
    }

    @Test func submissionExpiresOnlyWhenADeepBlockIsPastTheTTL() async throws {
        let owner = try descriptor()
        let notFound: StubURLProtocol.StubResponse = .success(statusCode: 404, body: Data("{}".utf8))
        let tip = ok(#"{"height":1000,"slot":50000}"#)
        let pastTTL = ok(#"{"height":985,"slot":49985}"#)
        let beforeTTL = ok(#"{"height":985,"slot":49985}"#)

        let expired = try await client(owner, ["txs/abc": notFound, "blocks/latest": tip, "blocks/985": pastTTL])
            .submissionState(hash: "abc", ttl: 49_000)
        let pending = try await client(owner, ["txs/abc": notFound, "blocks/latest": tip, "blocks/985": beforeTTL])
            .submissionState(hash: "abc", ttl: 60_000)

        #expect(expired == .expired)
        #expect(pending == .pending)
    }

    @Test func aCompetingSpendEndsASubmissionBeforeItsTTL() async throws {
        let owner = try descriptor()
        let notFound: StubURLProtocol.StubResponse = .success(statusCode: 404, body: Data("{}".utf8))
        let producer = String(repeating: "07", count: 32)
        let input = CardanoSpentInput(outputIndex: 0, txHash: producer)
        let consumed = { (by: String) in
            self.ok(#"{"outputs":[{"output_index":0,"consumed_by_tx":"\#(by)"}]}"#)
        }

        let conflicted = try await client(owner, [
            "txs/abc": notFound,
            "txs/\(producer)/utxos": consumed("def")
        ]).submissionState(CardanoPendingSubmission(hash: "abc", inputs: [input], ttl: 9_999_999))

        // Nothing consuming it yet: still pending (a shallow tip can't prove expiry).
        let open = try await client(owner, [
            "txs/abc": notFound,
            "txs/\(producer)/utxos": ok(#"{"outputs":[{"output_index":0,"consumed_by_tx":null}]}"#),
            "blocks/latest": ok(#"{"height":3,"slot":10}"#)
        ]).submissionState(CardanoPendingSubmission(hash: "abc", inputs: [input], ttl: 9_999_999))

        #expect(conflicted == .expired)
        #expect(open == .pending)
    }

    @Test func aFailingConflictLookupDoesNotHideTTLExpiry() async throws {
        let owner = try descriptor()
        let notFound: StubURLProtocol.StubResponse = .success(statusCode: 404, body: Data("{}".utf8))
        let producer = String(repeating: "07", count: 32)
        let pending = CardanoPendingSubmission(
            hash: "abc",
            inputs: [CardanoSpentInput(outputIndex: 0, txHash: producer)],
            ttl: 100
        )

        let state = try await client(owner, [
            "txs/abc": notFound,
            "txs/\(producer)/utxos": .success(statusCode: 500, body: Data("{}".utf8)),
            "blocks/latest": ok(#"{"height":1000,"slot":50000}"#),
            "blocks/985": ok(#"{"height":985,"slot":49985}"#)
        ]).submissionState(pending)

        #expect(state == .expired)
    }

    @Test func submissionsStoredWithoutInputsStillDecode() throws {
        let old = Data(#"{"hash":"abc","ttl":5}"#.utf8)

        #expect(try JSONDecoder().decode(CardanoPendingSubmission.self, from: old).inputs.isEmpty)
    }

    @Test func historyLabelsComeFromDecodedCertificates() throws {
        #expect(
            CardanoStakingLabel.method(kinds: ["StakeRegistration", "StakeDelegation"], hasWithdrawal: false) == "Stake"
        )
        #expect(CardanoStakingLabel.method(kinds: ["StakeDelegation"], hasWithdrawal: false) == "Delegate")
        #expect(CardanoStakingLabel.method(kinds: ["VoteDelegation"], hasWithdrawal: false) == "Vote Delegation")
        #expect(
            CardanoStakingLabel.method(kinds: ["StakeDelegation", "VoteDelegation"], hasWithdrawal: false)
                == "Delegate + Vote Delegation"
        )
        #expect(CardanoStakingLabel.method(kinds: [], hasWithdrawal: true) == "Withdraw Rewards")
        #expect(CardanoStakingLabel.method(kinds: ["StakeDeregistration"], hasWithdrawal: true) == "Stop Staking")
        #expect(CardanoStakingLabel.method(kinds: [], hasWithdrawal: false) == nil)
    }

    @Test func voteOnlyTransactionIsLabelledFromItsCBOR() async throws {
        let owner = try descriptor()
        let built = try cardanoBuildStaking(
            certificates: [.voteDelegation(drep: .abstain)],
            changeAddress: owner.receiveAddress.string,
            protocolParameters: parameters,
            stakeAddress: owner.stakeAddress,
            ttl: 1_000,
            utxos: [utxo(owner)],
            withdrawal: nil
        )

        guard case let .built(transaction) = built else {
            Issue.record("expected a built transaction")
            return
        }

        let cbor = try cardanoUnsignedTransaction(transactionBody: transaction.unsigned.transactionBody)
        let hex = cbor.map { String(format: "%02x", $0) }.joined()
        let stubbed = client(owner, ["txs/abc/cbor": ok(#"{"cbor":"\#(hex)"}"#)])
        let other = try CardanoAccountDescriptor(
            entropy: Data(repeating: 1, count: 16),
            network: .preprod,
            path: .cardanoAccount(accountIndex: 0)
        )

        #expect(await stubbed.stakingMethod(txHash: "abc", owner: owner) == "Vote Delegation")
        // The same transaction says nothing about another account's stake key.
        #expect(await stubbed.stakingMethod(txHash: "abc", owner: other) == nil)
    }

    @Test func poolsDropRetiringAndRetiredAndRankUnsaturatedFirst() async throws {
        let owner = try descriptor()
        let pools = #"""
        [{"pool_id":"pool1a","fixed_cost":"340000000","live_saturation":1.4,"margin_cost":0.01,
          "metadata":{"ticker":"AAA","name":"A"}},
         {"pool_id":"pool1b","fixed_cost":"170000000","live_saturation":0.5,"margin_cost":0.02,
          "metadata":{"ticker":"BBB","name":"B"}},
         {"pool_id":"pool1c","fixed_cost":"0","live_saturation":0.4,"margin_cost":0,"metadata":null}]
        """#
        let result = try await client(owner, [
            "pools/extended": ok(pools),
            "pools/retiring": ok(#"[{"pool_id":"pool1c","epoch":1}]"#),
            "pools/retired": ok("[]")
        ], endpoint: URL(string: "https://pools.test/api/v0")!).pools(forceRefresh: true)

        #expect(result.map(\.poolId) == ["pool1b", "pool1a"])
        #expect(result.first?.fixedCost == 170_000_000)
    }

    @Test func drepNameComesFromCIP119Metadata() {
        #expect(CardanoClient.givenName(["json_metadata": ["body": ["givenName": "Alice"]]]) == "Alice")
        #expect(CardanoClient.givenName(["json_metadata": ["body": ["givenName": ["@value": "Bob"]]]]) == "Bob")
        #expect(CardanoClient.givenName(["json_metadata": NSNull()]) == nil)
    }

    // MARK: - Helpers

    private var parameters: CardanoProtocolParametersFfi {
        CardanoProtocolParametersFfi(
            coinsPerUtxoByte: 4_310,
            keyDeposit: 2_000_000,
            maxTxSize: 16_384,
            maxValueSize: 5_000,
            minFeeA: 44,
            minFeeB: 155_381,
            poolDeposit: 500_000_000
        )
    }

    private func utxo(_ owner: CardanoAccountDescriptor) -> CardanoUtxoFfi {
        CardanoUtxoFfi(
            address: owner.receiveAddress.string,
            assets: [],
            lovelace: "5000000",
            outputIndex: 0,
            txHash: Data(repeating: 7, count: 32)
        )
    }

    private func read(
        registered: Bool,
        refund: UInt64? = nil,
        withdrawable: BigUInt = 0,
        drep: CardanoDRep? = nil
    ) -> CardanoStakingRead {
        CardanoStakingRead(
            controlled: 0,
            drep: drep,
            epoch: CardanoEpochTiming(endTime: Date(), epoch: 1),
            latestReward: nil,
            poolId: nil,
            refundDeposit: refund,
            registered: registered,
            rewardsSum: 0,
            withdrawable: withdrawable
        )
    }

    private func ok(_ json: String) -> StubURLProtocol.StubResponse {
        .success(body: Data(json.utf8))
    }

    private func client(
        _ owner: CardanoAccountDescriptor,
        _ responses: [String: StubURLProtocol.StubResponse],
        endpoint override: URL? = nil
    ) -> CardanoClient {
        var byPath = [String: StubURLProtocol.StubResponse]()

        for (path, response) in responses {
            byPath["/api/v0/\(path)"] = response
        }

        byPath["/api/v0/epochs/latest"] = .success(body: epoch)
        let stub = StubURLProtocol.makeSession(responsesByPath: byPath)
        return CardanoClient(endpoint: override ?? endpoint, projectId: "project-id", session: stub.urlSession)
    }

    private func descriptor() throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: entropy, network: .preprod, path: .cardanoAccount(accountIndex: 0))
    }
}
