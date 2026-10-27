import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

/// Offline coverage of the CIP-30 read and signing support: Blockfrost is
/// stubbed, keys come from fixed test entropy.
struct CardanoDappTests {
    private let endpoint = URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!
    private let entropy = Data(repeating: 0, count: 16)
    private let path = try! DerivationPath(string: "m/1852'/1815'/0'") // swiftlint:disable:this force_try

    private func descriptor() throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: entropy, network: .preprod, path: path)
    }

    private func client(_ stub: StubURLProtocol.Session) -> CardanoClient {
        CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)
    }

    private func json(_ text: String) -> StubURLProtocol.StubResponse {
        .success(body: Data(text.utf8))
    }

    private func utxoJson(address: String, index: UInt32 = 0, extra: String = "") -> String {
        """
        [{
          "address":"\(address)",
          "amount":[{"unit":"lovelace","quantity":"5000000"}],
          "output_index":\(index),
          "tx_hash":"\(String(repeating: "07", count: 32))"\(extra)
        }]
        """
    }

    /// A complete signed transfer, for tests that need valid transaction CBOR.
    private func signedTransfer() async throws -> (transaction: Data, unsigned: CardanoUnsignedTransaction) {
        let account = try descriptor()
        let parameters = """
        {"coins_per_utxo_size":4310,"key_deposit":2000000,"max_tx_size":16384,"max_val_size":5000,
         "min_fee_a":44,"min_fee_b":155381,"pool_deposit":500000000}
        """
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(account.stakeAddress)/utxos": json(utxoJson(address: account.receiveAddress.string)),
            "/api/v0/epochs/latest/parameters": json(parameters)
        ])
        let envelope = try await CardanoTransactionBuilder(client: client(stub)).buildTransfer(
            sender: .account(account),
            recipient: .recipient(try account.address(role: 0, index: 1)),
            amount: 1_000_000,
            token: nil,
            options: []
        )
        let unsigned = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: envelope)

        return (try unsigned.signed(entropy: entropy, path: path), unsigned)
    }

    /// The same transaction as a dapp would send it before signing: no witnesses.
    private func witnessless(_ unsigned: CardanoUnsignedTransaction) -> Data {
        Data([0x84]) + unsigned.transactionBody + Data([0xA0, 0xF5, 0xF6])
    }

    // MARK: Address discovery

    @Test func usedAddressesIncludeSpentOutOnesAndBothRoles() async throws {
        let owner = try descriptor()
        let first = try owner.address(role: 0, index: 0).string
        let later = try owner.address(role: 0, index: 3).string
        let change = try owner.address(role: 1, index: 1).string
        let response = """
        [{"address":"\(later)"},{"address":"\(change)"},{"address":"\(first)"}]
        """
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": json(response)
        ])

        let usage = try await client(stub).addressUsage(owner)

        #expect(usage.used.map { [$0.role, $0.index] } == [[0, 0], [0, 3], [1, 1]])
        #expect(usage.used.map(\.address.string) == [first, later, change])
        #expect(usage.firstUnusedExternalIndex() == 4)
    }

    @Test func discoveryFailsRatherThanOmittingAnUnmatchedKnownAddress() async throws {
        let owner = try descriptor()
        let foreign = try CardanoAccountDescriptor(
            entropy: Data(repeating: 9, count: 16),
            network: .preprod,
            path: path
        ).receiveAddress.string
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": json(#"[{"address":"\#(foreign)"}]"#)
        ])

        await #expect(throws: WalletKitError.self) {
            try await client(stub).addressUsage(owner)
        }
    }

    @Test func anAccountWithNoHistoryHasNoUsedAddresses() async throws {
        let owner = try descriptor()
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": json("[]")
        ])

        let usage = try await client(stub).addressUsage(owner)

        #expect(usage.used.isEmpty)
        #expect(usage.firstUnusedExternalIndex() == 0)
    }

    // MARK: UTxOs and scripts

    @Test func dappUtxosCarryDatumsAndFetchReferenceScriptsOnce() async throws {
        let owner = try descriptor()
        let scriptHash = String(repeating: "ab", count: 28)
        let extra = """
        ,"data_hash":"\(String(repeating: "cd", count: 32))","reference_script_hash":"\(scriptHash)"
        """
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": json(utxoJson(address: owner.receiveAddress.string, extra: extra)),
            "/api/v0/scripts/\(scriptHash)": json(#"{"type":"plutusV2"}"#),
            "/api/v0/scripts/\(scriptHash)/cbor": json(#"{"cbor":"4e4d01000033222220051200120011"}"#)
        ])
        let client = client(stub)

        let utxos = try await client.dappUtxos(owner)

        #expect(utxos.count == 1)
        #expect(utxos[0].datumHash == Data(repeating: 0xCD, count: 32))
        #expect(utxos[0].scriptRef != nil)
        // It serializes as a CIP-30 `TransactionUnspentOutput`.
        #expect(try !cardanoUtxoToHex(utxo: utxos[0]).isEmpty)

        let cached = try await client.dappUtxos(owner)
        #expect(cached == utxos)
        #expect(stub.capturedRequests.filter { $0.url?.path == "/api/v0/scripts/\(scriptHash)/cbor" }.count == 1)
    }

    @Test func nativeReferenceScriptsAreConvertedFromBlockfrostJson() async throws {
        let owner = try descriptor()
        let scriptHash = String(repeating: "ef", count: 28)
        let keyHash = String(repeating: "11", count: 28)
        let script = """
        {"json":{"type":"all","scripts":[{"type":"sig","keyHash":"\(keyHash)"},{"type":"before","slot":500}]}}
        """
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": json(utxoJson(
                address: owner.receiveAddress.string,
                extra: #","reference_script_hash":"\#(scriptHash)""#
            )),
            "/api/v0/scripts/\(scriptHash)": json(#"{"type":"timelock"}"#),
            "/api/v0/scripts/\(scriptHash)/json": json(script)
        ])

        let utxos = try await client(stub).dappUtxos(owner)

        #expect(utxos[0].scriptRef != nil)
    }

    // MARK: Submission

    @Test func submitPostsTheRawTransactionAndReturnsItsBodyHash() async throws {
        let (transaction, unsigned) = try await signedTransfer()
        let expected = try unsigned.transactionBodyHash().map { String(format: "%02x", $0) }.joined()
        let stub = StubURLProtocol.makeSession(response: json("ignored-by-the-client"))

        let result = try await client(stub).submit(rawTransaction: transaction)

        #expect(result == expected)
        #expect(stub.capturedRequest?.url?.path == "/api/v0/tx/submit")
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(stub.capturedBody == transaction)
    }

    @Test func submitTreatsAnAlreadySubmittedRejectionAsSuccess() async throws {
        let (transaction, unsigned) = try await signedTransfer()
        let expected = try unsigned.transactionBodyHash().map { String(format: "%02x", $0) }.joined()
        let stub = StubURLProtocol.makeSession(
            response: .success(statusCode: 400, body: Data("Transaction already submitted".utf8))
        )

        #expect(try await client(stub).submit(rawTransaction: transaction) == expected)
    }

    @Test func submitRejectsEmptyAndRefusedTransactions() async throws {
        let (transaction, _) = try await signedTransfer()
        let refused = StubURLProtocol.makeSession(
            response: .success(statusCode: 400, body: Data("BadInputsUTxO".utf8))
        )

        await #expect(throws: WalletKitError.self) {
            try await client(refused).submit(rawTransaction: Data())
        }
        await #expect(throws: WalletKitError.self) {
            try await client(refused).submit(rawTransaction: transaction)
        }
    }

    // MARK: Signer resolution

    @Test func ownInputsResolveToTheirPaymentKeys() async throws {
        let owner = try descriptor()
        let (_, unsigned) = try await signedTransfer()
        let transaction = witnessless(unsigned)
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": json(utxoJson(address: owner.receiveAddress.string)),
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": json(#"[{"address":"\#(owner.receiveAddress.string)"}]"#)
        ])

        let signers = try await client(stub).resolveSigners(transaction: transaction, owner: owner)

        #expect(signers.toSign == [CardanoSigningPath(index: 0, role: 0)])
        #expect(signers.missingCount == 0)
        #expect(signers.unresolved.isEmpty)
    }

    @Test func anAlreadySignedOwnInputIsSatisfiedNotSignedAgain() async throws {
        let owner = try descriptor()
        let (transaction, _) = try await signedTransfer()
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": json(utxoJson(address: owner.receiveAddress.string)),
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": json(#"[{"address":"\#(owner.receiveAddress.string)"}]"#)
        ])

        let signers = try await client(stub).resolveSigners(transaction: transaction, owner: owner)

        #expect(signers.toSign.isEmpty)
        #expect(signers.validExistingCount == 1)
        #expect(signers.missingCount == 0)
    }

    @Test func inputsOutsideTheAccountAreLookedUpSoAForeignKeyIsASignerAndAScriptIsNot() async throws {
        let owner = try descriptor()
        let (_, unsigned) = try await signedTransfer()
        let transaction = witnessless(unsigned)
        let foreign = try CardanoAccountDescriptor(
            entropy: Data(repeating: 9, count: 16),
            network: .preprod,
            path: path
        ).receiveAddress.string
        let spent = String(repeating: "07", count: 32)

        // The account no longer holds the UTxO; the chain says another key owns it.
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": json("[]"),
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": json("[]"),
            "/api/v0/txs/\(spent)/utxos": json(#"{"outputs":[{"address":"\#(foreign)","output_index":0}]}"#)
        ])

        let signers = try await client(stub).resolveSigners(transaction: transaction, owner: owner)

        #expect(signers.toSign.isEmpty)
        #expect(signers.missingCount == 1)
        #expect(signers.unresolved.isEmpty)
    }

    @Test func inputsOutsideTheAccountAreUnresolved() async throws {
        let owner = try descriptor()
        let (_, unsigned) = try await signedTransfer()
        let transaction = witnessless(unsigned)
        // The account no longer has the UTxO the transaction spends.
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/utxos": json(utxoJson(address: owner.receiveAddress.string, index: 9)),
            "/api/v0/accounts/\(owner.stakeAddress)/addresses": json("[]")
        ])

        let signers = try await client(stub).resolveSigners(transaction: transaction, owner: owner)

        #expect(signers.toSign.isEmpty)
        #expect(signers.unresolved.count == 1)
    }

    // MARK: Signing

    @Test func softwareSignerReturnsAWitnessSetOfNewVkeysOnly() async throws {
        let (_, unsigned) = try await signedTransfer()
        let transaction = witnessless(unsigned)
        let signer = try CardanoPKeySigner(entropy: entropy, network: .preprod, path: path)

        let witnesses = try await signer.signDappTransaction(
            transaction,
            paths: [CardanoSigningPath(index: 0, role: 0)]
        )

        // {0: [[vkey, signature]]}: a one-entry map holding only the vkey witnesses.
        #expect(witnesses.prefix(2) == Data([0xA1, 0x00]))
        #expect(witnesses.count < transaction.count)
    }

    @Test func softwareSignerSignsDataAndTheAddressMapsToItsKey() async throws {
        let owner = try descriptor()
        let address = try cardanoAddressToBytes(address: owner.address(role: 0, index: 2).string)
        let usage = CardanoAddressUsage(used: [])
        let signer = try CardanoPKeySigner(entropy: entropy, network: .preprod, path: path)

        let keyPath = try #require(try cardanoSigningPath(for: address, owner: owner, usage: usage))
        let signed = try await signer.signData(Data("hello".utf8), address: address, path: keyPath)

        #expect(keyPath == CardanoSigningPath(index: 2, role: 0))
        #expect(signed.signature.first == 0x84) // COSE_Sign1 array
        #expect(signed.key.first == 0xA4) // COSE_Key map
    }

    @Test func foreignAddressesHaveNoSigningKey() async throws {
        let owner = try descriptor()
        let foreign = try CardanoAccountDescriptor(
            entropy: Data(repeating: 9, count: 16),
            network: .preprod,
            path: path
        ).receiveAddress.string

        let keyPath = try cardanoSigningPath(
            for: cardanoAddressToBytes(address: foreign),
            owner: owner,
            usage: CardanoAddressUsage(used: [])
        )

        #expect(keyPath == nil)
    }
}
