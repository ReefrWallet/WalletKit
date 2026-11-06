// Native staking against a real `solana-test-validator` with 32-slot epochs: the on-chain proof
// that the instructions, seeds, activation port and authority rules match the Stake program.
// The firmware's fixtures only check display, so they can't show this.
//
// See SolanaLocalnetTests for why these need `make solana-testing` and skip in CI.

import BigInt
import Foundation
import Testing
@testable import WalletKit
import WalletKitTesting

private let oneSol: UInt64 = 1_000_000_000

private func makeSigner() throws -> SolanaPKeySigner {
    let seed = Mnemonic.generate().toSeed()
    let path = TestAccountFactory.slip10Path(coinType: 501)
    let privateKey = try seed.masterKey(curve: .ed25519).derive(path).privateKey()
    return try SolanaPKeySigner(network: .devnet, privateKey: privateKey, derivationPath: path)
}

private func read(_ client: SolanaRPCClient, _ owner: SolanaAddress) async throws -> [SolanaStakePosition] {
    try await client.stakingRead(owner: owner, known: []).positions
}

/// Polls until `condition` holds of the owner's positions, across epochs.
private func waitFor(
    _ client: SolanaRPCClient,
    _ owner: SolanaAddress,
    _ condition: ([SolanaStakePosition]) -> Bool
) async throws -> [SolanaStakePosition] {
    for _ in 0..<120 {
        let positions = try await read(client, owner)

        if condition(positions) {
            return positions
        }

        try await Task.sleep(for: .seconds(1))
    }

    throw SolanaLaunchError(description: "stake accounts never reached the expected state")
}

/// With short epochs, reward payout (when the program refuses stake changes) comes around often.
/// `action` runs on every attempt, so a withdrawal can take the balance after any payout.
private func prepareOutsideRewards(
    client: SolanaRPCClient,
    owner: SolanaAddress,
    action: () async throws -> SolanaStakingAction
) async throws -> SolanaPreparedStaking {
    for _ in 0..<60 {
        do {
            return try await client.prepareStaking(try await action(), owner: owner)
        } catch SolanaStakingBuildError.epochRewardsActive {
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    throw SolanaStakingBuildError.epochRewardsActive
}

private func send(
    _ prepared: SolanaPreparedStaking,
    client: SolanaRPCClient,
    node: SolanaNode,
    signer: SolanaPKeySigner
) async throws {
    let signature = try await signer.sign(transaction: prepared.unsigned)
    let identifier = try await client.broadcast(transaction: prepared.unsigned, signature: signature)

    #expect(identifier == SolanaRPCClient.signatureString(signature))

    try await node.waitForConfirmation(signature: identifier)
    #expect(try await client.signatureStatus(identifier, searchHistory: true) == .confirmed)
}

private func submit(
    _ action: SolanaStakingAction,
    client: SolanaRPCClient,
    node: SolanaNode,
    signer: SolanaPKeySigner
) async throws {
    let prepared = try await prepareOutsideRewards(client: client, owner: try signer.address()) { action }
    try await send(prepared, client: client, node: node, signer: signer)
}

/// Creates a stake account funded by `signer` with its own authorities and lockup, via raw
/// instructions, since the app itself only ever creates accounts it fully controls.
private func createForeign(
    seed: String,
    staker: SolanaAddress,
    withdrawer: SolanaAddress,
    lockupTimestamp: Int64 = 0,
    delegateTo voter: SolanaAddress?,
    client: SolanaRPCClient,
    node: SolanaNode,
    signer: SolanaPKeySigner
) async throws -> SolanaAddress {
    let owner = try signer.address()
    let address = try SolanaAddress.createWithSeed(base: owner, seed: seed, owner: SolanaProgram.stake)
    let rent = try await client.stakeAccountRent()

    var data = withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) }
    data += staker.rawBytes + withdrawer.rawBytes
    data += withUnsafeBytes(of: lockupTimestamp.littleEndian) { Data($0) }
    data += Data(count: 8)
    data += SolanaProgram.system.rawBytes

    var instructions = [
        SystemProgram.createAccountWithSeed(
            funder: owner,
            created: address,
            seed: seed,
            lamports: 2 * oneSol + rent,
            space: StakeProgram.accountSize,
            owner: SolanaProgram.stake
        ),
        SolanaInstruction(
            programId: SolanaProgram.stake,
            accounts: [
                SolanaAccountMeta(address: address, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: SolanaProgram.sysvarRent, isSigner: false, isWritable: false)
            ],
            data: data
        )
    ]

    if let voter {
        instructions.append(StakeProgram.delegate(stake: address, voter: voter, staker: owner))
    }

    let blockhash = try await client.latestBlockhash().blockhash
    let message = try SolanaMessage.compile(payer: owner, instructions: instructions, recentBlockhash: blockhash)
    let envelope = try JSONEncoder().encode(SolanaUnsignedTransaction(message: message.serialize()))
    let signature = try await signer.sign(transaction: envelope)
    let identifier = try await client.broadcast(transaction: envelope, signature: signature)

    try await node.waitForConfirmation(signature: identifier)
    return address
}

