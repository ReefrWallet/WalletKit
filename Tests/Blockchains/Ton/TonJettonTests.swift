import BigInt
import Foundation
import Testing
@testable import WalletKit

struct TonJettonTests {
    private let owner: TonAddress
    private let master: TonAddress

    init() throws {
        owner = try TonAddress(workchain: 0, hash: Data(repeating: 0x11, count: 32))
        master = try TonAddress(workchain: 0, hash: Data(repeating: 0x22, count: 32))
    }

    private func boc(of address: TonAddress) throws -> String {
        var builder = TonCellBuilder()
        builder.storeAddress(address)
        return TonBOC.serialize(try builder.build()).base64EncodedString()
    }

    private func jettonWalletAddressResponse(_ address: TonAddress) throws -> String {
        #"{"ok":true,"result":{"exit_code":0,"stack":[["cell",{"bytes":"\#(try boc(of: address))"}]]}}"#
    }

    @Test func aTransferBodyFollowsTep74() throws {
        let body = try TonJetton.transferBody(
            queryId: 1,
            amount: 1_500_000,
            destination: TonAddress(workchain: 0, hash: Data(repeating: 0x11, count: 32)),
            responseDestination: TonAddress(workchain: 0, hash: Data(repeating: 0x22, count: 32)),
            forwardAmount: 1,
            comment: nil
        )

        // op, query_id, amount, destination, response_destination, no custom payload, forward amount, empty payload.
        let expected = "0f8a7ea50000000000000001316e3608002222222222222222222222222222222222222222222222222222222222"
            + "2222230008888888888888888888888888888888888888888888888888888888888888888202"

        #expect(body.bitCount == 672)
        #expect(body.bits.map { String(format: "%02x", $0) }.joined() == expected)
        #expect(body.refs.isEmpty)
    }

    @Test func aCommentTravelsAsTheForwardPayload() throws {
        let body = try TonJetton.transferBody(
            queryId: 1,
            amount: 1,
            destination: owner,
            responseDestination: owner,
            forwardAmount: 1,
            comment: "hi"
        )

        // The comment is inline (`0`) behind the text opcode `0`, so it adds bits and no reference.
        #expect(body.refs.isEmpty)
        #expect(body.bitCount > 600)
    }

    @Test func anAddressRoundTripsThroughItsCell() throws {
        var builder = TonCellBuilder()
        builder.storeAddress(owner)
        #expect(try TonClient.address(in: builder.build()).hash == owner.hash)
        #expect(try TonClient.address(in: builder.build()).workchain == 0)
    }

    @Test func theWalletAddressComesFromTheMastersGetter() async throws {
        let transport = FakeTonTransport()
        transport.route("runGetMethod", try jettonWalletAddressResponse(owner))
        let client = TonClient(network: .testnet, transport: transport)
        let wallet = try await client.jettonWalletAddress(owner: owner, master: master)
        #expect(wallet.hash == owner.hash)

        // The owner is passed as a slice holding its address.
        let sent = try #require(transport.requests.last?.body)
        let request = try JSONDecoder().decode(TonClient.RunGetMethodRequest.self, from: sent)
        #expect(request.method == "get_wallet_address")
        #expect(request.stack.first?.first == "tvm.Slice")
    }

    @Test func aWalletThatIsNotDeployedHasNoData() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", #"{"ok":true,"result":{"balance":"0","state":"uninitialized"}}"#)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.jettonWalletData(master, owner: owner, master: master) == nil)
    }

    @Test func aFrozenWalletIsNotReadAsEmpty() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", #"{"ok":true,"result":{"balance":"1","state":"frozen"}}"#)
        let client = TonClient(network: .testnet, transport: transport)

        // It may still hold tokens, so neither the data nor a zero balance is returned.
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.jettonWalletData(master, owner: owner, master: master)
        }

        transport.route("getAddressInformation", #"{"ok":true,"result":{"balance":"0","state":"uninitialized"}}"#)
        #expect(try await client.jettonWalletData(master, owner: owner, master: master) == nil)
    }

    @Test func aWalletReportingTheSameHashInAnotherWorkchainIsRefused() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", #"{"ok":true,"result":{"balance":"1","state":"active"}}"#)
        let otherChain = try TonAddress(workchain: -1, hash: owner.hash)
        transport.route("runGetMethod", """
        {"ok":true,"result":{"exit_code":0,"stack":[["num","0x16e360"],["cell",{"bytes":"\(try boc(of: otherChain))"}],
        ["cell",{"bytes":"\(try boc(of: master))"}]]}}
        """)

        let client = TonClient(network: .testnet, transport: transport)
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.jettonWalletData(master, owner: owner, master: master)
        }
    }

    @Test func aWalletsDataIsDecodedAndCheckedAgainstItsOwnerAndMaster() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", #"{"ok":true,"result":{"balance":"1","state":"active"}}"#)
        transport.route("runGetMethod", """
        {"ok":true,"result":{"exit_code":0,"stack":[["num","0x16e360"],["cell",{"bytes":"\(try boc(of: owner))"}],
        ["cell",{"bytes":"\(try boc(of: master))"}],["cell",{"bytes":"\(try boc(of: owner))"}]]}}
        """)

        let client = TonClient(network: .testnet, transport: transport)
        let data = try await client.jettonWalletData(master, owner: owner, master: master)
        #expect(data?.balance == 1_500_000)

        // A wallet that reports another owner is refused rather than trusted.
        let stranger = try TonAddress(workchain: 0, hash: Data(repeating: 0x33, count: 32))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.jettonWalletData(master, owner: stranger, master: master)
        }
    }
}
