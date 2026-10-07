// DeData CLI for the contracts already deployed on opBNB Testnet. No compile, no deploy.
//
//   npm install
//   cp .env.example .env   (fill PRIVATE_KEY for write commands)
//   node --env-file=.env script/dedata.js <command> [...args]
//
// Run without a command to see the full list.

const fs = require("fs");
const path = require("path");
const { AbiCoder, Contract, JsonRpcProvider, Wallet, formatEther, hexlify, isHexString, keccak256, parseEther, randomBytes, toUtf8Bytes } = require("ethers");
const { PROTOCOL_ABI, PROVENANCE_ABI, REQUEST_STATUS } = require("./abi");

const dep = require("../deployments/opbnb-testnet.json");
const coder = AbiCoder.defaultAbiCoder();
const provider = new JsonRpcProvider(process.env.RPC_URL || dep.rpc, dep.chainId);
const signer = process.env.PRIVATE_KEY ? new Wallet(process.env.PRIVATE_KEY, provider) : null;
const runner = signer || provider;
const protocol = new Contract(process.env.PROTOCOL_ADDRESS || dep.DeDataProtocol.address, PROTOCOL_ABI, runner);
const provenance = new Contract(process.env.PROVENANCE_ADDRESS || dep.DeDataProvenance.address, PROVENANCE_ABI, runner);
const SALT_DIR = path.join(__dirname, "..", "salts");

const need = (cond, msg) => { if (!cond) { console.error(msg); process.exit(1); } };
const me = () => { need(signer, "PRIVATE_KEY missing in .env"); return signer.address; };
const toBytes32 = (v) => (isHexString(v, 32) ? v : keccak256(toUtf8Bytes(v)));
const fmtTime = (t) => (Number(t) ? new Date(Number(t) * 1000).toISOString() : "-");

async function send(label, txPromise) {
  const tx = await txPromise;
  console.log(`${label}: ${tx.hash}\n  ${dep.explorer}/tx/${tx.hash}`);
  const rc = await tx.wait();
  console.log(`  mined in block ${rc.blockNumber}`);
  return rc;
}

async function waitNextBlock(after) {
  while ((await provider.getBlockNumber()) <= after) await new Promise((r) => setTimeout(r, 1000));
}

function saveSalt(kind, data) {
  fs.mkdirSync(SALT_DIR, { recursive: true });
  const file = path.join(SALT_DIR, `${kind}-${Date.now()}.json`);
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
  console.log(`  salt saved to ${path.relative(process.cwd(), file)} (keep it private)`);
}

