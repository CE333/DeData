// Keeper: permissionless settlement bot (finalize, refund, expire). Pays gas, no special rights needed.
//   node --env-file=.env script/keeper.js [--once]
const { Contract, JsonRpcProvider, Wallet } = require("ethers");
const { PROTOCOL_ABI } = require("./abi");
const dep = require("../deployments/opbnb-testnet.json");
const provider = new JsonRpcProvider(process.env.RPC_URL || dep.rpc, dep.chainId);
const P = new Contract(dep.DeDataProtocol.address, PROTOCOL_ABI, new Wallet(process.env.PRIVATE_KEY, provider));
async function act(fn, id) {
  try { const tx = await P[fn](id); console.log(`${fn}(${id}) ${tx.hash}`); await tx.wait(); }
  catch (e) { console.error(`${fn}(${id}) skipped:`, e.shortMessage || e.message); }
}
async function tick() {
  const now = Math.floor(Date.now() / 1000);
  for (let i = 1, n = Number(await P.requestCount()); i <= n; i++) {
    const r = await P.getRequest(i), s = Number(r.status);
    if (s === 1 && now > Number(r.commitDeadline)) await act("refundUncommitted", i);
    else if (s === 2 && now >= Number(r.challengeDeadline)) await act("finalize", i);
    else if (s === 3 && now > Number(r.disputeDeadline)) await act("expireDispute", i);
  }
  for (let i = 1, n = Number(await P.reportCount()); i <= n; i++) {
    const p = await P.getReport(i);
    if (Number(p.status) === 1 && now > Number(p.deadline)) await act("expireLeak", i);
  }
}
(async function loop() {
  try { await tick(); } catch (e) { console.error(e.shortMessage || e.message); }
  if (!process.argv.includes("--once")) setTimeout(loop, Number(process.env.KEEPER_SECONDS || 60) * 1000);
})();
