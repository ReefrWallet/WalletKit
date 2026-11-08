import BigInt
import Foundation
import Testing
@testable import WalletKit

/// Receive address listing, the index limit, and UTxO evidence of use; Blockfrost is stubbed.
struct CardanoReceiveAddressTests {
    private let endpoint = URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!
    private let path = try! DerivationPath(string: "m/1852'/1815'/0'") // swiftlint:disable:this force_try

    private func descriptor() throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: Data(repeating: 0, count: 16), network: .preprod, path: path)
    }

    private func client(_ stub: StubURLProtocol.Session) -> CardanoClient {
        CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)
    }

    private func json(_ text: String) -> StubURLProtocol.StubResponse {
        .success(body: Data(text.utf8))
    }

    private func utxo(_ address: String, lovelace: String, output: UInt32 = 0) -> String {
        """
        {"address":"\(address)","amount":[{"unit":"lovelace","quantity":"\(lovelace)"}],
         "output_index":\(output),"tx_hash":"\(String(repeating: "07", count: 32))"}
        """
    }

    private func listed(_ addresses: [String]) -> String {
        "[" + addresses.map { #"{"address":"\#($0)"}"# }.joined(separator: ",") + "]"
    }

    private func stub(
        _ owner: CardanoAccountDescriptor,
        addresses: StubURLProtocol.StubResponse,
        utxos: StubURLProtocol.StubResponse
    ) -> StubURLProtocol.Session {
        StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": addresses,
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": utxos
        ])
    }

    // MARK: Index limit

    @Test func nextIndexFollowsTheNewestAndFallsBackToTheLowestFree() {
        #expect(CardanoAccountDescriptor.nextExternalIndex(after: []) == 0)
        #expect(CardanoAccountDescriptor.nextExternalIndex(after: [0, 3]) == 4)
        #expect(CardanoAccountDescriptor.nextExternalIndex(after: [0, 999]) == 1)
        #expect(CardanoAccountDescriptor.nextExternalIndex(after: Set(0..<1_000)) == nil)
        #expect(CardanoAccountDescriptor.nextExternalIndex(after: [0, .max]) == 1)
    }

    @Test func listingRefusesIndicesBeyondTheLimit() async throws {
        let owner = try descriptor()
        let client = client(stub(owner, addresses: json("[]"), utxos: json("[]")))

        await #expect(throws: WalletKitError.self) {
            try await client.receiveAddresses(owner, including: [1_000], snapshot: .empty)
        }
    }

    @Test func signingStopsAtTheIndexLimit() throws {
        let owner = try descriptor()
        let last = try owner.address(role: 0, index: 999).string
        let beyond = try owner.address(role: 0, index: 1_000).string

        let paths = try owner.signingPaths(for: [last, beyond])

        #expect(paths[last]?.index == 999)
        #expect(paths[beyond] == nil)
    }

    // MARK: Listing

    @Test func rowsAreSparseSortedAndCarryPerAddressLovelace() async throws {
        let owner = try descriptor()
        let used = try owner.address(role: 0, index: 2).string
        let funded = try owner.address(role: 0, index: 5).string
        let stub = stub(
            owner,
            addresses: json(listed([used, funded])),
            utxos: json("[" + utxo(funded, lovelace: "7000000") + "]")
        )

        let client = client(stub)

        let snapshot = try await client.utxoSnapshot(owner)
        let rows = try await client.receiveAddresses(owner, including: [9], snapshot: snapshot)

        #expect(rows.map(\.index) == [0, 2, 5, 9])
        #expect(rows.map(\.isUsed) == [false, true, true, false])
        #expect(rows.map(\.lovelace) == [0, 0, 7_000_000, 0])
    }

    @Test func aUTxOMarksAnAddressUsedWhenTheAddressListLags() async throws {
        let owner = try descriptor()
        let funded = try owner.address(role: 0, index: 500).string
        let stub = stub(owner, addresses: json("[]"), utxos: json("[" + utxo(funded, lovelace: "3000000") + "]"))
        let client = client(stub)

        let snapshot = try await client.utxoSnapshot(owner)
        let rows = try await client.receiveAddresses(owner, including: [], snapshot: snapshot)

        #expect(rows.map(\.index) == [0, 500])
        #expect(rows.last?.isUsed == true)
        #expect(rows.last?.lovelace == 3_000_000)
    }

    @Test func foreignAddressesAreIgnoredByListingAndNeverThrowFromUTxOs() async throws {
        let owner = try descriptor()
        let foreign = try CardanoAccountDescriptor(
            entropy: Data(repeating: 9, count: 16),
            network: .preprod,
            path: path
        ).receiveAddress.string

        let utxoOnly = stub(owner, addresses: json("[]"), utxos: json("[" + utxo(foreign, lovelace: "1000000") + "]"))
        let usage = try await client(utxoOnly).addressUsage(owner)
        #expect(usage.used.isEmpty)

        let listedForeign = stub(owner, addresses: json(listed([foreign])), utxos: json("[]"))
        let client = client(listedForeign)
        let rows = try await client.receiveAddresses(owner, including: [], snapshot: .empty)
        #expect(rows.map(\.index) == [0])

        await #expect(throws: WalletKitError.self) {
            try await client.addressUsage(owner)
        }
    }

    @Test func aNeverUsedAccountListsRowZero() async throws {
        let owner = try descriptor()
        let notFound = StubURLProtocol.StubResponse.success(statusCode: 404, body: Data("{}".utf8))
        let client = client(stub(owner, addresses: notFound, utxos: notFound))

        let snapshot = try await client.utxoSnapshot(owner)
        let rows = try await client.receiveAddresses(owner, including: [], snapshot: snapshot)

        #expect(snapshot == .empty)
        #expect(rows.map(\.index) == [0])
    }

    @Test func aFailureAfterPagingBeganThrowsInsteadOfReturningAPartialRead() async throws {
        let owner = try descriptor()
        let address = try owner.address(role: 0, index: 0).string
        let utxos = Array(repeating: utxo(address, lovelace: "1000000"), count: 100)
        let fullPage = "[" + utxos.joined(separator: ",") + "]"
        let session = StubURLProtocol.makeSession(responseSequence: [
            json(fullPage),
            .success(statusCode: 404, body: Data("{}".utf8))
        ])

        await #expect(throws: (any Error).self) {
            try await client(session).utxoSnapshot(owner)
        }
    }

    // MARK: Issued addresses

    @Test func anIssuedAddressIsProvenFromTheKeyWithoutANetwork() throws {
        let owner = try descriptor()
        let issued = try owner.address(role: 0, index: 500)
        let bytes = try cardanoAddressBytes(issued.string)

        #expect(try cardanoIssuedSigningPath(for: bytes, owner: owner, indices: [0, 500])?.index == 500)
        #expect(try cardanoIssuedSigningPath(for: bytes, owner: owner, indices: [0, 499]) == nil)

        let foreign = try CardanoAccountDescriptor(
            entropy: Data(repeating: 9, count: 16),
            network: .preprod,
            path: path
        ).receiveAddress
        let foreignBytes = try cardanoAddressBytes(foreign.string)

        #expect(try cardanoIssuedSigningPath(for: foreignBytes, owner: owner, indices: [0, 500]) == nil)
    }
}