const commands = {
  async status() {
    const [owner, pendingOwner, treasury, arbiter, pendingArbiter, eta, paused, bond, ds, rq, rp] = await Promise.all([
      protocol.owner(), protocol.pendingOwner(), protocol.treasury(), protocol.arbiter(), protocol.pendingArbiter(),
      protocol.arbiterEta(), protocol.paused(), protocol.reportBond(), protocol.datasetCount(), protocol.requestCount(), protocol.reportCount(),
    ]);
    const linked = await provenance.protocol();
    console.log({
      network: `${dep.network} (${dep.chainId})`,
      protocol: await protocol.getAddress(), owner, pendingOwner, treasury, arbiter, pendingArbiter,
      arbiterEta: fmtTime(eta), paused, reportBond: `${formatEther(bond)} BNB`,
      datasets: ds.toString(), requests: rq.toString(), reports: rp.toString(),
      provenance: await provenance.getAddress(), provenanceLinkedTo: linked,
      provenanceLinkOk: linked.toLowerCase() === (await protocol.getAddress()).toLowerCase(),
      receiptsMinted: (await provenance.totalSupply()).toString(),
    });
    if (arbiter.toLowerCase() === owner.toLowerCase()) console.warn("WARNING: arbiter == owner. Move the arbiter to an independent multisig.");
  },

  async dataset(id) {
    const d = await protocol.getDataset(id);
    console.log({ provider: d.provider, isActive: d.isActive, epsTotal: d.epsTotal, epsRemaining: d.epsRemaining,
      pricePerEps: `${formatEther(d.pricePerEps)} BNB`, minBuyerStake: `${formatEther(d.minBuyerStake)} BNB`,
      totalCompleted: d.totalCompleted.toString(), dataHash: d.dataHash });
  },

  async request(id) {
    const r = await protocol.getRequest(id);
    console.log({ buyer: r.buyer, datasetId: r.datasetId.toString(), status: REQUEST_STATUS[Number(r.status)],
      amount: `${formatEther(r.amount)} BNB`, eps: r.epsSpent, commitDeadline: fmtTime(r.commitDeadline),
      challengeDeadline: fmtTime(r.challengeDeadline), disputeDeadline: fmtTime(r.disputeDeadline),
      resultHash: r.resultHash, canaryRoot: r.canaryRoot });
  },

  async quote(datasetId, eps) {
    console.log(`${formatEther(await protocol.quote(datasetId, eps))} BNB`);
  },

  async me() {
    const a = me();
    const s = await protocol.getStake(a);
    console.log({ address: a, balance: `${formatEther(await provider.getBalance(a))} BNB`,
      claimable: `${formatEther(await protocol.claimable(a))} BNB`, stake: `${formatEther(s.amount)} BNB`,
      unlockAt: fmtTime(s.unlockAt), lastPurchaseAt: fmtTime(s.lastPurchaseAt), openReports: s.openReports });
  },

  // ---------- provider ----------
  // list <dataHash|greenfield-object-id> <metadataURI> <pricePerEpsBNB> <epsTotal> <minBuyerStakeBNB>
  async list(dataRef, metadataURI, price, epsTotal, minStake) {
    const a = me();
    const dataHash = toBytes32(dataRef);
    const salt = hexlify(randomBytes(32));
    const commitment = keccak256(coder.encode(["address", "bytes32", "bytes32"], [a, dataHash, salt]));
    saveSalt("listing", { dataHash, salt, commitment });
    const rc = await send("commit", protocol.commit(commitment));
    await waitNextBlock(rc.blockNumber);
    await send("listDataset", protocol.listDataset(dataHash, salt, metadataURI, parseEther(price), Number(epsTotal), parseEther(minStake)));
    console.log(`listed. datasetCount = ${await protocol.datasetCount()}`);
  },

  // commit-result <requestId> <resultHash|label> <canaryRoot>   (canaryRoot from: node script/canary-tree.js <requestId> <count>)
  async "commit-result"(id, result, canaryRoot) {
    me();
    const bond = await protocol.providerBondFor(id);
    console.log(`provider bond: ${formatEther(bond)} BNB`);
    await send("commitResult", protocol.commitResult(id, toBytes32(result), canaryRoot, { value: bond }));
  },

  // ---------- buyer ----------
  async stake(amountBNB) { me(); await send("stake", protocol.stake({ value: parseEther(amountBNB) })); },
  async "request-unstake"() { me(); await send("requestUnstake", protocol.requestUnstake()); },
  async "cancel-unstake"() { me(); await send("cancelUnstake", protocol.cancelUnstake()); },
  async unstake() { me(); await send("unstake", protocol.unstake()); },

  // buy <datasetId> <eps> <buyerPublicKeyHex> [slippageBps=100]
  async buy(datasetId, eps, buyerKey, slippageBps = "100") {
    me();
    need(isHexString(buyerKey) && buyerKey.length > 2, "buyerPublicKeyHex must be 0x-prefixed hex");
    const cost = await protocol.quote(datasetId, eps);
    const maxCost = cost + (cost * BigInt(slippageBps)) / 10000n;
    console.log(`cost ${formatEther(cost)} BNB, paying up to ${formatEther(maxCost)} BNB (excess becomes claimable)`);
    await send("requestCompute", protocol.requestCompute(datasetId, Number(eps), buyerKey, maxCost, { value: maxCost }));
    console.log(`requestId = ${await protocol.requestCount()}`);
  },

  async dispute(id) {
    me();
    const bond = await protocol.disputeBondFor(id);
    console.log(`dispute bond: ${formatEther(bond)} BNB`);
    await send("disputeResult", protocol.disputeResult(id, { value: bond }));
  },

  // mint <modelHash|label> <uri> <requestId...>   (request IDs ascending, all completed, all yours)
  async mint(model, uri, ...ids) {
    me();
    const sorted = ids.map(BigInt).sort((x, y) => (x < y ? -1 : 1));
    await send("mint", provenance.mint(toBytes32(model), sorted, uri));
    console.log(`receipts minted: ${await provenance.totalSupply()}`);
  },

  // ---------- anyone ----------
  async finalize(id) { me(); await send("finalize", protocol.finalize(id)); },
  async refund(id) { me(); await send("refundUncommitted", protocol.refundUncommitted(id)); },
  async "expire-dispute"(id) { me(); await send("expireDispute", protocol.expireDispute(id)); },
  async "expire-leak"(id) { me(); await send("expireLeak", protocol.expireLeak(id)); },
  async withdraw() { me(); await send("withdraw", protocol.withdraw()); },

  // report-leak <requestId> <canaryHash> <proofJson>   e.g. '["0xabc...","0xdef..."]'
  async "report-leak"(id, canaryHash, proofJson) {
    const a = me();
    const proof = JSON.parse(proofJson);
    const salt = hexlify(randomBytes(32));
    const commitment = keccak256(coder.encode(["address", "uint256", "bytes32", "bytes32"], [a, id, canaryHash, salt]));
    saveSalt("report", { requestId: id, canaryHash, salt, commitment });
    const rc = await send("commit", protocol.commit(commitment));
    await waitNextBlock(rc.blockNumber);
    const bond = await protocol.reportBond();
    await send("reportLeak", protocol.reportLeak(id, canaryHash, salt, proof, { value: bond }));
  },

  // ---------- owner ----------
  async "propose-arbiter"(addr) { me(); await send("proposeArbiter", protocol.proposeArbiter(addr)); console.log("run execute-arbiter after 2 days"); },
  async "execute-arbiter"() { me(); await send("executeArbiter", protocol.executeArbiter()); },
  async "set-treasury"(addr) { me(); await send("setTreasury", protocol.setTreasury(addr)); },
  async pause() { me(); await send("setPaused", protocol.setPaused(true)); },
  async unpause() { me(); await send("setPaused", protocol.setPaused(false)); },
  async "transfer-ownership"(addr) { me(); await send("transferOwnership", protocol.transferOwnership(addr)); },
  async "accept-ownership"() { me(); await send("acceptOwnership", protocol.acceptOwnership()); },
};

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (!cmd || !commands[cmd]) {
    console.log("commands:\n  " + Object.keys(commands).join("\n  "));
    process.exit(cmd ? 1 : 0);
  }
  try {
    await commands[cmd](...args);
  } catch (e) {
    const parsed = e?.data ? protocol.interface.parseError(e.data) || provenance.interface.parseError(e.data) : null;
    console.error(parsed ? `reverted: ${parsed.name}(${parsed.args.join(", ")})` : e.shortMessage || e.message);
    process.exit(1);
  }
}

main();
