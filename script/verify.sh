#!/usr/bin/env bash
# Verifies the already-deployed contracts on opBNB Testnet (5611). Needs Foundry (forge, cast).
# Settings MUST match what you used in Remix: solc 0.8.24, optimizer on, 200 runs (+ --via-ir if you enabled viaIR).
set -euo pipefail
source .env
RPC=${RPC_URL:-https://opbnb-testnet-rpc.bnbchain.org}
P=0x5c6dA7E2B4D37Bc88E828c6512c93C659e5f1F1d
V=0x3b9b87018E3f99841f4323dC2357BD21075dfbde

# constructor args are read back from chain (treasury may differ if you already called setTreasury)
TREASURY=$(cast call $P "treasury()(address)" --rpc-url $RPC)
ARBITER=$(cast call $P "arbiter()(address)" --rpc-url $RPC)
BOND=$(cast call $P "reportBond()(uint256)" --rpc-url $RPC | awk '{print $1}')
echo "treasury=$TREASURY arbiter=$ARBITER reportBond=$BOND"

forge verify-contract $P src/DeDataProtocol.sol:DeDataProtocol \
  --chain 5611 --compiler-version 0.8.24 --num-of-optimizations 200 ${VIA_IR:+--via-ir} \
  --constructor-args $(cast abi-encode "constructor(address,address,uint256)" $TREASURY $ARBITER $BOND) \
  --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" --watch

forge verify-contract $V src/DeDataProvenance.sol:DeDataProvenance \
  --chain 5611 --compiler-version 0.8.24 --num-of-optimizations 200 ${VIA_IR:+--via-ir} \
  --constructor-args $(cast abi-encode "constructor(address)" $P) \
  --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" --watch
