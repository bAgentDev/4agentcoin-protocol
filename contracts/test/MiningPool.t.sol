// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {MockIdentityVerifier, LocalTaskSolver} from "./Mocks.sol";

contract MiningPoolTest is Test {
    GenesisMiner genesis;
    FourAgentCoin token;
    MiningPool pool;
    MockIdentityVerifier identity;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address fees = makeAddr("fees");
    address lp = makeAddr("lp");
    function setUp() public {
        identity = new MockIdentityVerifier();
        genesis = new GenesisMiner(GenesisMiner.Config(address(this), address(identity), "ipfs://local"));
        token = new FourAgentCoin(lp, fees);
        pool = new MiningPool(address(genesis), address(token), fees, 2.1 ether);
        genesis.setMiningPool(address(pool));
        token.setMiningPool(address(pool));
        genesis.transferFrom(address(this), alice, 0);
        genesis.transferFrom(address(this), alice, 1);
        identity.setEligible(alice, true);
        identity.setAgentId(alice, keccak256("alice-agent"));
        vm.prank(alice);
        genesis.setApprovalForAll(address(pool), true);
        vm.deal(alice, 100 ether);
    }
    function _ids(uint256 id) internal pure returns (uint256[] memory ids) { ids = new uint256[](1); ids[0] = id; }
    function _open() internal { genesis.setStakingOpen(true); pool.setMiningOpen(true); }
    function _stake(uint256 id) internal { vm.prank(alice); pool.stake(_ids(id)); }
    function _solution(uint256 id) internal view returns (uint256 nonce, uint256 answer) {
        uint16[] memory edges;
        (, nonce,, edges) = pool.getTask(id);
        answer = LocalTaskSolver.solve(edges);
    }
    function _solve(uint256 id) internal {
        (uint256 nonce, uint256 answer) = _solution(id);
        vm.prank(alice);
        pool.submitTask(id, nonce, answer, 0);
    }
    function testDefaultsRequireManualOpeningAndStakeAloneDoesNotEarn() public {
        assertFalse(genesis.stakingOpen());
        assertFalse(pool.miningOpen());
        vm.prank(alice);
        vm.expectRevert(MiningPool.MiningClosed.selector);
        pool.stake(_ids(0));
        _open(); _stake(0);
        vm.warp(block.timestamp + 365 days);
        assertEq(token.balanceOf(alice), 0);
        assertEq(pool.totalSolved(), 0);
        assertEq(genesis.ownerOf(0), alice);
        assertTrue(genesis.isStaked(0));
        assertEq(pool.stakeAgentId(0), keccak256("alice-agent"));
    }
    function testSuccessfulTaskMintsAtomicNetAndFeeThenFreshTask() public {
        _open(); _stake(0);
        bytes32 oldSeed = pool.taskSeed(0);
        uint256 oldNonce = pool.taskNonce(0);
        (uint256 gross, uint256 fee, uint256 net, uint256 era) = pool.previewReward(0);
        assertEq(gross, 2.1 ether);
        assertEq(fee, 0.063 ether);
        assertEq(era, 0);
        _solve(0);
        assertEq(token.balanceOf(alice), net);
        assertEq(token.balanceOf(fees), fee);
        assertEq(token.balanceOf(lp), token.LP_ALLOCATION());
        assertEq(token.totalSupply(), token.LP_ALLOCATION() + gross);
        assertEq(token.miningMinted(), gross);
        assertEq(pool.totalGrossMined(), gross);
        assertEq(pool.totalSolved(), 1);
        assertEq(pool.completedTasks(alice), 1);
        assertEq(pool.netEarned(alice), net);
        assertEq(pool.taskNonce(0), oldNonce + 1);
        assertNotEq(pool.taskSeed(0), oldSeed);
        vm.expectRevert(FourAgentCoin.MiningPoolLocked.selector);
        token.setMiningPool(address(pool));
    }
    function testWrongAnswerReplayAndSameBlockFailWithoutReward() public {
        _open(); _stake(0);
        (uint256 nonce, uint256 answer) = _solution(0);
        vm.prank(alice);
        vm.expectRevert(MiningPool.InvalidAnswer.selector);
        pool.submitTask(0, nonce, answer | (1 << 32), 0);
        assertEq(pool.taskNonce(0), nonce);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(bob);
        vm.expectRevert(MiningPool.NotStaker.selector);
        pool.submitTask(0, nonce, answer, 0);
        _solve(0);
        vm.prank(alice);
        vm.expectRevert(MiningPool.StaleTask.selector);
        pool.submitTask(0, nonce, answer, 0);
        (nonce, answer) = _solution(0);
        vm.prank(alice);
        vm.expectRevert(MiningPool.SameBlock.selector);
        pool.submitTask(0, nonce, answer, 0);
        vm.roll(block.number + 1);
        _solve(0);
        assertEq(pool.totalSolved(), 2);
    }
    function testTasksHaveNoTimeExpiryDistinctNFTsAndUnstakeInvalidatePriorTask() public {
        _open();
        uint256[] memory ids = new uint256[](2); ids[0] = 0; ids[1] = 1;
        vm.prank(alice); pool.stake(ids);
        assertNotEq(pool.taskSeed(0), pool.taskSeed(1));
        (uint256 oldNonce, uint256 oldAnswer) = _solution(0);
        vm.warp(block.timestamp + 10 * 365 days);
        _solve(1);
        vm.prank(alice); pool.unstake(_ids(0));
        assertEq(pool.taskNonce(0), oldNonce + 1);
        _stake(0);
        vm.prank(alice);
        vm.expectRevert(MiningPool.StaleTask.selector);
        pool.submitTask(0, oldNonce, oldAnswer, 0);
        _solve(0);
        assertEq(pool.totalSolved(), 2);
    }
    function testRevokedOrChangedIdentityOnlyBlocksNewStakeAndAnswersNeverExitOrHistory() public {
        _open(); _stake(0); _solve(0);
        uint256 earned = token.balanceOf(alice);
        identity.setEligible(alice, false);
        vm.prank(alice); vm.expectRevert(MiningPool.NotEligible.selector); pool.stake(_ids(1));
        vm.roll(block.number + 1);
        (uint256 nonce, uint256 answer) = _solution(0);
        vm.prank(alice); vm.expectRevert(MiningPool.NotEligible.selector); pool.submitTask(0, nonce, answer, 0);
        identity.setEligible(alice, true);
        identity.setAgentId(alice, keccak256("changed"));
        vm.prank(alice); vm.expectRevert(MiningPool.IdentityChanged.selector); pool.submitTask(0, nonce, answer, 0);
        identity.setFail(true);
        vm.prank(alice); vm.expectRevert(MiningPool.IdentityUnavailable.selector); pool.stake(_ids(1));
        pool.setMiningOpen(false); genesis.setStakingOpen(false);
        vm.prank(alice); pool.unstake(_ids(0));
        assertFalse(genesis.isStaked(0));
        assertEq(token.balanceOf(alice), earned);
        assertEq(pool.netEarned(alice), earned);
        vm.prank(alice); token.transfer(bob, earned);
        assertEq(token.balanceOf(bob), earned);
        vm.prank(alice); genesis.transferFrom(alice, bob, 0);
        assertEq(genesis.ownerOf(0), bob);
    }
    function testMinimumQuoteRollsBackEverything() public {
        _open(); _stake(0);
        (uint256 nonce, uint256 answer) = _solution(0);
        vm.prank(alice); vm.expectRevert(MiningPool.RewardBelowMinimum.selector);
        pool.submitTask(0, nonce, answer, 2.1 ether + 1);
        assertEq(pool.taskNonce(0), nonce);
        assertEq(pool.totalGrossMined(), 0);
        assertEq(token.miningMinted(), 0);
    }
    function testPublicHPWeightsOnlyReward() public {
        genesis.setMintOpen(true);
        vm.prank(alice); uint256 id = genesis.mint{value: 0.0021 ether}(bytes32(0));
        _open(); _stake(0); _stake(id);
        (uint256 gross,,,) = pool.previewReward(id);
        uint256 hp = genesis.getToken(id).power;
        assertEq(gross, uint256(2.1 ether) * hp / 150_000_000);
        _solve(0); _solve(id);
        assertEq(pool.completedTasks(alice), 2);
        assertEq(pool.totalGrossMined(), 2.1 ether + gross);
    }
    function testStageCrossingUsesPreSubmitEraAndNextQuoteHalves() public {
        MiningPool high = new MiningPool(address(genesis), address(token), fees, token.MINING_ALLOCATION() / 2 + 1);
        genesis.setMiningPool(address(high)); token.setMiningPool(address(high));
        genesis.setStakingOpen(true); high.setMiningOpen(true);
        vm.startPrank(alice);
        genesis.setApprovalForAll(address(high), true); high.stake(_ids(0));
        (,uint256 nonce,,uint16[] memory edges) = high.getTask(0);
        high.submitTask(0, nonce, LocalTaskSolver.solve(edges), 0);
        vm.stopPrank();
        assertEq(high.currentEra(), 1);
        assertEq(high.currentBaseReward(), high.initialBaseReward() >> 1);
        assertEq(high.totalGrossMined(), high.initialBaseReward());
        (uint256 nextGross,,,uint256 era) = high.previewReward(0);
        assertEq(nextGross, high.initialBaseReward() >> 1); assertEq(era, 1);
    }
    function testExtremeRewardStrictCapAndNoFurtherMint() public {
        genesis.setMintOpen(true);
        uint256 expectedId = genesis.totalAllocated();
        uint256 saltWord;
        while (uint256(keccak256(abi.encode("GENESIS_MINT_POWER_V1", bytes32(saltWord), blockhash(block.number - 1), expectedId, keccak256("alice-agent"), uint256(0), block.chainid, address(genesis)))) % (1e18 + 1) < 8e17) ++saltWord;
        vm.prank(alice); uint256 id = genesis.mint{value: 0.0021 ether}(bytes32(saltWord));
        assertGt(genesis.getToken(id).power, 150_000_000);
        MiningPool high = new MiningPool(address(genesis), address(token), fees, token.MINING_ALLOCATION());
        genesis.setMiningPool(address(high)); token.setMiningPool(address(high));
        genesis.setStakingOpen(true); high.setMiningOpen(true);
        vm.startPrank(alice);
        genesis.setApprovalForAll(address(high), true); high.stake(_ids(id));
        (,uint256 nonce,,uint16[] memory edges) = high.getTask(id);
        high.submitTask(id, nonce, LocalTaskSolver.solve(edges), 0);
        vm.stopPrank();
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(high.totalGrossMined(), token.MINING_ALLOCATION());
        vm.roll(block.number + 1);
        (,nonce,,edges) = high.getTask(id);
        vm.prank(alice); vm.expectRevert(MiningPool.MiningExhausted.selector);
        high.submitTask(id, nonce, LocalTaskSolver.solve(edges), 0);
        vm.prank(alice); high.unstake(_ids(id));
        assertFalse(genesis.isStaked(id));
    }
    function testMissingAgentIdFailsClosedWithoutWalletFallback() public {
        _open();
        identity.setAgentId(alice, bytes32(0));
        vm.prank(alice); vm.expectRevert(MiningPool.IdentityUnavailable.selector); pool.stake(_ids(0));
        identity.setAgentId(alice, keccak256("alice-agent"));
        _stake(0);
        identity.setFailAgentId(true);
        (uint256 nonce, uint256 answer) = _solution(0);
        vm.prank(alice); vm.expectRevert(MiningPool.IdentityUnavailable.selector); pool.submitTask(0, nonce, answer, 0);
        vm.prank(alice); pool.unstake(_ids(0));
        assertFalse(genesis.isStaked(0));
    }
    function testBatchStakeFailureRollsBackAllLocksAndTasks() public {
        _open();
        uint256[] memory ids = new uint256[](2); ids[0] = 0; ids[1] = 0;
        vm.prank(alice); vm.expectRevert(MiningPool.AlreadyStaked.selector); pool.stake(ids);
        assertFalse(genesis.isStaked(0));
        assertEq(pool.taskNonce(0), 0);
        assertEq(pool.stakedBy(0), address(0));
    }

}
