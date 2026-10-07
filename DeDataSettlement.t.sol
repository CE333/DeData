// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeDataProtocol} from "../src/DeDataProtocol.sol";
import {DeDataProvenance} from "../src/DeDataProvenance.sol";

/// @dev Tries to re-enter withdraw() from its receive hook.
contract ReentrantReceiver {
    DeDataProtocol public immutable protocol;
    bool public reentryBlocked;

    constructor(DeDataProtocol p) {
        protocol = p;
    }

    function doWithdraw() external {
        protocol.withdraw();
    }

    receive() external payable {
        try protocol.withdraw() {
            reentryBlocked = false;
        } catch {
            reentryBlocked = true;
        }
    }
}

contract DeDataSettlementTest is Test {
    DeDataProtocol internal protocol;
    DeDataProvenance internal provenance;

    address internal treasury = makeAddr("treasury");
    address internal arbiter = makeAddr("arbiter");
    address internal provider = makeAddr("provider");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant REPORT_BOND = 0.1 ether;
    uint96 internal constant PRICE_PER_EPS = 1e15;
    uint32 internal constant EPS_TOTAL = 100;
    uint96 internal constant MIN_STAKE = 1 ether;
    uint32 internal constant EPS = 10;

    bytes32 internal constant DATA_HASH = keccak256("greenfield://dataset-1");
    bytes32 internal constant SALT = keccak256("salt");
    bytes32 internal constant RESULT_HASH = keccak256("encrypted-result");
    bytes32 internal constant CANARY_ROOT = keccak256("canary-root");
    bytes internal constant BUYER_KEY = hex"04abcdef";

    uint256 internal datasetId;

    function setUp() public {
        protocol = new DeDataProtocol(treasury, arbiter, REPORT_BOND);
        provenance = new DeDataProvenance(address(protocol));

        vm.deal(provider, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(stranger, 100 ether);

        datasetId = _listDataset(provider, DATA_HASH, MIN_STAKE);

        vm.prank(buyer);
        protocol.stake{value: MIN_STAKE}();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _listDataset(address who, bytes32 dataHash, uint96 minStake) internal returns (uint256 id) {
        vm.prank(who);
        protocol.commit(keccak256(abi.encode(who, dataHash, SALT)));
        vm.roll(block.number + 1);
        vm.prank(who);
        id = protocol.listDataset(dataHash, SALT, "ipfs://meta", PRICE_PER_EPS, EPS_TOTAL, minStake);
    }

    function _request(uint32 eps) internal returns (uint256 requestId, uint256 cost) {
        cost = protocol.quote(datasetId, eps);
        vm.prank(buyer);
        requestId = protocol.requestCompute{value: cost}(datasetId, eps, BUYER_KEY, cost);
    }

    function _commit(uint256 requestId) internal returns (uint256 bond) {
        bond = protocol.providerBondFor(requestId);
        vm.prank(provider);
        protocol.commitResult{value: bond}(requestId, RESULT_HASH, CANARY_ROOT);
    }

    function _dispute(uint256 requestId) internal returns (uint256 bond) {
        bond = protocol.disputeBondFor(requestId);
        vm.prank(buyer);
        protocol.disputeResult{value: bond}(requestId);
    }

    function _status(uint256 requestId) internal view returns (DeDataProtocol.RequestStatus) {
        return protocol.getRequest(requestId).status;
    }

    function _fee(uint256 cost) internal view returns (uint256) {
        return (cost * protocol.FEE_BPS()) / protocol.BPS();
    }

    /// @dev Every wei held must be owed to someone: claimables + staked balances.
    function _assertSolvent(uint256 lockedInFlight) internal view {
        uint256 owed = protocol.claimable(provider) + protocol.claimable(buyer) + protocol.claimable(treasury)
            + protocol.claimable(stranger) + protocol.getStake(buyer).amount + lockedInFlight;
        assertEq(address(protocol).balance, owed, "protocol balance != total owed");
    }

    /*//////////////////////////////////////////////////////////////
                    HAPPY PATH: request -> commit -> finalize
    //////////////////////////////////////////////////////////////*/

    function test_HappyPath_Finalize() public {
        (uint256 id, uint256 cost) = _request(EPS);
        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Pending));
        assertEq(protocol.getDataset(datasetId).epsRemaining, EPS_TOTAL - EPS);

        uint256 bond = _commit(id);
        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Committed));
        assertEq(bond, (cost * 2_000) / 10_000);

        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD());
        vm.prank(stranger); // finalize is permissionless
        protocol.finalize(id);

        uint256 fee = _fee(cost);
        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Completed));
        assertEq(protocol.claimable(provider), cost - fee + bond);
        assertEq(protocol.claimable(treasury), fee);
        assertEq(protocol.getDataset(datasetId).totalCompleted, 1);
        _assertSolvent(0);

        uint256 before = provider.balance;
        vm.prank(provider);
        protocol.withdraw();
        assertEq(provider.balance - before, cost - fee + bond);
        assertEq(protocol.claimable(provider), 0);
    }

    function test_Overpayment_IsCreditedToBuyer() public {
        uint256 cost = protocol.quote(datasetId, EPS);
        vm.prank(buyer);
        protocol.requestCompute{value: cost + 1 ether}(datasetId, EPS, BUYER_KEY, cost);
        assertEq(protocol.claimable(buyer), 1 ether);
    }

    function test_Quote_RisesWithScarcity() public {
        (, uint256 first) = _request(EPS);
        (, uint256 second) = _request(EPS);
        assertGt(second, first);
    }

    function test_BudgetExhausted_RetiresDataset() public {
        _request(EPS_TOTAL);
        assertFalse(protocol.getDataset(datasetId).isActive);
        vm.expectRevert(DeDataProtocol.BudgetExhausted.selector);
        protocol.quote(datasetId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                           REQUEST GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SlippageExceeded() public {
        uint256 cost = protocol.quote(datasetId, EPS);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DeDataProtocol.SlippageExceeded.selector, cost, cost - 1));
        protocol.requestCompute{value: cost}(datasetId, EPS, BUYER_KEY, cost - 1);
    }

    function test_RevertWhen_Underpaid() public {
        uint256 cost = protocol.quote(datasetId, EPS);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DeDataProtocol.InvalidPayment.selector, cost, cost - 1));
        protocol.requestCompute{value: cost - 1}(datasetId, EPS, BUYER_KEY, cost);
    }

    function test_RevertWhen_ProviderBuysOwnDataset() public {
        vm.prank(provider);
        protocol.stake{value: MIN_STAKE}();
        uint256 cost = protocol.quote(datasetId, EPS);
        vm.prank(provider);
        vm.expectRevert(DeDataProtocol.SelfPurchase.selector);
        protocol.requestCompute{value: cost}(datasetId, EPS, BUYER_KEY, cost);
    }

    function test_RevertWhen_StakeTooLow() public {
        uint256 cost = protocol.quote(datasetId, EPS);
        vm.prank(stranger);
        vm.expectRevert(DeDataProtocol.InsufficientStake.selector);
        protocol.requestCompute{value: cost}(datasetId, EPS, BUYER_KEY, cost);
    }

    function test_RevertWhen_Paused() public {
        protocol.setPaused(true);
        uint256 cost = protocol.quote(datasetId, EPS);
        vm.prank(buyer);
        vm.expectRevert(DeDataProtocol.ContractPaused.selector);
        protocol.requestCompute{value: cost}(datasetId, EPS, BUYER_KEY, cost);
    }

    /*//////////////////////////////////////////////////////////////
                              COMMIT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonProviderCommits() public {
        (uint256 id,) = _request(EPS);
        uint256 bond = protocol.providerBondFor(id);
        vm.prank(stranger);
        vm.expectRevert(DeDataProtocol.Unauthorized.selector);
        protocol.commitResult{value: bond}(id, RESULT_HASH, CANARY_ROOT);
    }

    function test_RevertWhen_CommitWrongBond() public {
        (uint256 id,) = _request(EPS);
        uint256 bond = protocol.providerBondFor(id);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(DeDataProtocol.InvalidPayment.selector, bond, bond + 1));
        protocol.commitResult{value: bond + 1}(id, RESULT_HASH, CANARY_ROOT);
    }

    function test_RevertWhen_CommitAfterDeadline() public {
        (uint256 id,) = _request(EPS);
        vm.warp(block.timestamp + protocol.COMMIT_WINDOW() + 1);
        uint256 bond = protocol.providerBondFor(id);
        vm.prank(provider);
        vm.expectRevert(DeDataProtocol.WindowClosed.selector);
        protocol.commitResult{value: bond}(id, RESULT_HASH, CANARY_ROOT);
    }

    function test_Commit_AtExactDeadline() public {
        (uint256 id,) = _request(EPS);
        vm.warp(block.timestamp + protocol.COMMIT_WINDOW());
        _commit(id);
        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Committed));
    }

    function test_RevertWhen_CommitTwice() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        uint256 bond = protocol.providerBondFor(id);
        vm.prank(provider);
        vm.expectRevert(DeDataProtocol.InvalidStatus.selector);
        protocol.commitResult{value: bond}(id, RESULT_HASH, CANARY_ROOT);
    }

    function test_RevertWhen_CommitZeroHashes() public {
        (uint256 id,) = _request(EPS);
        uint256 bond = protocol.providerBondFor(id);
        vm.prank(provider);
        vm.expectRevert(DeDataProtocol.ZeroValue.selector);
        protocol.commitResult{value: bond}(id, bytes32(0), CANARY_ROOT);
    }

    /*//////////////////////////////////////////////////////////////
                        REFUND (no commit in time)
    //////////////////////////////////////////////////////////////*/

    function test_RefundUncommitted_RestoresBudget() public {
        (uint256 id, uint256 cost) = _request(EPS);
        vm.warp(block.timestamp + protocol.COMMIT_WINDOW() + 1);

        vm.prank(stranger); // permissionless, but funds go to buyer
        protocol.refundUncommitted(id);

        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Refunded));
        assertEq(protocol.claimable(buyer), cost);
        assertEq(protocol.claimable(stranger), 0);
        assertEq(protocol.getDataset(datasetId).epsRemaining, EPS_TOTAL);
        _assertSolvent(0);
    }

    function test_RevertWhen_RefundBeforeDeadline() public {
        (uint256 id,) = _request(EPS);
        vm.warp(block.timestamp + protocol.COMMIT_WINDOW());
        vm.expectRevert(DeDataProtocol.WindowOpen.selector);
        protocol.refundUncommitted(id);
    }

    function test_RevertWhen_RefundAfterCommit() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        vm.warp(block.timestamp + protocol.COMMIT_WINDOW() + 1);
        vm.expectRevert(DeDataProtocol.InvalidStatus.selector);
        protocol.refundUncommitted(id);
    }

    /*//////////////////////////////////////////////////////////////
                          CHALLENGE WINDOW
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_FinalizeDuringChallenge() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD() - 1);
        vm.expectRevert(DeDataProtocol.WindowOpen.selector);
        protocol.finalize(id);
    }

    /// @dev At exactly challengeDeadline, dispute is closed and finalize is open: no overlap, no gap.
    function test_ChallengeBoundary_NoOverlap() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD());

        uint256 bond = protocol.disputeBondFor(id);
        vm.prank(buyer);
        vm.expectRevert(DeDataProtocol.WindowClosed.selector);
        protocol.disputeResult{value: bond}(id);

        protocol.finalize(id);
        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Completed));
    }

    function test_RevertWhen_FinalizeTwice() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD());
        protocol.finalize(id);
        vm.expectRevert(DeDataProtocol.InvalidStatus.selector);
        protocol.finalize(id);
    }

    function test_RevertWhen_NonBuyerDisputes() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        uint256 bond = protocol.disputeBondFor(id);
        vm.prank(stranger);
        vm.expectRevert(DeDataProtocol.Unauthorized.selector);
        protocol.disputeResult{value: bond}(id);
    }

    function test_RevertWhen_DisputeWrongBond() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        uint256 bond = protocol.disputeBondFor(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DeDataProtocol.InvalidPayment.selector, bond, 0));
        protocol.disputeResult(id);
    }

    /*//////////////////////////////////////////////////////////////
                              DISPUTES
    //////////////////////////////////////////////////////////////*/

    function test_Dispute_ProviderWins_TakesBuyerBond() public {
        (uint256 id, uint256 cost) = _request(EPS);
        uint256 pBond = _commit(id);
        uint256 bBond = _dispute(id);
        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Disputed));

        vm.prank(arbiter);
        protocol.resolveDispute(id, true);

        uint256 fee = _fee(cost);
        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Completed));
        assertEq(protocol.claimable(provider), cost - fee + pBond + bBond);
        assertEq(protocol.claimable(treasury), fee);
        assertEq(protocol.claimable(buyer), 0);
        _assertSolvent(0);
    }

    function test_Dispute_BuyerWins_FullRefundPlusProviderBond() public {
        (uint256 id, uint256 cost) = _request(EPS);
        uint256 pBond = _commit(id);
        uint256 bBond = _dispute(id);

        vm.prank(arbiter);
        protocol.resolveDispute(id, false);

        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Refunded));
        assertEq(protocol.claimable(buyer), cost + bBond + pBond);
        assertEq(protocol.claimable(provider), 0);
        assertEq(protocol.claimable(treasury), 0);
        // budget is intentionally NOT restored: result may already be out
        assertEq(protocol.getDataset(datasetId).epsRemaining, EPS_TOTAL - EPS);
        _assertSolvent(0);
    }

    function test_Dispute_Expired_ReturnsBothBonds() public {
        (uint256 id, uint256 cost) = _request(EPS);
        uint256 pBond = _commit(id);
        uint256 bBond = _dispute(id);

        vm.warp(block.timestamp + protocol.RESOLUTION_WINDOW() + 1);
        vm.prank(stranger);
        protocol.expireDispute(id);

        assertEq(uint8(_status(id)), uint8(DeDataProtocol.RequestStatus.Refunded));
        assertEq(protocol.claimable(buyer), cost + bBond);
        assertEq(protocol.claimable(provider), pBond);
        _assertSolvent(0);
    }

    function test_RevertWhen_ResolveAfterDeadline() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        _dispute(id);
        vm.warp(block.timestamp + protocol.RESOLUTION_WINDOW() + 1);
        vm.prank(arbiter);
        vm.expectRevert(DeDataProtocol.WindowClosed.selector);
        protocol.resolveDispute(id, true);
    }

    function test_RevertWhen_ExpireBeforeDeadline() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        _dispute(id);
        vm.warp(block.timestamp + protocol.RESOLUTION_WINDOW());
        vm.expectRevert(DeDataProtocol.WindowOpen.selector);
        protocol.expireDispute(id);
    }

    function test_RevertWhen_NonArbiterResolves() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        _dispute(id);
        vm.prank(provider);
        vm.expectRevert(DeDataProtocol.Unauthorized.selector);
        protocol.resolveDispute(id, true);
    }

    function test_RevertWhen_FinalizeDisputed() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        _dispute(id);
        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD());
        vm.expectRevert(DeDataProtocol.InvalidStatus.selector);
        protocol.finalize(id);
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_WithdrawNothing() public {
        vm.prank(stranger);
        vm.expectRevert(DeDataProtocol.ZeroValue.selector);
        protocol.withdraw();
    }

    function test_Withdraw_BlocksReentrancy() public {
        ReentrantReceiver attacker = new ReentrantReceiver(protocol);
        // credit the attacker via overpayment refund-style flow: make it the buyer
        vm.deal(address(attacker), 10 ether);
        vm.prank(address(attacker));
        protocol.stake{value: MIN_STAKE}();
        uint256 cost = protocol.quote(datasetId, EPS);
        vm.prank(address(attacker));
        protocol.requestCompute{value: cost + 1 ether}(datasetId, EPS, BUYER_KEY, cost);

        uint256 before = address(attacker).balance;
        attacker.doWithdraw();

        assertTrue(attacker.reentryBlocked(), "re-entry was not blocked");
        assertEq(address(attacker).balance - before, 1 ether, "paid more than once");
        assertEq(protocol.claimable(address(attacker)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                      PROVENANCE (post-settlement)
    //////////////////////////////////////////////////////////////*/

    function test_Provenance_MintAfterCompletion() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD());
        protocol.finalize(id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(buyer);
        uint256 tokenId = provenance.mint(keccak256("model-v1"), ids, "ipfs://model");

        assertEq(provenance.ownerOf(tokenId), buyer);
        assertTrue(provenance.locked(tokenId));
        (, uint256[] memory dsIds) = provenance.lineage(tokenId);
        assertEq(dsIds[0], datasetId);

        vm.prank(buyer);
        vm.expectRevert(DeDataProvenance.Soulbound.selector);
        provenance.transferFrom(buyer, stranger, tokenId);
    }

    function test_RevertWhen_MintOnUnsettledRequest() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DeDataProvenance.RequestNotEligible.selector, id));
        provenance.mint(keccak256("model-v1"), ids, "ipfs://model");
    }

    function test_RevertWhen_MintOnRefundedRequest() public {
        (uint256 id,) = _request(EPS);
        _commit(id);
        _dispute(id);
        vm.prank(arbiter);
        protocol.resolveDispute(id, false);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DeDataProvenance.RequestNotEligible.selector, id));
        provenance.mint(keccak256("model-v1"), ids, "ipfs://model");
    }

    /*//////////////////////////////////////////////////////////////
               KNOWN TRUST ASSUMPTION: provider sock-puppet
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents that the provider (who knows every canary) can open a valid leak report
    ///         through a second account. Only an honest arbiter prevents the slash.
    function test_TrustAssumption_ProviderSockPuppetCanReport() public {
        (uint256 id,) = _request(EPS);

        bytes32 canary = keccak256("canary-0");
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(id, canary))));
        uint256 bond = protocol.providerBondFor(id);
        vm.prank(provider);
        protocol.commitResult{value: bond}(id, RESULT_HASH, leaf); // single-leaf tree: root == leaf
        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD());
        protocol.finalize(id);

        address sock = stranger; // controlled by provider
        vm.prank(sock);
        protocol.commit(keccak256(abi.encode(sock, id, canary, SALT)));
        vm.roll(block.number + 1);
        vm.prank(sock);
        uint256 reportId = protocol.reportLeak{value: REPORT_BOND}(id, canary, SALT, new bytes32[](0));

        vm.prank(arbiter);
        protocol.resolveLeak(reportId, true); // a careless / colluding arbiter

        uint256 slashed = MIN_STAKE;
        uint256 toProvider = (slashed * 5_000) / 10_000;
        uint256 toSock = (slashed * 3_000) / 10_000;
        assertEq(protocol.getStake(buyer).amount, 0);
        assertGe(protocol.claimable(provider), toProvider);
        assertEq(protocol.claimable(sock), toSock + REPORT_BOND);
        // provider side captured 80% of the buyer's stake
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Finalize_ConservesValue(uint32 eps) public {
        eps = uint32(bound(eps, 1, EPS_TOTAL));
        (uint256 id, uint256 cost) = _request(eps);
        uint256 bond = _commit(id);
        vm.warp(block.timestamp + protocol.CHALLENGE_PERIOD());
        protocol.finalize(id);

        assertEq(protocol.claimable(provider) + protocol.claimable(treasury), cost + bond);
        _assertSolvent(0);
    }

    function testFuzz_Dispute_ConservesValue(uint32 eps, bool providerWins) public {
        eps = uint32(bound(eps, 1, EPS_TOTAL));
        (uint256 id, uint256 cost) = _request(eps);
        uint256 pBond = _commit(id);
        uint256 bBond = _dispute(id);

        vm.prank(arbiter);
        protocol.resolveDispute(id, providerWins);

        uint256 total = protocol.claimable(provider) + protocol.claimable(buyer) + protocol.claimable(treasury);
        assertEq(total, cost + pBond + bBond);
        _assertSolvent(0);
    }
}
