// Provider node: serves compute-to-data jobs for datasets YOU listed.
//   node --env-file=.env script/provider-node.js        (PRIVATE_KEY = provider wallet, testnet only)
// Flow: new Pending request -> DP-noised compute -> canaries + Merkle root -> encrypt to buyer key
//       -> serve ciphertext at GET /result/<id> -> commitResult with bond (must land within 2 days).
const fs = require("fs"), path = require("path"), http = require("http"), crypto = require("crypto");
const { Contract, JsonRpcProvider, Wallet, AbiCoder, keccak256, concat, randomBytes } = require("ethers");
const { PROTOCOL_ABI } = require("./abi");
const dep = require("../deployments/opbnb-testnet.json");
const cfg = require("../provider.config.json");
const provider = new JsonRpcProvider(process.env.RPC_URL || dep.rpc, dep.chainId);
const wallet = new Wallet(process.env.PRIVATE_KEY, provider);
const P = new Contract(dep.DeDataProtocol.address, PROTOCOL_ABI, wallet);
const OUT = path.join(__dirname, "..", "out"); fs.mkdirSync(OUT, { recursive: true });
const coder = AbiCoder.defaultAbiCoder(), busy = new Set();

// --- differential privacy: clipped mean + Laplace noise, scale = sensitivity / (eps * epsUnit)
function compute(ds, eps) {
  const v = fs.readFileSync(ds.file, "utf8").trim().split("\n").slice(1).map((l) => Number(l.split(",")[ds.column || 0]))
    .filter(Number.isFinite).map((x) => Math.min(ds.hi, Math.max(ds.lo, x)));
  const mean = v.reduce((a, b) => a + b, 0) / v.length;
  const scale = (ds.hi - ds.lo) / v.length / (eps * cfg.epsUnit);
  const u = crypto.randomInt(1, 2 ** 48) / 2 ** 48 - 0.5;
  return { query: "mean", n: v.length, epsUnits: eps, value: mean - scale * Math.sign(u) * Math.log(1 - 2 * Math.abs(u)), noiseScale: scale };
}
// --- ECDH P-256 + AES-256-GCM, key = sha256(shared x). The buyer's browser decrypts with WebCrypto.
function encrypt(buyerKeyHex, plain) {
  const e = crypto.createECDH("prime256v1"); e.generateKeys();
  const key = crypto.createHash("sha256").update(e.computeSecret(Buffer.from(buyerKeyHex.slice(2), "hex"))).digest();
  const iv = crypto.randomBytes(12), c = crypto.createCipheriv("aes-256-gcm", key, iv);
  const ct = Buffer.concat([c.update(plain), c.final(), c.getAuthTag()]);
  return JSON.stringify({ v: 1, epk: "0x" + e.getPublicKey("hex"), iv: "0x" + iv.toString("hex"), ct: "0x" + ct.toString("hex") });
}
// --- canary tree (same format as canary-tree.js / the contract)
const leaf = (id, h) => keccak256(keccak256(coder.encode(["uint256", "bytes32"], [id, h])));
const pair = (a, b) => (BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a])));
function layers(l) { const L = [l]; while (L.at(-1).length > 1) { const v = L.at(-1), n = []; for (let i = 0; i < v.length; i += 2) n.push(i + 1 < v.length ? pair(v[i], v[i + 1]) : v[i]); L.push(n); } return L; }
function proof(L, i) { const p = []; for (let d = 0; d < L.length - 1; d++) { if ((i ^ 1) < L[d].length) p.push(L[d][i ^ 1]); i >>= 1; } return p; }

async function buyerKeyOf(id) {
  const head = await provider.getBlockNumber();
  for (let s = Math.max(dep.DeDataProtocol.blockNumber, head - 200000); s <= head; s += 50000) {
    const ev = await P.queryFilter(P.filters.ComputeRequested(id), s, Math.min(s + 49999, head));
    if (ev.length) return ev[0].args.buyerKey;
  }
}
async function handle(id) {
  const r = await P.getRequest(id), ds = cfg.datasets[r.datasetId.toString()];
  const key = await buyerKeyOf(id); if (!key) throw new Error("buyerKey event not found");
  const res = compute(ds, Number(r.epsSpent));
  const records = Array.from({ length: cfg.canaries || 8 }, () => keccak256(randomBytes(32)));
  const L = layers(records.map((h) => leaf(BigInt(id), h))), root = L.at(-1)[0];
  const blob = encrypt(key, Buffer.from(JSON.stringify({ requestId: String(id), ...res, canaryRecords: records })));
  fs.writeFileSync(path.join(OUT, `result-${id}.json`), blob);
  fs.writeFileSync(path.join(OUT, `canaries-${id}.json`), JSON.stringify({ canaryRoot: root, canaries: records.map((canaryHash, i) => ({ canaryHash, proof: proof(L, i) })) }, null, 2));
  const tx = await P.commitResult(id, keccak256(Buffer.from(blob)), root, { value: await P.providerBondFor(id) });
  console.log(`request ${id}: commitResult ${tx.hash}`); await tx.wait();
}
async function tick() {
  const now = Math.floor(Date.now() / 1000), n = Number(await P.requestCount());
  for (let id = 1; id <= n; id++) {
    if (busy.has(id)) continue;
    const r = await P.getRequest(id);
    if (Number(r.status) !== 1 || now > Number(r.commitDeadline) || !cfg.datasets[r.datasetId.toString()]) continue;
    if ((await P.getDataset(r.datasetId)).provider !== wallet.address) continue;
    busy.add(id);
    try { await handle(id); } catch (e) { console.error(`request ${id} failed:`, e.shortMessage || e.message); busy.delete(id); }
  }
}
http.createServer((q, s) => {
  const m = /^\/result\/(\d+)$/.exec(q.url), f = m && path.join(OUT, `result-${m[1]}.json`);
  s.setHeader("Access-Control-Allow-Origin", "*");
  if (!f || !fs.existsSync(f)) { s.statusCode = 404; return s.end("not found"); }
  s.setHeader("Content-Type", "application/json"); s.end(fs.readFileSync(f));
}).listen(cfg.port || 8787, () => console.log(`provider ${wallet.address} serving results on :${cfg.port || 8787}`));
(async function loop() { try { await tick(); } catch (e) { console.error(e.shortMessage || e.message); } setTimeout(loop, 15000); })();
