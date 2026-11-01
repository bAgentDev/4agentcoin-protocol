// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MockIdentityVerifier, LocalTaskSolver} from "./Mocks.sol";

/// @custom:oz-upgrades-from src/GenesisMiner.sol:GenesisMiner
/// @dev Appended marker starts at zero and uses an owner setter; no new initialization is needed.
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract GenesisMinerV2 is GenesisMiner {
    uint256 public upgradeMarker;
    function setUpgradeMarker(uint256 marker) external onlyOwner { upgradeMarker = marker; }
    function version() external pure returns (uint256) { return 2; }
}

/// @custom:oz-upgrades-from src/MiningPool.sol:MiningPool
/// @dev Appended marker starts at zero and uses an owner setter; no new initialization is needed.
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract MiningPoolV2 is MiningPool {
    uint256 public upgradeMarker;
    function setUpgradeMarker(uint256 marker) external onlyOwner { upgradeMarker = marker; }
    function version() external pure returns (uint256) { return 2; }
}

contract NonUUPSImplementation {}

contract WrongUUIDImplementation {
    function proxiableUUID() external pure returns (bytes32) { return bytes32(0); }
}

contract UpgradeabilityTest is Test {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant AGENT_ID = keccak256("upgrade-alice-agent");
    uint256 private constant PRICE = 0.0021 ether;
    GenesisMiner private genesis;
    MiningPool private pool;
    GenesisMiner private genesisImplementation;
    MiningPool private poolImplementation;
    FourAgentCoin private token;
    MockIdentityVerifier private identity;
    address private alice = makeAddr("upgrade-alice");
    address private bob = makeAddr("upgrade-bob");
    address private fees = makeAddr("upgrade-fees");
    address private lp = makeAddr("upgrade-lp");

    function setUp() public {
        identity = new MockIdentityVerifier();
        genesisImplementation = new GenesisMiner();
        genesis = GenesisMiner(address(new ERC1967Proxy(address(genesisImplementation), abi.encodeCall(GenesisMiner.initialize, (_config(), address(this))))));
        token = new FourAgentCoin(lp, fees);
        poolImplementation = new MiningPool();
        pool = MiningPool(address(new ERC1967Proxy(address(poolImplementation), abi.encodeCall(MiningPool.initialize, (address(genesis), address(token), fees, 2.1 ether, address(this))))));
        genesis.setMiningPool(address(pool));
        token.setMiningPool(address(pool));
        identity.setEligible(alice, true);
        identity.setAgentId(alice, AGENT_ID);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _config() private view returns (GenesisMiner.Config memory) {
        return GenesisMiner.Config(address(this), address(identity), "ipfs://upgrade-regression.png");
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _solve(uint256 id) private {
        (, uint256 nonce,, uint16[] memory edges) = pool.getTask(id);
        vm.prank(alice);
        pool.submitTask(id, nonce, LocalTaskSolver.solve(edges), 0);
    }

    // Test-only predictable salts force a real collision before/after upgrade, exercising the private uniqueness map.
    function _minimumPowerSalt(uint256 tokenId) private view returns (bytes32) {
        for (uint256 word;; ++word) {
            bytes32 salt = bytes32(word);
            uint256 u = uint256(keccak256(abi.encode("GENESIS_MINT_POWER_V1", salt, blockhash(block.number - 1), tokenId, AGENT_ID, uint256(0), block.chainid, address(genesis)))) % (1e18 + 1);
            // Even the largest 10% boost maps this interval to exactly MIN_POWER after integer rounding.
            if (u <= 60_000_000_000_000) return salt;
        }
        revert("unreachable");
    }

    function _upgrade() private returns (GenesisMinerV2 nextGenesis, MiningPoolV2 nextPool) {
        nextGenesis = new GenesisMinerV2();
        nextPool = new MiningPoolV2();
        genesis.upgradeToAndCall(address(nextGenesis), "");
        pool.upgradeToAndCall(address(nextPool), "");
        assertEq(address(uint160(uint256(vm.load(address(genesis), IMPLEMENTATION_SLOT)))), address(nextGenesis));
        assertEq(address(uint160(uint256(vm.load(address(pool), IMPLEMENTATION_SLOT)))), address(nextPool));
    }

    function testProxyConstructionInitializesReserveAndOrdinaryOwnerExactlyOnce() public {
        assertEq(genesis.owner(), address(this));
        assertEq(pool.owner(), address(this));
        assertFalse(identity.eligible(address(this)));
        assertEq(genesis.balanceOf(address(this)), 2100);
        assertEq(genesis.ownerOf(0), address(this));
        assertEq(genesis.ownerOf(2099), address(this));
        assertEq(genesis.getToken(0).power, 150_000_000);
        assertEq(genesis.reserveRecipient(), address(this));
        assertEq(genesis.totalAllocated(), 2100);
        assertFalse(genesis.mintOpen());
        assertFalse(genesis.stakingOpen());
        assertFalse(pool.miningOpen());
        assertEq(address(pool.genesis()), address(genesis));
        assertEq(address(pool.token()), address(token));
        assertEq(pool.initialBaseReward(), 2.1 ether);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        genesis.initialize(_config(), bob);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(address(genesis), address(token), bob, 1 ether, bob);
    }

    function testImplementationsAreLockedAndProxyRejectsMissingAtomicInitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        genesisImplementation.initialize(_config(), alice);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        poolImplementation.initialize(address(genesis), address(token), fees, 2.1 ether, alice);
        vm.expectRevert(ERC1967Proxy.ERC1967ProxyUninitialized.selector);
        new ERC1967Proxy(address(genesisImplementation), "");
        vm.expectRevert(ERC1967Proxy.ERC1967ProxyUninitialized.selector);
        new ERC1967Proxy(address(poolImplementation), "");
        assertEq(genesisImplementation.owner(), address(0));
        assertEq(poolImplementation.owner(), address(0));
    }

    function testZeroOwnerIsRejectedByBothAtomicInitializers() public {
        bytes memory genesisData = abi.encodeCall(GenesisMiner.initialize, (_config(), address(0)));
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new ERC1967Proxy(address(genesisImplementation), genesisData);
        bytes memory poolData = abi.encodeCall(MiningPool.initialize, (address(genesis), address(token), fees, 2.1 ether, address(0)));
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new ERC1967Proxy(address(poolImplementation), poolData);
    }

    function testUpgradeRejectsUnauthorizedNonUUPSAndWrongUUIDAndWrongCallContext() public {
        GenesisMinerV2 nextGenesis = new GenesisMinerV2();
        MiningPoolV2 nextPool = new MiningPoolV2();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        genesis.upgradeToAndCall(address(nextGenesis), "");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        pool.upgradeToAndCall(address(nextPool), "");
        NonUUPSImplementation nonUUPS = new NonUUPSImplementation();
        vm.expectRevert(abi.encodeWithSignature("ERC1967InvalidImplementation(address)", address(nonUUPS)));
        genesis.upgradeToAndCall(address(nonUUPS), "");
        vm.expectRevert(abi.encodeWithSignature("ERC1967InvalidImplementation(address)", address(nonUUPS)));
        pool.upgradeToAndCall(address(nonUUPS), "");
        WrongUUIDImplementation wrongUUID = new WrongUUIDImplementation();
        vm.expectRevert(abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, bytes32(0)));
        genesis.upgradeToAndCall(address(wrongUUID), "");
        vm.expectRevert(abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, bytes32(0)));
        pool.upgradeToAndCall(address(wrongUUID), "");
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        genesisImplementation.upgradeToAndCall(address(nextGenesis), "");
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        poolImplementation.upgradeToAndCall(address(nextPool), "");
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        genesis.proxiableUUID();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        pool.proxiableUUID();
        assertEq(genesisImplementation.proxiableUUID(), IMPLEMENTATION_SLOT);
        assertEq(poolImplementation.proxiableUUID(), IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(vm.load(address(genesis), IMPLEMENTATION_SLOT)))), address(genesisImplementation));
        assertEq(address(uint160(uint256(vm.load(address(pool), IMPLEMENTATION_SLOT)))), address(poolImplementation));
    }

    function testTwoStepOwnershipAndPendingOwnerSurviveUpgradeAndControlLaterUpgrades() public {
        GenesisMinerV2 firstGenesis = new GenesisMinerV2();
        MiningPoolV2 firstPool = new MiningPoolV2();
        genesis.transferOwnership(bob);
        pool.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        genesis.upgradeToAndCall(address(firstGenesis), "");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        pool.upgradeToAndCall(address(firstPool), "");
        genesis.upgradeToAndCall(address(firstGenesis), "");
        pool.upgradeToAndCall(address(firstPool), "");
        assertEq(genesis.pendingOwner(), bob);
        assertEq(pool.pendingOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        genesis.acceptOwnership();
        vm.prank(bob); genesis.acceptOwnership();
        vm.prank(bob); pool.acceptOwnership();
        GenesisMinerV2 secondGenesis = new GenesisMinerV2();
        MiningPoolV2 secondPool = new MiningPoolV2();
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        genesis.upgradeToAndCall(address(secondGenesis), "");
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        pool.upgradeToAndCall(address(secondPool), "");
        vm.prank(bob); genesis.upgradeToAndCall(address(secondGenesis), "");
        vm.prank(bob); pool.upgradeToAndCall(address(secondPool), "");
        assertEq(genesis.owner(), bob);
        assertEq(pool.owner(), bob);
        assertEq(genesis.pendingOwner(), address(0));
        assertEq(pool.pendingOwner(), address(0));
    }

    function _prepareActiveBusiness() private {
        genesis.setMintOpen(true);
        genesis.setStakingOpen(true);
        pool.setMiningOpen(true);
        for (uint256 i; i < 4; ++i) genesis.transferFrom(address(this), alice, i);
        bytes32 salt = _minimumPowerSalt(2100);
        vm.prank(alice); genesis.mintBatch{value: PRICE * 11}(11, salt);
        assertEq(genesis.getToken(2100).power, genesis.MIN_POWER());
        vm.prank(alice); genesis.setApprovalForAll(address(pool), true);
        vm.prank(alice); genesis.approve(bob, 3);
        vm.prank(alice); genesis.list(1, 1 ether);
        vm.prank(bob); genesis.buy{value: 1 ether}(1, 1, 1 ether);
        vm.prank(alice); genesis.list(2, 2 ether);
        vm.prank(alice); genesis.list(3, 3 ether);
        genesis.withdrawSaleRevenue(payable(lp), 0.001 ether, true);
        genesis.withdrawSaleRevenue(payable(fees), 0.002 ether, false);
        genesis.withdrawMarketFees(payable(fees), 0.01 ether);
        vm.prank(alice); pool.stake(_ids(0));
        vm.prank(alice); pool.stake(_ids(2100));
        _solve(0);
    }

    function _genesisState() private view returns (bytes32) {
        (GenesisMiner.MarketListing[] memory listings, uint256 total) = genesis.getActiveListings(0, 100);
        bytes32 configuration = keccak256(abi.encode(genesis.owner(), genesis.pendingOwner(), genesis.reserveRecipient(), genesis.identityVerifier(), genesis.miningPool(), genesis.mintOpen(), genesis.stakingOpen(), genesis.name(), genesis.symbol()));
        bytes32 accounting = keccak256(abi.encode(genesis.totalAllocated(), genesis.totalSupply(), genesis.publicMinted(), genesis.saleRevenue(), genesis.liquidityWithdrawn(), genesis.operationsWithdrawn(), genesis.marketFeeBalance(), address(genesis).balance, genesis.totalStakeLocks(), genesis.balanceOf(alice), genesis.balanceOf(bob), genesis.balanceOf(address(this))));
        bytes32 tokens = keccak256(abi.encode(genesis.getToken(0), genesis.getToken(1), genesis.getToken(2100), genesis.tokenURI(0), genesis.tokenURI(2100), genesis.stakedOwner(0), genesis.stakedOwner(2100), genesis.getApproved(3), genesis.isApprovedForAll(alice, address(pool))));
        bytes32 mints;
        for (uint256 id = 2100; id < 2111; ++id) mints = keccak256(abi.encode(mints, genesis.getToken(id), genesis.mintOriginAgentId(id), genesis.mintBonusBps(id)));
        return keccak256(abi.encode(configuration, accounting, tokens, mints, genesis.mintedByAgent(AGENT_ID), listings, total, genesis.getListing(2), genesis.getListing(3)));
    }

    function _poolState() private view returns (bytes32) {
        bytes32 configuration = keccak256(abi.encode(pool.owner(), pool.pendingOwner(), address(pool.genesis()), address(pool.token()), pool.initialBaseReward(), pool.feeRecipient(), pool.miningOpen(), pool.currentEra(), pool.currentBaseReward()));
        bytes32 tasks = keccak256(abi.encode(pool.stakedBy(0), pool.stakedBy(2100), pool.stakeAgentId(0), pool.stakeAgentId(2100), pool.taskSeed(0), pool.taskSeed(2100), pool.taskNonce(0), pool.taskNonce(2100), pool.lastSolvedBlock(0)));
        return keccak256(abi.encode(configuration, tasks, pool.totalSolved(), pool.totalGrossMined(), pool.completedTasks(alice), pool.netEarned(alice), token.miningPool(), token.miningMinted(), token.totalSupply(), token.balanceOf(alice), token.balanceOf(fees), token.balanceOf(lp)));
    }

    function testUpgradePreservesActiveBusinessStateAndAllowsContinuedMintMarketStakeAndWork() public {
        _prepareActiveBusiness();
        bytes32 genesisBefore = _genesisState();
        bytes32 poolBefore = _poolState();
        (, uint256 originalNonce,, uint16[] memory originalEdges) = pool.getTask(2100);
        uint256 originalAnswer = LocalTaskSolver.solve(originalEdges);
        _upgrade();
        GenesisMinerV2 upgradedGenesis = GenesisMinerV2(address(genesis));
        MiningPoolV2 upgradedPool = MiningPoolV2(address(pool));
        assertEq(upgradedGenesis.version(), 2);
        assertEq(upgradedPool.version(), 2);
        assertEq(upgradedGenesis.upgradeMarker(), 0);
        assertEq(upgradedPool.upgradeMarker(), 0);
        upgradedGenesis.setUpgradeMarker(721);
        upgradedPool.setUpgradeMarker(20);
        assertEq(upgradedGenesis.upgradeMarker(), 721);
        assertEq(upgradedPool.upgradeMarker(), 20);
        assertEq(_genesisState(), genesisBefore);
        assertEq(_poolState(), poolBefore);
        vm.prank(alice); pool.submitTask(2100, originalNonce, originalAnswer, 0);
        vm.prank(bob); genesis.buy{value: 2 ether}(2, 2, 2 ether);
        assertEq(genesis.ownerOf(2), bob);
        (GenesisMiner.MarketListing[] memory active, uint256 count) = genesis.getActiveListings(0, 100);
        assertEq(count, 1);
        assertEq(active[0].tokenId, 3);
        vm.prank(alice); genesis.cancel(3);
        vm.prank(alice); genesis.list(3, 4 ether);
        assertEq(genesis.getListing(3).listingId, 4);
        vm.prank(alice); pool.unstake(_ids(0));
        uint256 exitNonce = pool.taskNonce(0);
        vm.prank(alice); pool.stake(_ids(0));
        assertEq(pool.taskNonce(0), exitNonce + 1);
        vm.roll(block.number + 1);
        _solve(0);
        assertEq(pool.totalSolved(), 3);
        assertEq(pool.completedTasks(alice), 3);
        assertEq(pool.totalGrossMined(), token.miningMinted());
        assertEq(pool.netEarned(alice), token.balanceOf(alice));
        assertEq(token.miningPool(), address(pool));
        vm.expectRevert(FourAgentCoin.MiningPoolLocked.selector);
        token.setMiningPool(address(pool));
        bytes32 salt = _minimumPowerSalt(2111);
        vm.prank(alice); genesis.mintBatch{value: PRICE * 10}(10, salt);
        assertGt(genesis.getToken(2111).power, genesis.MIN_POWER());
        assertEq(genesis.mintedByAgent(AGENT_ID), 21);
        for (uint256 i = 2100; i < 2121; ++i) {
            assertEq(genesis.mintOriginAgentId(i), AGENT_ID);
            for (uint256 j = 2100; j < i; ++j) assertNotEq(genesis.getToken(i).power, genesis.getToken(j).power);
        }
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.AgentMintLimit.selector);
        genesis.mint{value: PRICE}(bytes32(0));
        assertEq(genesis.getToken(0).power, 150_000_000);
    }
}
