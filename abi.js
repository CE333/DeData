// Human-readable ABIs, written by hand from src/*.sol (no compilation needed).
const DATASET = "tuple(address provider,bool isActive,uint32 epsTotal,uint32 epsRemaining,uint96 pricePerEps,uint96 minBuyerStake,uint64 totalCompleted,bytes32 dataHash,bytes32 metadataHash)";
const REQUEST = "tuple(address buyer,uint96 amount,uint64 datasetId,uint64 commitDeadline,uint64 challengeDeadline,uint64 disputeDeadline,uint96 providerBond,uint96 buyerBond,uint32 epsSpent,uint8 status,uint96 stakeAtRisk,bytes32 buyerKeyHash,bytes32 resultHash,bytes32 canaryRoot)";
const STAKE = "tuple(uint96 amount,uint64 unlockAt,uint64 lastPurchaseAt,uint32 openReports)";
const REPORT = "tuple(address reporter,uint64 requestId,uint64 deadline,uint8 status,bytes32 leaf)";

const PROTOCOL_ABI = [
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function treasury() view returns (address)",
  "function arbiter() view returns (address)",
  "function pendingArbiter() view returns (address)",
  "function arbiterEta() view returns (uint64)",
  "function paused() view returns (bool)",
  "function reportBond() view returns (uint256)",
  "function datasetCount() view returns (uint256)",
  "function requestCount() view returns (uint256)",
  "function reportCount() view returns (uint256)",
  "function claimable(address) view returns (uint256)",
  "function commitmentBlock(bytes32) view returns (uint256)",
  "function quote(uint256 datasetId, uint32 eps) view returns (uint256)",
  "function providerBondFor(uint256 requestId) view returns (uint256)",
  "function disputeBondFor(uint256 requestId) view returns (uint256)",
  `function getDataset(uint256) view returns (${DATASET})`,
  `function getRequest(uint256) view returns (${REQUEST})`,
  `function getStake(address) view returns (${STAKE})`,
  `function getReport(uint256) view returns (${REPORT})`,
  "function commit(bytes32 commitment)",
  "function listDataset(bytes32 dataHash, bytes32 salt, string metadataURI, uint96 pricePerEps, uint32 epsTotal, uint96 minBuyerStake) returns (uint256)",
  "function updateDataset(uint256 datasetId, uint96 pricePerEps, uint96 minBuyerStake, bool isActive)",
  "function commitResult(uint256 requestId, bytes32 resultHash, bytes32 canaryRoot) payable",
  "function requestCompute(uint256 datasetId, uint32 eps, bytes buyerKey, uint256 maxCost) payable returns (uint256)",
  "function refundUncommitted(uint256 requestId)",
  "function disputeResult(uint256 requestId) payable",
  "function finalize(uint256 requestId)",
  "function expireDispute(uint256 requestId)",
  "function stake() payable",
  "function requestUnstake()",
  "function cancelUnstake()",
  "function unstake()",
  "function reportLeak(uint256 requestId, bytes32 canaryHash, bytes32 salt, bytes32[] proof) payable returns (uint256)",
  "function expireLeak(uint256 reportId)",
  "function withdraw()",
  "function setPaused(bool)",
  "function setTreasury(address)",
  "function proposeArbiter(address)",
  "function executeArbiter()",
  "function transferOwnership(address)",
  "function acceptOwnership()",
  "event ComputeRequested(uint256 indexed requestId, uint256 indexed datasetId, address indexed buyer, uint256 cost, uint32 eps, bytes buyerKey)",
  "event DatasetListed(uint256 indexed datasetId, address indexed provider, bytes32 dataHash, string metadataURI)",
  "error Unauthorized()", "error ContractPaused()", "error Reentrancy()", "error ZeroAddress()", "error ZeroValue()",
  "error InvalidCommitment()", "error HashAlreadyListed()", "error BudgetExhausted()", "error DatasetInactive()",
  "error SelfPurchase()", "error InsufficientStake()", "error StakeLocked()",
  "error SlippageExceeded(uint256 cost, uint256 maxCost)", "error InvalidPayment(uint256 expected, uint256 received)",
  "error InvalidStatus()", "error WindowOpen()", "error WindowClosed()", "error AlreadyReported()",
  "error InvalidProof()", "error TransferFailed()", "error Overflow()",
];

const PROVENANCE_ABI = [
  "function protocol() view returns (address)",
  "function totalSupply() view returns (uint256)",
  "function tokenOfModel(bytes32) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function tokenURI(uint256) view returns (string)",
  "function lineage(uint256) view returns (uint256[] requestIds, uint256[] datasetIds)",
  "function mint(bytes32 modelHash, uint256[] requestIds, string uri) returns (uint256)",
  "error InvalidModelHash()", "error ModelAlreadyRegistered()", "error InvalidLineageLength()",
  "error UnsortedRequestIds()", "error RequestNotEligible(uint256 requestId)", "error NonexistentToken()", "error Soulbound()",
];

const REQUEST_STATUS = ["None", "Pending", "Committed", "Disputed", "Completed", "Refunded"];

module.exports = { PROTOCOL_ABI, PROVENANCE_ABI, REQUEST_STATUS };
