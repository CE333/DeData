# DeData Protocol: deployment on opBNB Testnet (5611)

Two contracts are already deployed and operational. This folder contains everything needed to interact with them on-chain without recompiling or redeploying.

## Structure

| Folder/file | Purpose |
|---|---|
| `src/` | Solidity source code (reference only; no compilation needed) |
| `script/canary-tree.js` | Off-chain: builds the Merkle tree of buyer-unique canaries and generates proofs for leak reports |
| `script/dedata.js` | CLI to interact with the deployed contracts: status, list datasets, buy, dispute, mint provenance receipts, etc. |
| `script/abi.js` | Human-readable ABIs (written by hand, compiled from `src/`) |
| `script/verify.sh` | Verifies the source code on opBNB explorer (Foundry required) |
| `test/DeDataSettlement.t.sol` | Comprehensive Foundry test suite (38 tests, fuzzed accounting) |
| `deployments/opbnb-testnet.json` | Deployment metadata: contract addresses, tx hashes, block numbers |
| `foundry.toml` | Foundry config (for compilation and testing) |

## Quick start

### 1. Check contract status
```bash
npm install
cp .env.example .env   # fill PRIVATE_KEY if you're about to interact, or leave blank to read-only
node --env-file=.env script/dedata.js status
```

### 2. List a dataset (provider)
```bash
node --env-file=.env script/dedata.js list <dataHash> <metadataURI> <pricePerEpsBNB> <epsTotal> <minBuyerStakeBNB>
# Example:
node --env-file=.env script/dedata.js list "greenfield-object" "ipfs://Qm..." 0.001 100 0.5
# Outputs: salt saved to ./salts/listing-*.json (keep it safe)
# After commit block lands, the transaction hash is logged.
```

### 3. Generate canary trees (off-chain, for every request)
```bash
node script/canary-tree.js <requestId> <count>
# Outputs JSON with canaryRoot and proof for each record.
```

### 4. Commit result (provider)
```bash
node --env-file=.env script/dedata.js commit-result <requestId> <resultHash> <canaryRoot>
# (resultHash and canaryRoot from step 3)
```

### 5. Buy compute (buyer)
```bash
node --env-file=.env script/dedata.js stake 1.0      # first-time setup: stake 1 BNB
node --env-file=.env script/dedata.js quote 1 10     # check price for dataset 1, 10 eps
node --env-file=.env script/dedata.js buy 1 10 0x<YOUR_PUBLIC_KEY> 100  # buy (100 bps slippage)
# Outputs: requestId (used to check status, dispute, report leaks)
```

### 6. Finalize or dispute
```bash
# Happy path: 24h after commit, anyone can finalize.
node --env-file=.env script/dedata.js finalize <requestId>

# Buyer disputes within 24h:
node --env-file=.env script/dedata.js dispute <requestId>
# (requires arbiter to resolve in 72h, or dispute expires and funds are refunded)
```

### 7. Report a leak (anyone, off-chain proof)
```bash
node script/canary-tree.js <requestId> <count> | jq '.canaries[0]'  # find a canary in the leaked data
node --env-file=.env script/dedata.js report-leak <requestId> <canaryHash> '[proof_array]'
```

### 8. Mint model provenance receipt (buyer, after settlement)
```bash
node --env-file=.env script/dedata.js mint "model-label" "ipfs://model-metadata" 1 2 3
# (request IDs 1, 2, 3 all completed; outputs receipt token ID)
```

### 9. Check account state
```bash
node --env-file=.env script/dedata.js me
```

## On-chain addresses

- **Protocol**: [`0x5c6dA7E2B4D37Bc88E828c6512c93C659e5f1F1d`](https://testnet.opbnbscan.com/address/0x5c6dA7E2B4D37Bc88E828c6512c93C659e5f1F1d)
- **Provenance**: [`0x3b9b87018E3f99841f4323dC2357BD21075dfbde`](https://testnet.opbnbscan.com/address/0x3b9b87018E3f99841f4323dC2357BD21075dfbde)
- **RPC**: https://opbnb-testnet-rpc.bnbchain.org
- **Explorer**: https://testnet.opbnbscan.com

## Verify source code on explorer

Needs Foundry and `ETHERSCAN_API_KEY` in `.env`:
```bash
# Read treasury and arbiter from on-chain (may differ from constructor if changed by owner)
bash script/verify.sh
```

## Test the contracts locally (Foundry)

```bash
forge install foundry-rs/forge-std --no-commit
forge test -vvv
forge test --match-test testFuzz -vvv
forge coverage
```

## Known limitations

- **Arbiter is a trust anchor:** The arbiter is currently a single address. It is responsible for resolving disputes and confirming leaks honestly. Moving it to an independent multisig is recommended.
- **Provider knows its own canaries:** The provider generates the canaries embedded in each result, so it can theoretically file a fake leak report through a second account. Only the arbiter's judgment (based on independent evidence) can prevent this.
- **Greenfield ownership not verified on-chain:** Commit-reveal prevents listing front-running but does not cryptographically prove the lister owns the Greenfield object.

## No compilation, no redeployment

Every command and script in this folder works against the live contracts. You do NOT need to:
- Recompile Solidity.
- Redeploy the contracts.
- Change network settings in Remix or Hardhat.

To participate, just fill in `.env` with your testnet key and run the CLI.

## Questions?

See the [pitch deck](https://app.clickup.com/90141732790/artifact/2kydvbxp-574) for an overview of the mechanism.

---

Deployed by [@SIMURIAX](https://github.com/simuriax) on opBNB Testnet (5611).
