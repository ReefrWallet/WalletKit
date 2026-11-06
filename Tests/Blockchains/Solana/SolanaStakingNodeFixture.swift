// A fake Solana node for the staking suites: answers JSON-RPC by method through the real
// `URLSession`/`JSONRPCClient` path, with canned sysvars and stake accounts.

import Foundation
import Testing
@testable import WalletKit

/// Answers JSON-RPC methods with canned `result` JSON, or fails them.
final class FakeSolanaNode: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable ([Any]) -> String?] = [:]
    private var calls: [String: Int] = [:]

    /// `handler` returns the `result` JSON, or `nil` to fail the call with a node error.
    func on(_ method: String, _ handler: @escaping @Sendable ([Any]) -> String?) {
        lock.withLock { handlers[method] = handler }
    }

    func on(_ method: String, result: String) {
        on(method) { _ in result }
    }

    func count(_ method: String) -> Int {
        lock.withLock { calls[method] ?? 0 }
    }

    func client(validatorIndex: URL? = nil) -> SolanaRPCClient {
        let stub = StubURLProtocol.makeSession { [self] body in response(to: body) }

        return SolanaRPCClient(
            // One endpoint per node: the cluster info cache is keyed by it.
            endpoint: URL(string: "https://\(UUID().uuidString).example.com/rpc")!,
            session: stub.urlSession,
            validatorIndexEndpoint: validatorIndex
        )
    }

    private func response(to body: Data?) -> StubURLProtocol.StubResponse {
        guard
            let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = json["method"] as? String
        else {
            return .failure(.badURL)
        }

        let handler = lock.withLock {
            calls[method, default: 0] += 1
            return handlers[method]
        }

        guard let result = handler?(json["params"] as? [Any] ?? []) else {
            let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"refused"}}"#
            return .success(body: Data(error.utf8))
        }

        return .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":\#(result)}"#.utf8))
    }
}

let stakingOwner = SolanaAddress.known("14CCvQzQzHCVgZM3j9soPnXuJXh1RmCfwLVUcdfbZVBS")
let stakingOtherWallet = SolanaAddress.known("ETxHeBBcuw9Yu4dGuP3oXrD12V5RECvmi8ogQ9PkjyVF")
let stakingVoter = SolanaAddress.known("ATFXMD5cYiw9yHkvexgx3nf9LNSouEViB5BZBsgwunAv")

func stakingUInt64(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

func accountJSON(_ data: Data, owner: String, lamports: UInt64 = 1_000) -> String {
    #"""
    {"data":["\#(data.base64EncodedString())","base64"],"executable":false,"lamports":\#(lamports),
     "owner":"\#(owner)","rentEpoch":0,"space":\#(data.count)}
    """#
}

func clockData(epoch: UInt64 = 100, slot: UInt64 = 43_200_100) -> Data {
    stakingUInt64(slot) + stakingUInt64(1_000) + stakingUInt64(epoch) + stakingUInt64(epoch + 1) + stakingUInt64(2_000)
}

func historyData(newest: UInt64?) -> Data {
    guard let newest else {
        return stakingUInt64(0)
    }

    return stakingUInt64(1) + stakingUInt64(newest) + stakingUInt64(1_000) + stakingUInt64(0) + stakingUInt64(0)
}

/// The `getMultipleAccounts` result for the Clock and StakeHistory sysvars.
func snapshotJSON(epoch: UInt64 = 100, newest: UInt64? = 99) -> String {
    let sysvar = "Sysvar1111111111111111111111111111111111111"
    let clock = accountJSON(clockData(epoch: epoch), owner: sysvar)
    let history = accountJSON(historyData(newest: newest), owner: sysvar)

    return #"{"context":{"slot":1},"value":[\#(clock),\#(history)]}"#
}

/// A node whose snapshot and cluster calls work, with the given stake accounts by `getProgramAccounts`.
func makeStakingNode(
    epoch: UInt64 = 100,
    newestHistory: UInt64? = 99,
    programAccounts: [(address: String, data: Data)] = []
) -> FakeSolanaNode {
    let node = FakeSolanaNode()

    let snapshot = snapshotJSON(epoch: epoch, newest: newestHistory)

    node.on("getMultipleAccounts") { params in
        let addresses = params.first as? [String] ?? []

        if addresses.first == SolanaProgram.sysvarClock.string {
            return snapshot
        }

        return #"{"context":{"slot":1},"value":[\#(addresses.map { _ in "null" }.joined(separator: ","))]}"#
    }

    node.on("getEpochSchedule", result: #"""
    {"firstNormalEpoch":0,"firstNormalSlot":0,"leaderScheduleSlotOffset":432000,"slotsPerEpoch":432000,"warmup":false}
    """#)

    node.on("getAccountInfo", result: #"{"context":{"slot":1},"value":null}"#)

    node.on("getRecentPerformanceSamples", result: #"""
    [{"numSlots":300,"numTransactions":1,"samplePeriodSecs":60,"slot":1}]
    """#)

    let entries = programAccounts.map { account in
        #"{"pubkey":"\#(account.address)","account":\#(accountJSON(account.data, owner: SolanaProgram.stake.string))}"#
    }

    node.on("getProgramAccounts", result: "[\(entries.joined(separator: ","))]")
    return node
}

func stakeData(
    withdrawer: SolanaAddress = stakingOwner,
    activation: UInt64 = 1,
    deactivation: UInt64 = .max
) -> Data {
    SolanaStakingTests.stakeAccountData(
        staker: stakingOwner,
        withdrawer: withdrawer,
        voter: stakingVoter,
        stake: 5_000,
        activation: activation,
        deactivation: deactivation
    )
}

let stakeAddress = "GEimxzEMpnvAALuhRXgPYk1LuKGJR8Zb1G7wKCwt44Kz"
