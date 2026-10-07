// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DeDataProtocol
/// @author Hossein Amirbeik (SIMURIAX)
/// @notice Compute-to-data marketplace with a priced differential-privacy budget, optimistic result
///         settlement and canary-based leak attribution.
/// @dev Settlement flow:
///      requestCompute -> commitResult -> (challenge window) -> finalize
///                                     \-> disputeResult -> resolveDispute | expireDispute
///      requestCompute -> (no commit before deadline) -> refundUncommitted
///      All value transfers are pull-based through `withdraw`.
contract DeDataProtocol {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum RequestStatus {
        None,
        Pending,
        Committed,
        Disputed,
        Completed,
        Refunded
    }

    enum ReportStatus {
        None,
        Open,
        Upheld,
        Rejected,
        Expired
    }

    struct Dataset {
        address provider;
        bool isActive;
        uint32 epsTotal;
        uint32 epsRemaining;
        uint96 pricePerEps;
        uint96 minBuyerStake;
        uint64 totalCompleted;
        bytes32 dataHash;
        bytes32 metadataHash;
    }

    struct ComputeRequest {
        address buyer;
        uint96 amount;
        uint64 datasetId;
        uint64 commitDeadline;
        uint64 challengeDeadline;
        uint64 disputeDeadline;
        uint96 providerBond;
        uint96 buyerBond;
        uint32 epsSpent;
        RequestStatus status;
        uint96 stakeAtRisk;
        bytes32 buyerKeyHash;
        bytes32 resultHash;
        bytes32 canaryRoot;
    }

    struct BuyerStake {
        uint96 amount;
        uint64 unlockAt;
        uint64 lastPurchaseAt;
        uint32 openReports;
    }

    struct LeakReport {
        address reporter;
        uint64 requestId;
        uint64 deadline;
        ReportStatus status;
        bytes32 leaf;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 250;
    uint256 public constant PROVIDER_BOND_BPS = 2_000;
    uint256 public constant DISPUTE_BOND_BPS = 1_000;
    uint256 public constant SLASH_PROVIDER_BPS = 5_000;
    uint256 public constant SLASH_REPORTER_BPS = 3_000;

    uint256 public constant COMMIT_WINDOW = 2 days;
    uint256 public constant CHALLENGE_PERIOD = 1 days;
    uint256 public constant RESOLUTION_WINDOW = 3 days;
    uint256 public constant STAKE_COOLDOWN = 14 days;
    uint256 public constant LEAK_WATCH_PERIOD = 90 days;
    uint256 public constant ARBITER_TIMELOCK = 2 days;

    uint256 public immutable reportBond;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public treasury;
    address public arbiter;
    address public pendingArbiter;
    uint64 public arbiterEta;
    bool public paused;

    uint256 private _locked = 1;

    uint256 public datasetCount;
    uint256 public requestCount;
    uint256 public reportCount;

    mapping(uint256 => Dataset) private _datasets;
    mapping(uint256 => ComputeRequest) private _requests;
    mapping(uint256 => LeakReport) private _reports;
    mapping(address => BuyerStake) private _stakes;

    mapping(bytes32 => uint256) public commitmentBlock;
    mapping(bytes32 => bool) public isHashListed;
    mapping(uint256 => bool) public isRequestReported;
    mapping(address => uint256) public claimable;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CommitmentRecorded(bytes32 indexed commitment, address indexed account);
    event DatasetListed(uint256 indexed datasetId, address indexed provider, bytes32 dataHash, string metadataURI);
    event DatasetUpdated(uint256 indexed datasetId, uint96 pricePerEps, uint96 minBuyerStake, bool isActive);
    event DatasetRetired(uint256 indexed datasetId);

    event ComputeRequested(
        uint256 indexed requestId,
        uint256 indexed datasetId,
        address indexed buyer,
        uint256 cost,
        uint32 eps,
        bytes buyerKey
    );
    event ResultCommitted(uint256 indexed requestId, bytes32 resultHash, bytes32 canaryRoot, uint256 bond);
    event ResultDisputed(uint256 indexed requestId, uint256 bond);
    event DisputeResolved(uint256 indexed requestId, bool providerWins);
    event DisputeExpired(uint256 indexed requestId);
    event ComputeCompleted(uint256 indexed requestId, address indexed provider, uint256 payout, uint256 fee);
    event ComputeRefunded(uint256 indexed requestId, address indexed buyer, uint256 amount);

    event Staked(address indexed buyer, uint256 amount);
    event UnstakeRequested(address indexed buyer, uint256 unlockAt);
    event UnstakeCancelled(address indexed buyer);
    event Unstaked(address indexed buyer, uint256 amount);

    event LeakReported(
        uint256 indexed reportId, uint256 indexed requestId, address indexed buyer, address reporter, bytes32 leaf
    );
    event LeakResolved(uint256 indexed reportId, bool upheld, uint256 slashed);
    event LeakExpired(uint256 indexed reportId);

    event Withdrawal(address indexed account, uint256 amount);
    event PauseSet(bool paused);
    event TreasurySet(address treasury);
    event ArbiterProposed(address arbiter, uint256 eta);
    event ArbiterSet(address arbiter);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error ContractPaused();
    error Reentrancy();
    error ZeroAddress();
    error ZeroValue();
    error InvalidCommitment();
    error HashAlreadyListed();
    error BudgetExhausted();
    error DatasetInactive();
    error SelfPurchase();
    error InsufficientStake();
    error StakeLocked();
    error SlippageExceeded(uint256 cost, uint256 maxCost);
    error InvalidPayment(uint256 expected, uint256 received);
    error InvalidStatus();
    error WindowOpen();
    error WindowClosed();
    error AlreadyReported();
    error InvalidProof();
    error TransferFailed();
    error Overflow();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param treasury_   Recipient of protocol fees and a share of slashed stake.
    /// @param arbiter_    Dispute and leak resolver. Should be a multisig independent of the owner.
    /// @param reportBond_ Bond required to open a leak report.
    constructor(address treasury_, address arbiter_, uint256 reportBond_) {
        if (treasury_ == address(0) || arbiter_ == address(0)) revert ZeroAddress();
        if (reportBond_ == 0) revert ZeroValue();
        owner = msg.sender;
        treasury = treasury_;
        arbiter = arbiter_;
        reportBond = reportBond_;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              COMMITMENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Records a commitment used by `listDataset` and `reportLeak` to prevent front-running.
    /// @dev Listing:   keccak256(abi.encode(sender, dataHash, salt))
    ///      Reporting: keccak256(abi.encode(sender, requestId, canaryHash, salt))
    function commit(bytes32 commitment) external {
        if (commitment == bytes32(0) || commitmentBlock[commitment] != 0) revert InvalidCommitment();
        commitmentBlock[commitment] = block.number;
        emit CommitmentRecorded(commitment, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               PROVIDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lists a dataset. Requires a prior `commit` in an earlier block.
    /// @param dataHash      Content hash of the dataset object on BNB Greenfield.
    /// @param salt          Salt used in the listing commitment.
    /// @param metadataURI   Off-chain metadata; only its hash is stored.
    /// @param pricePerEps   Base price in wei per privacy-budget unit.
    /// @param epsTotal      Total privacy budget in units.
    /// @param minBuyerStake Stake a buyer must hold, and the amount at risk on a proven leak.
    function listDataset(
        bytes32 dataHash,
        bytes32 salt,
        string calldata metadataURI,
        uint96 pricePerEps,
        uint32 epsTotal,
        uint96 minBuyerStake
    ) external whenNotPaused returns (uint256 datasetId) {
        if (dataHash == bytes32(0) || pricePerEps == 0 || epsTotal == 0) revert ZeroValue();
        if (isHashListed[dataHash]) revert HashAlreadyListed();
        _consumeCommitment(keccak256(abi.encode(msg.sender, dataHash, salt)));

        isHashListed[dataHash] = true;
        datasetId = ++datasetCount;

        Dataset storage d = _datasets[datasetId];
        d.provider = msg.sender;
        d.isActive = true;
        d.epsTotal = epsTotal;
        d.epsRemaining = epsTotal;
        d.pricePerEps = pricePerEps;
        d.minBuyerStake = minBuyerStake;
        d.dataHash = dataHash;
        d.metadataHash = keccak256(bytes(metadataURI));

        emit DatasetListed(datasetId, msg.sender, dataHash, metadataURI);
    }

    /// @notice Updates pricing and availability. Existing requests keep their snapshotted terms.
    function updateDataset(uint256 datasetId, uint96 pricePerEps, uint96 minBuyerStake, bool isActive) external {
        Dataset storage d = _datasets[datasetId];
        if (msg.sender != d.provider) revert Unauthorized();
        if (pricePerEps == 0) revert ZeroValue();
        if (isActive && d.epsRemaining == 0) revert BudgetExhausted();

        d.pricePerEps = pricePerEps;
        d.minBuyerStake = minBuyerStake;
        d.isActive = isActive;

        emit DatasetUpdated(datasetId, pricePerEps, minBuyerStake, isActive);
    }

    /// @notice Commits the result of a pending request. Callable once, by the dataset provider only.
    /// @param resultHash Hash of the encrypted result delivered to the buyer off-chain.
    /// @param canaryRoot Merkle root of the buyer-unique canary records embedded in the result.
    function commitResult(uint256 requestId, bytes32 resultHash, bytes32 canaryRoot) external payable {
        ComputeRequest storage r = _requests[requestId];
        if (r.status != RequestStatus.Pending) revert InvalidStatus();
        if (msg.sender != _datasets[r.datasetId].provider) revert Unauthorized();
        if (block.timestamp > r.commitDeadline) revert WindowClosed();
        if (resultHash == bytes32(0) || canaryRoot == bytes32(0)) revert ZeroValue();

        uint256 bond = providerBondFor(requestId);
        if (msg.value != bond) revert InvalidPayment(bond, msg.value);

        r.status = RequestStatus.Committed;
        r.resultHash = resultHash;
        r.canaryRoot = canaryRoot;
        r.providerBond = uint96(bond);
        r.challengeDeadline = uint64(block.timestamp + CHALLENGE_PERIOD);

        emit ResultCommitted(requestId, resultHash, canaryRoot, bond);
    }

    /*//////////////////////////////////////////////////////////////
                                 BUYERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Purchases `eps` units of privacy budget for a compute job. Excess payment is credited.
    /// @param buyerKey Public key the provider must encrypt the result to.
    /// @param maxCost  Upper bound on the quoted cost, protecting against concurrent price moves.
    function requestCompute(uint256 datasetId, uint32 eps, bytes calldata buyerKey, uint256 maxCost)
        external
        payable
        whenNotPaused
        returns (uint256 requestId)
    {
        if (buyerKey.length == 0) revert ZeroValue();

        uint256 cost = _consumeBudget(datasetId, eps, maxCost);
        requestId = _createRequest(datasetId, eps, cost, keccak256(buyerKey));

        if (msg.value > cost) claimable[msg.sender] += msg.value - cost;

        emit ComputeRequested(requestId, datasetId, msg.sender, cost, eps, buyerKey);
    }

    /// @notice Refunds a request the provider failed to commit in time and restores its budget.
    /// @dev Permissionless; funds are always credited to the buyer.
    function refundUncommitted(uint256 requestId) external {
        ComputeRequest storage r = _requests[requestId];
        if (r.status != RequestStatus.Pending) revert InvalidStatus();
        if (block.timestamp <= r.commitDeadline) revert WindowOpen();

        r.status = RequestStatus.Refunded;
        _datasets[r.datasetId].epsRemaining += r.epsSpent;
        claimable[r.buyer] += r.amount;

        emit ComputeRefunded(requestId, r.buyer, r.amount);
    }

    /// @notice Disputes a committed result within the challenge window.
    function disputeResult(uint256 requestId) external payable {
        ComputeRequest storage r = _requests[requestId];
        if (r.status != RequestStatus.Committed) revert InvalidStatus();
        if (msg.sender != r.buyer) revert Unauthorized();
        if (block.timestamp >= r.challengeDeadline) revert WindowClosed();

        uint256 bond = disputeBondFor(requestId);
        if (msg.value != bond) revert InvalidPayment(bond, msg.value);

        r.status = RequestStatus.Disputed;
        r.buyerBond = uint96(bond);
        r.disputeDeadline = uint64(block.timestamp + RESOLUTION_WINDOW);

        emit ResultDisputed(requestId, bond);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Settles an undisputed result after the challenge window. Permissionless.
    function finalize(uint256 requestId) external {
        ComputeRequest storage r = _requests[requestId];
        if (r.status != RequestStatus.Committed) revert InvalidStatus();
        if (block.timestamp < r.challengeDeadline) revert WindowOpen();
        _complete(requestId, 0);
    }

    /// @notice Resolves a dispute. The losing side forfeits its bond to the winner.
    /// @dev Consumed privacy budget is not restored: the result may already have been released.
    function resolveDispute(uint256 requestId, bool providerWins) external onlyArbiter {
        ComputeRequest storage r = _requests[requestId];
        if (r.status != RequestStatus.Disputed) revert InvalidStatus();
        if (block.timestamp > r.disputeDeadline) revert WindowClosed();

        if (providerWins) {
            _complete(requestId, r.buyerBond);
        } else {
            r.status = RequestStatus.Refunded;
            uint256 total = uint256(r.amount) + r.buyerBond + r.providerBond;
            claimable[r.buyer] += total;
            emit ComputeRefunded(requestId, r.buyer, total);
        }

        emit DisputeResolved(requestId, providerWins);
    }

    /// @notice Unwinds a dispute the arbiter failed to resolve in time. Both bonds are returned.
    function expireDispute(uint256 requestId) external {
        ComputeRequest storage r = _requests[requestId];
        if (r.status != RequestStatus.Disputed) revert InvalidStatus();
        if (block.timestamp <= r.disputeDeadline) revert WindowOpen();

        r.status = RequestStatus.Refunded;
        claimable[r.buyer] += uint256(r.amount) + r.buyerBond;
        claimable[_datasets[r.datasetId].provider] += r.providerBond;

        emit ComputeRefunded(requestId, r.buyer, r.amount);
        emit DisputeExpired(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                              BUYER STAKE
    //////////////////////////////////////////////////////////////*/

    function stake() external payable {
        if (msg.value == 0) revert ZeroValue();
        BuyerStake storage s = _stakes[msg.sender];
        uint256 total = uint256(s.amount) + msg.value;
        if (total > type(uint96).max) revert Overflow();

        s.amount = uint96(total);
        s.unlockAt = 0;

        emit Staked(msg.sender, msg.value);
    }

    function requestUnstake() external {
        BuyerStake storage s = _stakes[msg.sender];
        if (s.amount == 0) revert ZeroValue();
        s.unlockAt = uint64(block.timestamp + STAKE_COOLDOWN);
        emit UnstakeRequested(msg.sender, s.unlockAt);
    }

    function cancelUnstake() external {
        _stakes[msg.sender].unlockAt = 0;
        emit UnstakeCancelled(msg.sender);
    }

    /// @notice Releases stake after the cooldown, the post-purchase watch period and all open reports.
    function unstake() external {
        BuyerStake storage s = _stakes[msg.sender];
        if (s.unlockAt == 0 || block.timestamp < s.unlockAt) revert StakeLocked();
        if (block.timestamp < uint256(s.lastPurchaseAt) + LEAK_WATCH_PERIOD) revert StakeLocked();
        if (s.openReports != 0) revert StakeLocked();

        uint256 amount = s.amount;
        if (amount == 0) revert ZeroValue();
        s.amount = 0;
        s.unlockAt = 0;
        claimable[msg.sender] += amount;

        emit Unstaked(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             LEAK REPORTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Attributes a leaked canary to a request. Requires a prior `commit` in an earlier block.
    /// @dev leaf = keccak256(bytes.concat(keccak256(abi.encode(requestId, canaryHash)))),
    ///      verified against `canaryRoot` with sorted-pair hashing.
    function reportLeak(uint256 requestId, bytes32 canaryHash, bytes32 salt, bytes32[] calldata proof)
        external
        payable
        returns (uint256 reportId)
    {
        if (msg.value != reportBond) revert InvalidPayment(reportBond, msg.value);

        ComputeRequest storage r = _requests[requestId];
        if (r.canaryRoot == bytes32(0) || r.stakeAtRisk == 0) revert InvalidStatus();
        if (isRequestReported[requestId]) revert AlreadyReported();

        _consumeCommitment(keccak256(abi.encode(msg.sender, requestId, canaryHash, salt)));

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(requestId, canaryHash))));
        if (!_verifyProof(proof, r.canaryRoot, leaf)) revert InvalidProof();

        isRequestReported[requestId] = true;
        _stakes[r.buyer].openReports++;

        reportId = ++reportCount;
        LeakReport storage rep = _reports[reportId];
        rep.reporter = msg.sender;
        rep.requestId = uint64(requestId);
        rep.deadline = uint64(block.timestamp + RESOLUTION_WINDOW);
        rep.status = ReportStatus.Open;
        rep.leaf = leaf;

        emit LeakReported(reportId, requestId, r.buyer, msg.sender, leaf);
    }

    /// @notice Confirms or rejects a leak report based on off-chain evidence.
    /// @dev Upheld: buyer stake is slashed up to `stakeAtRisk` and split between provider, reporter
    ///      and treasury. Rejected: the report bond compensates the buyer.
    function resolveLeak(uint256 reportId, bool upheld) external onlyArbiter {
        LeakReport storage rep = _reports[reportId];
        if (rep.status != ReportStatus.Open) revert InvalidStatus();
        if (block.timestamp > rep.deadline) revert WindowClosed();

        ComputeRequest storage r = _requests[rep.requestId];
        BuyerStake storage s = _stakes[r.buyer];
        s.openReports--;

        uint256 slashed;
        if (upheld) {
            rep.status = ReportStatus.Upheld;
            slashed = r.stakeAtRisk < s.amount ? r.stakeAtRisk : s.amount;
            s.amount -= uint96(slashed);

            uint256 toProvider = (slashed * SLASH_PROVIDER_BPS) / BPS;
            uint256 toReporter = (slashed * SLASH_REPORTER_BPS) / BPS;
            claimable[_datasets[r.datasetId].provider] += toProvider;
            claimable[rep.reporter] += toReporter + reportBond;
            claimable[treasury] += slashed - toProvider - toReporter;
        } else {
            rep.status = ReportStatus.Rejected;
            isRequestReported[rep.requestId] = false;
            claimable[r.buyer] += reportBond;
        }

        emit LeakResolved(reportId, upheld, slashed);
    }

    /// @notice Closes a report the arbiter failed to resolve in time and returns the bond.
    function expireLeak(uint256 reportId) external {
        LeakReport storage rep = _reports[reportId];
        if (rep.status != ReportStatus.Open) revert InvalidStatus();
        if (block.timestamp <= rep.deadline) revert WindowOpen();

        rep.status = ReportStatus.Expired;
        isRequestReported[rep.requestId] = false;
        _stakes[_requests[rep.requestId].buyer].openReports--;
        claimable[rep.reporter] += reportBond;

        emit LeakExpired(reportId);
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function withdraw() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert ZeroValue();
        claimable[msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawal(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Pausing blocks new listings and purchases only. Settlement paths stay available.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseSet(paused_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function proposeArbiter(address arbiter_) external onlyOwner {
        if (arbiter_ == address(0)) revert ZeroAddress();
        pendingArbiter = arbiter_;
        arbiterEta = uint64(block.timestamp + ARBITER_TIMELOCK);
        emit ArbiterProposed(arbiter_, arbiterEta);
    }

    function executeArbiter() external onlyOwner {
        address next = pendingArbiter;
        if (next == address(0)) revert ZeroAddress();
        if (block.timestamp < arbiterEta) revert WindowOpen();

        arbiter = next;
        pendingArbiter = address(0);
        arbiterEta = 0;

        emit ArbiterSet(next);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Cost of consuming `eps` budget units at the current scarcity level.
    /// @dev cost = pricePerEps * eps * epsTotal / mean(remainingBefore, remainingAfter)
    function quote(uint256 datasetId, uint32 eps) public view returns (uint256) {
        Dataset storage d = _datasets[datasetId];
        if (eps == 0 || eps > d.epsRemaining) revert BudgetExhausted();
        uint256 remainingBefore = d.epsRemaining;
        uint256 remainingAfter = remainingBefore - eps;
        return (uint256(d.pricePerEps) * eps * d.epsTotal * 2) / (remainingBefore + remainingAfter);
    }

    function providerBondFor(uint256 requestId) public view returns (uint256) {
        return (uint256(_requests[requestId].amount) * PROVIDER_BOND_BPS) / BPS;
    }

    function disputeBondFor(uint256 requestId) public view returns (uint256) {
        return (uint256(_requests[requestId].amount) * DISPUTE_BOND_BPS) / BPS;
    }

    function getDataset(uint256 datasetId) external view returns (Dataset memory) {
        return _datasets[datasetId];
    }

    function getRequest(uint256 requestId) external view returns (ComputeRequest memory) {
        return _requests[requestId];
    }

    function getReport(uint256 reportId) external view returns (LeakReport memory) {
        return _reports[reportId];
    }

    function getStake(address buyer) external view returns (BuyerStake memory) {
        return _stakes[buyer];
    }

    /// @notice Lightweight accessor used by DeDataProvenance.
    function requestSummary(uint256 requestId)
        external
        view
        returns (address buyer, uint256 datasetId, bool completed)
    {
        ComputeRequest storage r = _requests[requestId];
        return (r.buyer, r.datasetId, r.status == RequestStatus.Completed);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _consumeCommitment(bytes32 commitment) private {
        uint256 recordedAt = commitmentBlock[commitment];
        if (recordedAt == 0 || recordedAt >= block.number) revert InvalidCommitment();
        delete commitmentBlock[commitment];
    }

    function _consumeBudget(uint256 datasetId, uint32 eps, uint256 maxCost) private returns (uint256 cost) {
        Dataset storage d = _datasets[datasetId];
        if (!d.isActive) revert DatasetInactive();
        if (msg.sender == d.provider) revert SelfPurchase();

        BuyerStake storage s = _stakes[msg.sender];
        if (s.unlockAt != 0) revert StakeLocked();
        if (s.amount < d.minBuyerStake) revert InsufficientStake();
        s.lastPurchaseAt = uint64(block.timestamp);

        cost = quote(datasetId, eps);
        if (cost == 0 || cost > type(uint96).max) revert Overflow();
        if (cost > maxCost) revert SlippageExceeded(cost, maxCost);
        if (msg.value < cost) revert InvalidPayment(cost, msg.value);

        d.epsRemaining -= eps;
        if (d.epsRemaining == 0) {
            d.isActive = false;
            emit DatasetRetired(datasetId);
        }
    }

    function _createRequest(uint256 datasetId, uint32 eps, uint256 cost, bytes32 keyHash)
        private
        returns (uint256 requestId)
    {
        requestId = ++requestCount;
        ComputeRequest storage r = _requests[requestId];
        r.buyer = msg.sender;
        r.amount = uint96(cost);
        r.datasetId = uint64(datasetId);
        r.epsSpent = eps;
        r.status = RequestStatus.Pending;
        r.commitDeadline = uint64(block.timestamp + COMMIT_WINDOW);
        r.stakeAtRisk = _datasets[datasetId].minBuyerStake;
        r.buyerKeyHash = keyHash;
    }

    function _complete(uint256 requestId, uint256 bonus) private {
        ComputeRequest storage r = _requests[requestId];
        Dataset storage d = _datasets[r.datasetId];

        r.status = RequestStatus.Completed;
        d.totalCompleted++;

        uint256 fee = (uint256(r.amount) * FEE_BPS) / BPS;
        uint256 payout = uint256(r.amount) - fee;
        claimable[d.provider] += payout + r.providerBond + bonus;
        claimable[treasury] += fee;

        emit ComputeCompleted(requestId, d.provider, payout, fee);
    }

    function _verifyProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool) {
        bytes32 node = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            node = node < sibling
                ? keccak256(abi.encodePacked(node, sibling))
                : keccak256(abi.encodePacked(sibling, node));
        }
        return node == root;
    }
}