/// Withdraws every stake account of `signer`, checking the balance rose by what they held, less the fee.
private func withdrawAll(client: SolanaRPCClient, node: SolanaNode, signer: SolanaPKeySigner) async throws {
    let owner = try signer.address()
    let before = try await client.getNativeBalance(owner)
    var withdrawn: UInt64 = 0

    // Fresh amounts, as the app takes them: a reward paid since would leave less than rent.
    let prepared = try await prepareOutsideRewards(client: client, owner: owner) {
        let live = try await read(client, owner)
        withdrawn = live.map(\.account.lamports).reduce(0, +)

        return .withdraw(live.map { .init(address: $0.account.address, lamports: $0.account.lamports) })
    }

    try await send(prepared, client: client, node: node, signer: signer)

    let after = try await client.getNativeBalance(owner)

    #expect(after > before)
    #expect(after <= before + BigUInt(withdrawn))
    #expect(try await read(client, owner).isEmpty)
}

@Suite(.timeLimit(.minutes(5)), .serialized, .localNode)
struct SolanaStakingLocalnetTests {
    @Test func stakeThenPartialThenFullUnstakeThenWithdraw() async throws {
        let node = try await SolanaNode.start(slotsPerEpoch: 32)
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let signer = try makeSigner()
        let owner = try signer.address()

        _ = try await node.airdrop(to: owner, lamports: 20 * oneSol)

        let voter = try #require(try await client.validators().first).voteAddress

        // Stake: the seed address is the one the app predicts.
        try await submit(.stake(lamports: 5 * oneSol, voter: voter), client: client, node: node, signer: signer)

        let first = try SolanaAddress.createWithSeed(base: owner, seed: "stake:0", owner: SolanaProgram.stake)
        let staked = try await read(client, owner)

        #expect(staked.map(\.account.address) == [first.string])
        #expect(staked.first?.account.delegation?.stake == 5 * oneSol)
        #expect(staked.first?.account.delegation?.voter == voter)
        #expect(try await client.nextStakeSeed(owner: owner).seed == "stake:1")

        // The local activation calculation reaches what the program then enforces.
        let active = try await waitFor(client, owner) { $0.first?.status == .active }
        #expect(active.first?.canUnstake(owner: owner.string) == true)

        // Partial: a new account holding the split, cooling; the rest keeps earning.
        try await submit(
            .unstakePartial(account: first.string, lamports: 2 * oneSol),
            client: client,
            node: node,
            signer: signer
        )

        let split = try await read(client, owner)
        let remainder = try #require(split.first { $0.account.address == first.string })
        let child = try #require(split.first { $0.account.address != first.string })

        #expect(split.count == 2)
        #expect(remainder.account.delegation?.stake == 3 * oneSol)
        #expect(remainder.status == .active)
        #expect(child.account.delegation?.stake == 2 * oneSol)
        #expect(child.status == .deactivating)

        // Full: both can be unstaked or withdrawn in one all-deactivate / all-withdraw transaction.
        try await submit(.unstake(accounts: [first.string]), client: client, node: node, signer: signer)

        let cooling = try await waitFor(client, owner) { positions in
            positions.count == 2 && positions.allSatisfy { $0.status == .inactive }
        }

        #expect(cooling.allSatisfy { $0.canWithdraw(owner: owner.string, at: SolanaClock(
            epoch: 0, epochStartTimestamp: 0, slot: 0, unixTimestamp: Int64.max
        )) })

        try await withdrawAll(client: client, node: node, signer: signer)

        // History names each action by its stake instruction.
        let methods = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        ).transactions.compactMap(\.method)

        #expect(methods.contains("SOL: Delegate"))
        #expect(methods.contains("SOL: Deactivate"))
        #expect(methods.contains("SOL: Withdraw"))
    }

    @Test func onlyEachActionsOwnAuthorityWorks() async throws {
        let node = try await SolanaNode.start(slotsPerEpoch: 32)
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let signer = try makeSigner()
        let other = try makeSigner().address()
        let owner = try signer.address()

        _ = try await node.airdrop(to: owner, lamports: 20 * oneSol)

        let voter = try SolanaAddress(string: try #require(try await client.validators().first).voteAddress)

        // This wallet stakes but another withdraws: deactivating works, withdrawing doesn't.
        let foreignWithdrawer = try await createForeign(
            seed: "other:0",
            staker: owner,
            withdrawer: other,
            delegateTo: voter,
            client: client,
            node: node,
            signer: signer
        )

        // Another wallet stakes but this one withdraws, with nothing delegated: withdrawing works.
        let foreignStaker = try await createForeign(
            seed: "other:1",
            staker: other,
            withdrawer: owner,
            delegateTo: nil,
            client: client,
            node: node,
            signer: signer
        )

        let positions = try await read(client, owner)
        let clock = try await client.stakingRead(owner: owner, known: []).clock

        let withdrawerElsewhere = try #require(positions.first { $0.account.address == foreignWithdrawer.string })
        let stakerElsewhere = try #require(positions.first { $0.account.address == foreignStaker.string })

        #expect(positions.count == 2)
        #expect(withdrawerElsewhere.canUnstake(owner: owner.string))
        #expect(!withdrawerElsewhere.canWithdraw(owner: owner.string, at: clock))
        #expect(stakerElsewhere.status == .undelegated)
        #expect(stakerElsewhere.canWithdraw(owner: owner.string, at: clock))

        try await submit(.unstake(accounts: [foreignWithdrawer.string]), client: client, node: node, signer: signer)

        try await submit(
            .withdraw([.init(address: foreignStaker.string, lamports: stakerElsewhere.account.lamports)]),
            client: client,
            node: node,
            signer: signer
        )

        // The program refuses what the app also refuses: simulation catches it before any send.
        await #expect(throws: SolanaStakingBuildError.self) {
            try await client.prepareStaking(
                .withdraw([.init(address: foreignWithdrawer.string, lamports: 1)]),
                owner: owner
            )
        }
    }

    @Test func lockupBlocksWithdrawalNotUnstaking() async throws {
        let node = try await SolanaNode.start(slotsPerEpoch: 32)
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let signer = try makeSigner()
        let owner = try signer.address()

        _ = try await node.airdrop(to: owner, lamports: 20 * oneSol)

        let voter = try SolanaAddress(string: try #require(try await client.validators().first).voteAddress)

        let locked = try await createForeign(
            seed: "locked:0",
            staker: owner,
            withdrawer: owner,
            lockupTimestamp: Int64(Date().timeIntervalSince1970) + 86_400 * 365,
            delegateTo: voter,
            client: client,
            node: node,
            signer: signer
        )

        let read = try await client.stakingRead(owner: owner, known: [])
        let position = try #require(read.positions.first)

        #expect(position.account.isLocked(at: read.clock))
        #expect(position.canUnstake(owner: owner.string))

        try await submit(.unstake(accounts: [locked.string]), client: client, node: node, signer: signer)

        let cooled = try await waitFor(client, owner) { $0.first?.status == .inactive }
        let latest = try await client.stakingRead(owner: owner, known: [])

        #expect(cooled.first?.canWithdraw(owner: owner.string, at: latest.clock) == false)

        await #expect(throws: SolanaStakingBuildError.self) {
            try await client.prepareStaking(
                .withdraw([.init(address: locked.string, lamports: cooled.first?.account.lamports ?? 0)]),
                owner: owner
            )
        }
    }

    /// Validators and rewards through a real node, and the expiry walk over a real chain.
    @Test func expiryWalksARealChain() async throws {
        let node = try await SolanaNode.start(slotsPerEpoch: 32)
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let signer = try makeSigner()
        let owner = try signer.address()

        _ = try await node.airdrop(to: owner, lamports: 2 * oneSol)

        let prepared = try await client.prepareStaking(
            .unstake(accounts: []),
            owner: owner
        )

        // Never broadcast, with a validity window short enough to pass quickly.
        let pending = SolanaPendingSubmission(
            action: prepared.action,
            lastValidBlockHeight: try await client.blockHeight(commitment: .confirmed) + 3,
            recentBlockhash: prepared.recentBlockhash,
            signature: SolanaRPCClient.signatureString(Data(repeating: 7, count: 64)),
            slotAtBuild: prepared.slotAtBuild
        )

        var update = await client.reconcile(pending)
        var current = pending

        for _ in 0..<120 {
            if case let .unresolved(progress) = update {
                current = progress
                try await Task.sleep(for: .seconds(1))
                update = await client.reconcile(current)
            } else {
                break
            }
        }

        #expect(update == .expired)
    }
}
