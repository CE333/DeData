// Builds the per-request canary Merkle tree used by DeDataProtocol.
//
//   npm install ethers@6
//   node script/canary-tree.js <requestId> <count>
//
// Output: canaryRoot (for commitResult) and, for each record, the canaryHash and proof
// (for reportLeak). Keep the records secret; they are the buyer's fingerprint.

const { AbiCoder, concat, keccak256, randomBytes } = require("ethers");

const coder = AbiCoder.defaultAbiCoder();

const leafOf = (requestId, canaryHash) =>
  keccak256(keccak256(coder.encode(["uint256", "bytes32"], [requestId, canaryHash])));

const hashPair = (a, b) => (BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a])));

function buildLayers(leaves) {
  const layers = [leaves];
  while (layers.at(-1).length > 1) {
    const level = layers.at(-1);
    const next = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(i + 1 < level.length ? hashPair(level[i], level[i + 1]) : level[i]);
    }
    layers.push(next);
  }
  return layers;
}

function proofOf(layers, index) {
  const proof = [];
  for (let depth = 0; depth < layers.length - 1; depth++) {
    const sibling = index ^ 1;
    if (sibling < layers[depth].length) proof.push(layers[depth][sibling]);
    index >>= 1;
  }
  return proof;
}

function main() {
  const requestId = BigInt(process.argv[2] ?? 1);
  const count = Number(process.argv[3] ?? 8);

  const records = Array.from({ length: count }, () => keccak256(randomBytes(32)));
  const layers = buildLayers(records.map((r) => leafOf(requestId, r)));

  console.log(JSON.stringify({
    requestId: requestId.toString(),
    canaryRoot: layers.at(-1)[0],
    canaries: records.map((canaryHash, i) => ({ canaryHash, proof: proofOf(layers, i) })),
  }, null, 2));
}

main();
