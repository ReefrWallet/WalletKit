// Regenerates TestVectors/aptos-*.json with the official Aptos TS SDK:
//   cd Scripts/aptos-test-vectors && npm install && node gen.mjs && cp out/*.json ../../TestVectors/
// Keys here are fixed, test-only, and never funded on a public network.
import fs from "node:fs";
import {
  Account, AccountAddress, ChainId, Ed25519PrivateKey, EntryFunction,
  RawTransaction, Secp256k1PrivateKey, SigningSchemeInput, SimpleTransaction,
  TransactionPayloadEntryFunction, U64, generateSignedTransaction, generateUserTransactionHash,
  generateSigningMessageForTransaction, Hex, TypeTag, parseTypeTag,
} from "@aptos-labs/ts-sdk";

// Raw 64-byte signature, unwrapping AnySignature for SingleKey accounts.
const rawSig = (sig) => Hex.fromHexInput(sig.signature ? sig.signature.toUint8Array() : sig.toUint8Array()).toString();
const hex = (b) => Hex.fromHexInput(b).toString();
const SDK = JSON.parse(fs.readFileSync("node_modules/@aptos-labs/ts-sdk/package.json")).version;

// Fixed, test-only keys (never funded on any public network).
const keys = [
  { label: "ed25519-a", scheme: "ed25519", pk: "0x" + "11".repeat(32) },
  { label: "ed25519-b", scheme: "ed25519", pk: "0x9bf49a6a0755f953811fce125f2683d50429c3bb49e074147e0089a52eae155f" },
  { label: "secp256k1-a", scheme: "secp256k1", pk: "0x" + "22".repeat(32) },
  { label: "secp256k1-b", scheme: "secp256k1", pk: "0xd107155adf816a0a94c6db3c9489c13ad8a1eda7ada2e558ba3bfa47c020347e" },
];

const makeAccount = ({ scheme, pk }) =>
  scheme === "ed25519"
    ? Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(pk), legacy: true })
    : Account.fromPrivateKey({ privateKey: new Secp256k1PrivateKey(pk) });

// ---- addresses ---------------------------------------------------------
const addresses = keys.map((k) => {
  const a = makeAccount(k);
  return {
    label: k.label, scheme: k.scheme, privateKey: k.pk,
    // Raw key bytes: 32-byte Ed25519, or 65-byte uncompressed secp256k1.
    publicKey: hex(k.scheme === "ed25519" ? a.publicKey.toUint8Array() : a.publicKey.publicKey.toUint8Array()),
    // BCS(AnyPublicKey) — what SingleKey accounts hash into their address.
    ...(k.scheme === "secp256k1" ? { anyPublicKeyBcsHex: hex(a.publicKey.bcsToBytes()) } : {}),
    address: a.accountAddress.toStringLong(),
  };
});

// ---- mnemonic derivation ----------------------------------------------
const mnemonic = "shoot island position soft burden budget tooth cruel issue economy destroy above";
const derivation = [];
for (let i = 0; i < 3; i++) {
  const edPath = `m/44'/637'/${i}'/0'/0'`;
  const ed = Account.fromDerivationPath({ scheme: SigningSchemeInput.Ed25519, path: edPath, mnemonic, legacy: true });
  derivation.push({ scheme: "ed25519", accountIndex: i, path: edPath,
    privateKey: hex(ed.privateKey.toUint8Array()), address: ed.accountAddress.toStringLong() });
  const kPath = `m/44'/637'/${i}'/0/0`;
  const k = Account.fromDerivationPath({ scheme: SigningSchemeInput.Secp256k1Ecdsa, path: kPath, mnemonic });
  derivation.push({ scheme: "secp256k1", accountIndex: i, path: kPath,
    privateKey: hex(k.privateKey.toUint8Array()), address: k.accountAddress.toStringLong() });
}

// ---- signed transactions ----------------------------------------------
const recipient = AccountAddress.from("0x" + "ab".repeat(32));
const payloads = [
  { kind: "apt-transfer", ef: () => EntryFunction.build("0x1::aptos_account", "transfer", [], [recipient, new U64(123_456_789n)]) },
  { kind: "coin-transfer", ef: () => EntryFunction.build("0x1::aptos_account", "transfer_coins",
      [parseTypeTag("0x1::aptos_coin::AptosCoin")], [recipient, new U64(42n)]) },
  { kind: "fa-transfer", ef: () => EntryFunction.build("0x1::primary_fungible_store", "transfer",
      [parseTypeTag("0x1::fungible_asset::Metadata")],
      [AccountAddress.from("0xa"), recipient, new U64(1_000n)]) },
];

const transactions = [];
for (const k of keys) {
  const acct = makeAccount(k);
  for (const [i, p] of payloads.entries()) {
    const raw = new RawTransaction(
      acct.accountAddress, BigInt(7 + i), new TransactionPayloadEntryFunction(p.ef()),
      200_000n, 100n, 1_900_000_000n, new ChainId(4),
    );
    const tx = new SimpleTransaction(raw);
    const auth = acct.signTransactionWithAuthenticator(tx);
    const signed = generateSignedTransaction({ transaction: tx, senderAuthenticator: auth });
    transactions.push({
      label: `${k.label}/${p.kind}`, scheme: k.scheme, privateKey: k.pk,
      rawTransactionBcsHex: hex(raw.bcsToBytes()),
      signingMessageHex: hex(generateSigningMessageForTransaction(tx)),
      accountAuthenticatorBcsHex: hex(auth.bcsToBytes()),
      signedTransactionBcsHex: hex(signed),
      transactionHashHex: generateUserTransactionHash({ transaction: tx, senderAuthenticator: auth }),
    });
  }
}

// ---- off-chain messages ------------------------------------------------
const messages = [];
const msgs = ["Hello, Aptos!", "", "APTOS\nmessage: sign in to reefr\nnonce: 42"];
for (const k of keys) {
  const acct = makeAccount(k);
  for (const m of msgs) {
    const bytes = new TextEncoder().encode(m);
    messages.push({ label: `${k.label}/${JSON.stringify(m).slice(0, 24)}`, scheme: k.scheme,
      privateKey: k.pk, messageHex: hex(bytes), signatureHex: rawSig(acct.sign(bytes)) });
  }
}

// ---- Move type tags ---------------------------------------------------
const typeTags = [
  "u8", "u64", "u128", "u256", "bool", "address", "vector<u8>", "vector<vector<address>>",
  "0x1::aptos_coin::AptosCoin", "0x1::fungible_asset::Metadata",
  "0x1::coin::CoinStore<0x1::aptos_coin::AptosCoin>",
  "0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDC",
  "0x1::pool::Pool<0x1::aptos_coin::AptosCoin, vector<u64>>",
].map((s) => ({ typeTag: s, bcsHex: hex(parseTypeTag(s).bcsToBytes()) }));

const out = "out";
fs.mkdirSync(out, { recursive: true });
const write = (name, entries, note) => fs.writeFileSync(`${out}/${name}`,
  JSON.stringify(entries.map((e) => ({ ...e })), null, 2) + "\n");
write("aptos-address.json", addresses);
write("aptos-derivation.json", [{ mnemonic, passphrase: "" }, ...derivation].slice(1).map((d) => ({ mnemonic, ...d })));
write("aptos-tx.json", transactions);
write("aptos-message.json", messages);
write("aptos-type-tag.json", typeTags);
console.log(`ts-sdk ${SDK}: ${addresses.length} addresses, ${derivation.length} derivations, ${transactions.length} txs, ${messages.length} messages`);
