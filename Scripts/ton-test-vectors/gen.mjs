// Regenerates TestVectors/ton-*.json with the official TON JS SDK (@ton/ton, @ton/core, @ton/crypto):
//   cd Scripts/ton-test-vectors && npm install && node gen.mjs && cp out/*.json ../../TestVectors/
// Keys and the mnemonic are fixed, test-only, and never funded on a public network.
import crypto from "node:crypto";
import fs from "node:fs";
import { Address, beginCell, Cell, SendMode, storeMessage } from "@ton/core";
import { deriveEd25519Path, keyPairFromSeed, sign } from "@ton/crypto";
import { external, internal, WalletContractV5R1 } from "@ton/ton";

const SDK = JSON.parse(fs.readFileSync("node_modules/@ton/ton/package.json")).version;
const hex = (b) => Buffer.from(b).toString("hex");
const networks = [
  { name: "mainnet", globalId: -239, testOnly: false },
  { name: "testnet", globalId: -3, testOnly: true },
];

const wallet = (publicKey, net) =>
  WalletContractV5R1.create({ publicKey, workchain: 0, walletId: { networkGlobalId: net.globalId } });
const friendly = (address, net) => address.toString({ urlSafe: true, bounceable: false, testOnly: net.testOnly });

// ---- addresses from fixed seeds ----------------------------------------
const seeds = [
  { label: "seed-11", seed: Buffer.alloc(32, 0x11) },
  { label: "seed-22", seed: Buffer.alloc(32, 0x22) },
];
const addresses = [];
for (const { label, seed } of seeds) {
  const kp = keyPairFromSeed(seed);
  for (const net of networks) {
    const w = wallet(kp.publicKey, net);
    addresses.push({
      label: `${label}-${net.name}`, network: net.name, privateKey: hex(seed), publicKey: hex(kp.publicKey),
      address: friendly(w.address, net), raw: w.address.toRawString(),
      stateInitHash: hex(beginCell().store((b) => {
        b.storeBit(0).storeBit(0).storeBit(1).storeBit(1).storeBit(0).storeRef(w.init.code).storeRef(w.init.data);
      }).endCell().hash()),
      codeHash: hex(w.init.code.hash()), dataHash: hex(w.init.data.hash()),
    });
  }
}

// ---- mnemonic derivation (standard BIP39 seed + the SDK's SLIP-10 ed25519, m/44'/607'/i') ----
// Not `mnemonicToHDSeed`: that is the TON-native mnemonic scheme (different salt and iterations), not BIP39.
const mnemonic = "shoot island position soft burden budget tooth cruel issue economy destroy above";
const hdSeed = crypto.pbkdf2Sync(mnemonic.normalize("NFKD"), "mnemonic", 2048, 64, "sha512");
const derivation = [];
for (let i = 0; i < 3; i++) {
  const path = `m/44'/607'/${i}'`;
  const seed = await deriveEd25519Path(hdSeed, [44, 607, i]);
  const kp = keyPairFromSeed(seed);
  for (const net of networks) {
    derivation.push({
      mnemonic, path, accountIndex: i, network: net.name, privateKey: hex(seed), publicKey: hex(kp.publicKey),
      address: friendly(wallet(kp.publicKey, net).address, net),
    });
  }
}

// ---- signed transfers ----------------------------------------------------
const recipients = [
  { label: "bounceable", address: Address.parse("EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N"), bounce: true },
  { label: "non-bounceable", address: Address.parse("EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N"), bounce: false },
];
const cases = [
  { label: "plain", seqno: 0, deploy: true, value: 1_000_000_000n, comment: null, validUntil: 1_700_000_600 },
  { label: "seqno-42", seqno: 42, deploy: false, value: 123_456_789_012n, comment: null, validUntil: 1_700_000_600 },
  { label: "comment", seqno: 7, deploy: false, value: 5_000_000n, comment: "gm", validUntil: 1_800_000_000 },
];
const transfers = [];
const seed = seeds[0].seed;
const kp = keyPairFromSeed(seed);
for (const net of networks) {
  const w = wallet(kp.publicKey, net);
  for (const c of cases) {
    for (const r of recipients) {
      const msg = internal({ to: r.address, value: c.value, bounce: r.bounce, body: c.comment ?? undefined });
      const body = w.createTransfer({
        seqno: c.seqno, secretKey: kp.secretKey, sendMode: SendMode.PAY_GAS_SEPARATELY,
        messages: [msg], timeout: c.validUntil,
      });
      // `body` is signed (signature appended); the unsigned part is everything but the last 512 bits.
      const slice = body.beginParse();
      const unsigned = beginCell().storeBits(slice.loadBits(slice.remainingBits - 512));
      while (slice.remainingRefs > 0) unsigned.storeRef(slice.loadRef());
      const unsignedCell = unsigned.endCell();
      const signature = sign(unsignedCell.hash(), kp.secretKey);
      const ext = external({ to: w.address, init: c.deploy ? w.init : undefined, body });
      const message = beginCell().store(storeMessage(ext)).endCell();
      const normalized = beginCell().storeUint(2, 2).storeUint(0, 2).storeAddress(w.address).storeCoins(0)
        .storeBit(false).storeBit(true).storeRef(body).endCell();
      transfers.push({
        label: `${net.name}/${c.label}/${r.label}`, network: net.name, privateKey: hex(seed),
        sender: friendly(w.address, net), recipient: r.address.toString({ urlSafe: true, bounceable: r.bounce }),
        bounce: r.bounce, amount: c.value.toString(), comment: c.comment, seqno: c.seqno,
        validUntil: c.validUntil, deploy: c.deploy,
        signingBodyHash: hex(unsignedCell.hash()), signature: hex(signature),
        signedBodyBocHex: hex(body.toBoc({ idx: false, crc32: false })),
        externalMessageBocHex: hex(message.toBoc({ idx: false, crc32: false })),
        normalizedHash: hex(normalized.hash()),
      });
    }
  }
}

const out = "out";
fs.mkdirSync(out, { recursive: true });
const write = (name, entries) => fs.writeFileSync(`${out}/${name}`, JSON.stringify(entries, null, 2) + "\n");
write("ton-address.json", addresses);
write("ton-derivation.json", derivation);
write("ton-transfer.json", transfers);
console.log(`@ton/ton ${SDK}: ${addresses.length} addresses, ${derivation.length} derivations, ${transfers.length} transfers`);
