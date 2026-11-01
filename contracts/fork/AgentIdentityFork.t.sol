// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BinanceAgentIdentityAdapter} from "../src/BinanceAgentIdentityAdapter.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {LocalTaskSolver} from "../test/Mocks.sol";

interface IOfficialAgentRegistryFork {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function handleOf(address holder) external view returns (string memory);
    function ownerOfHandle(string calldata handle) external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address holder) external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev Opt-in with FOUNDRY_PROFILE=bsc_fork, BSC_RPC_URL and an explicit BSC_FORK_BLOCK_NUMBER.
/// Reads the actual official Registry and simulates local protocol transactions with synthetic BNB.
/// No broadcast, production mint, private key, wallet session or real model execution occurs here.
contract AgentIdentityForkTest is Test {
    address private constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    bytes32 private constant REGISTRY_CODE_HASH = 0xc4006e6e6ffaaf6996116617392beabe4f5f0a0795841322f91c2ceac34d6ace;
    address private constant HOLDER = 0x40329b72c0f6EDB2196287d2aB535923A4743C50;
    address private constant SECOND_HOLDER = 0x72B73415e263C2b976B2770ee764BACD02ec3004;
    address private constant NO_ID = address(0x123);
    bytes32 private constant HOLDER_ID = 0x121274cfd5956527c56dfd7d3d684dd8db977163eda94d39f8c9215eded00639;
    bytes32 private constant SECOND_HOLDER_ID = 0x9cde749424d4ab2b74caad6ce50fe92417e6edbacc37f6871f2dcbb65aaa4a39;
    uint256 private constant PRICE = 0.0021 ether;

    address private admin = makeAddr("identity-fork-admin");
    address private treasury = makeAddr("identity-fork-treasury");
    address private fees = makeAddr("identity-fork-fees");
    BinanceAgentIdentityAdapter private identity;
    IOfficialAgentRegistryFork private official;
    GenesisMiner private genesis;
    FourAgentCoin private token;
    MiningPool private pool;

    function setUp() public {
        string memory rpc = vm.envString("BSC_RPC_URL");
        uint256 sourceBlock = vm.envUint("BSC_FORK_BLOCK_NUMBER");
        require(sourceBlock > 0, "BSC_FORK_BLOCK_NUMBER must be explicit and positive");
        vm.createSelectFork(rpc, sourceBlock);
        bytes memory encodedChain = vm.rpc("eth_chainId", "[]");
        require(encodedChain.length > 0 && encodedChain.length <= 32, "Invalid RPC chain ID encoding");
        uint256 sourceChain;
        for (uint256 i; i < encodedChain.length; ++i) sourceChain = (sourceChain << 8) | uint8(encodedChain[i]);
        assertEq(sourceChain, 56, "RPC must be BSC mainnet");
        assertEq(block.chainid, 56, "Fork source chain must be BSC");
        assertEq(block.number, sourceBlock);
        vm.roll(sourceBlock + 1);
        bytes32 sourceHash = blockhash(sourceBlock);
        assertNotEq(sourceHash, bytes32(0), "Selected source block hash unavailable");
        emit log_named_uint("BSC identity source block", sourceBlock);
        emit log_named_bytes32("BSC identity source block hash", sourceHash);
        vm.roll(sourceBlock);
        vm.chainId(31337);
        assertEq(block.chainid, 31337, "All protocol mutations must remain local");

        assertEq(REGISTRY.code.length, 8756, "Official registry runtime length changed");
        assertEq(REGISTRY.codehash, REGISTRY_CODE_HASH, "Official registry runtime changed; re-review required");
        official = IOfficialAgentRegistryFork(REGISTRY);
        identity = new BinanceAgentIdentityAdapter();
        assertEq(identity.registry(), REGISTRY);
        assertTrue(identity.isEligible(HOLDER), "Actual on-chain Agent ID holder must qualify");
        assertFalse(identity.isEligible(NO_ID), "Unregistered address must not qualify");

        vm.startPrank(admin);
        GenesisMiner genesisImplementation = new GenesisMiner();
        GenesisMiner.Config memory c = GenesisMiner.Config(admin, address(identity), "https://4agentcoin.pages.dev/nft/genesis-miner.png");
        genesis = GenesisMiner(address(new ERC1967Proxy(address(genesisImplementation), abi.encodeCall(GenesisMiner.initialize, (c, admin)))));
        token = new FourAgentCoin(treasury, fees);
        MiningPool poolImplementation = new MiningPool();
        pool = MiningPool(address(new ERC1967Proxy(address(poolImplementation), abi.encodeCall(MiningPool.initialize, (address(genesis), address(token), fees, uint256(2.1 ether), admin)))));
        genesis.setMiningPool(address(pool));
        token.setMiningPool(address(pool));
        vm.stopPrank();
        vm.deal(HOLDER, 10 ether);
        vm.deal(NO_ID, 10 ether);
        vm.deal(admin, 10 ether);
    }

    function testActualRegistryAndAdapterReturnTheSamePermanentTokenIds() public view {
        assertEq(official.name(), "SPACE ID Agent ID");
        assertEq(official.symbol(), "AI");
        assertEq(official.balanceOf(HOLDER), 1);
        assertEq(official.handleOf(HOLDER), "orcasai");
        assertEq(keccak256(bytes(official.handleOf(HOLDER))), HOLDER_ID);
        assertEq(official.ownerOf(uint256(HOLDER_ID)), HOLDER);
        assertEq(official.ownerOfHandle("orcasai"), HOLDER);
        assertEq(identity.agentIdOf(HOLDER), HOLDER_ID);
        assertNotEq(identity.agentIdOf(HOLDER), keccak256("orcasai.ai"));
        assertEq(official.handleOf(SECOND_HOLDER), "heyi");
        assertEq(official.balanceOf(SECOND_HOLDER), 1);
        assertEq(official.ownerOf(uint256(SECOND_HOLDER_ID)), SECOND_HOLDER);
        assertEq(official.ownerOfHandle("heyi"), SECOND_HOLDER);
        assertEq(identity.agentIdOf(SECOND_HOLDER), SECOND_HOLDER_ID);
        assertNotEq(HOLDER_ID, SECOND_HOLDER_ID);
        assertEq(official.handleOf(NO_ID), "");
        assertEq(official.balanceOf(NO_ID), 0);
        assertEq(identity.agentIdOf(NO_ID), bytes32(0));
        assertFalse(identity.isEligible(address(0)));
        assertEq(identity.agentIdOf(address(0)), bytes32(0));
    }

    function testOrdinaryAdministratorOwnsReserveAndDeploysWithEveryGateClosed() public view {
        assertFalse(identity.isEligible(admin), "Deployment must not require an Agent ID");
        assertEq(genesis.owner(), admin);
        assertEq(token.owner(), admin);
        assertEq(pool.owner(), admin);
        assertEq(genesis.reserveRecipient(), admin);
        assertEq(genesis.balanceOf(admin), 2100);
        assertEq(genesis.totalAllocated(), 2100);
        assertEq(genesis.saleRevenue(), 0);
        assertFalse(genesis.mintOpen());
        assertFalse(genesis.stakingOpen());
        assertFalse(pool.miningOpen());
        assertEq(genesis.identityVerifier(), address(identity));
        assertEq(genesis.miningPool(), address(pool));
        assertEq(token.miningPool(), address(pool));
        assertEq(token.balanceOf(treasury), token.LP_ALLOCATION());
        assertEq(token.miningMinted(), 0);
    }

    function testRealAgentMintsTwentyOneAndSellingAMinerCannotResetItsIdentityQuota() public {
        _openMint();
        uint256 balanceBefore = HOLDER.balance;
        vm.prank(HOLDER);
        uint256 first = genesis.mintBatch{value: 21 * PRICE}(21, keccak256("real-identity-batch"));
        assertEq(first, 2100);
        assertEq(genesis.totalAllocated(), 2121);
        assertEq(genesis.publicMinted(), 21);
        assertEq(genesis.mintedByAgent(HOLDER_ID), 21);
        assertEq(genesis.saleRevenue(), 21 * PRICE);
        assertEq(address(genesis).balance, 21 * PRICE);
        assertEq(HOLDER.balance, balanceBefore - 21 * PRICE);
        for (uint256 i; i < 21; ++i) {
            GenesisMiner.TokenView memory miner = genesis.getToken(first + i);
            assertEq(miner.owner, HOLDER);
            assertFalse(miner.isReserved);
            assertGe(miner.power, 50_000_000);
            assertLe(miner.power, 250_000_000);
            assertEq(genesis.mintOriginAgentId(first + i), HOLDER_ID);
            for (uint256 j; j < i; ++j) assertNotEq(miner.power, genesis.getToken(first + j).power);
        }
        // The unrestricted secondary market moves the miner, not its official identity or mint allowance.
        vm.prank(HOLDER);
        genesis.list(first, 0.1 ether);
        GenesisMiner.Listing memory listing = genesis.getListing(first);
        vm.prank(NO_ID);
        genesis.buy{value: listing.price}(first, listing.listingId, listing.price);
        assertEq(genesis.ownerOf(first), NO_ID);
        assertEq(genesis.mintedByAgent(HOLDER_ID), 21);
        assertFalse(genesis.isMintEligible(HOLDER));
        vm.expectRevert(GenesisMiner.AgentMintLimit.selector);
        vm.prank(HOLDER);
        genesis.mint{value: PRICE}(keccak256("cannot-remint-after-sale"));
        assertEq(genesis.totalAllocated(), 2121);
        assertEq(genesis.saleRevenue(), 21 * PRICE);
    }

    function testNoIdCannotMintOrStakeButCanBuyAndSellGenesisNfts() public {
        _openMint();
        vm.expectRevert(GenesisMiner.NotEligible.selector);
        vm.prank(NO_ID);
        genesis.mint{value: PRICE}(keccak256("no-official-id"));
        assertEq(genesis.totalAllocated(), 2100);
        assertEq(genesis.saleRevenue(), 0);
        uint256 minerId = _mint(1);
        vm.prank(HOLDER);
        genesis.transferFrom(HOLDER, NO_ID, minerId);
        _openMining();
        vm.startPrank(NO_ID);
        genesis.setApprovalForAll(address(pool), true);
        vm.expectRevert(MiningPool.NotEligible.selector);
        pool.stake(_ids(minerId));
        assertFalse(genesis.isStaked(minerId));
        genesis.list(minerId, 0.1 ether);
        vm.stopPrank();
        GenesisMiner.Listing memory listing = genesis.getListing(minerId);
        uint256 sellerBefore = NO_ID.balance;
        uint256 buyerBefore = admin.balance;
        vm.prank(admin);
        genesis.buy{value: listing.price}(minerId, listing.listingId, listing.price);
        assertEq(genesis.ownerOf(minerId), admin);
        assertEq(NO_ID.balance, sellerBefore + 0.095 ether);
        assertEq(admin.balance, buyerBefore - 0.1 ether);
        assertEq(genesis.marketFeeBalance(), 0.005 ether);
        assertEq(genesis.saleRevenue(), PRICE);
        assertEq(address(genesis).balance, PRICE + 0.005 ether);
        assertEq(pool.totalSolved(), 0);
        assertEq(token.miningMinted(), 0);
    }

    function testRealHolderBatchStakesAndValidWorkPaysExactNetAndFee() public {
        _openMint();
        uint256 first = _mint(2);
        _openMining();
        vm.startPrank(HOLDER);
        genesis.setApprovalForAll(address(pool), true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = first + 1;
        pool.stake(ids);
        vm.stopPrank();
        assertEq(pool.stakeAgentId(first), HOLDER_ID);
        assertEq(pool.stakeAgentId(first + 1), HOLDER_ID);
        assertEq(genesis.totalStakeLocks(), 2);
        vm.warp(block.timestamp + 1 days);
        assertEq(token.balanceOf(HOLDER), 0, "Staking alone must never issue mining rewards");
        assertEq(pool.totalGrossMined(), 0);
        (uint256 gross0, uint256 fee0, uint256 net0,) = pool.previewReward(first);
        (uint256 gross1, uint256 fee1, uint256 net1,) = pool.previewReward(first + 1);
        (uint256 nonce, uint256 answer) = _solution(first);
        vm.expectRevert(MiningPool.InvalidAnswer.selector);
        vm.prank(HOLDER);
        pool.submitTask(first, nonce, answer | (1 << 32), 0);
        assertEq(pool.taskNonce(first), nonce);
        assertEq(token.miningMinted(), 0);
        _solve(first);
        _solve(first + 1);
        assertEq(token.balanceOf(HOLDER), net0 + net1);
        assertEq(token.balanceOf(fees), fee0 + fee1);
        assertEq(pool.totalGrossMined(), gross0 + gross1);
        assertEq(pool.totalSolved(), 2);
        assertEq(pool.completedTasks(HOLDER), 2);
        assertEq(pool.netEarned(HOLDER), net0 + net1);
        assertEq(token.miningMinted(), gross0 + gross1);
        assertEq(token.totalSupply(), token.LP_ALLOCATION() + gross0 + gross1);
        assertEq(token.balanceOf(treasury), token.LP_ALLOCATION());
        assertEq(genesis.ownerOf(first), HOLDER, "Noncustodial stake must retain NFT ownership");
        assertEq(genesis.mintedByAgent(HOLDER_ID), 2);
    }

    function testLocallyInjectedRegistryFailureStopsNewWorkButNeverBlocksExit() public {
        _openMint();
        uint256 first = _mint(2);
        _openMining();
        vm.startPrank(HOLDER);
        genesis.setApprovalForAll(address(pool), true);
        pool.stake(_ids(first));
        vm.stopPrank();
        (uint256 nonce, uint256 answer) = _solution(first);
        // A local Foundry fault injection only; the remote Registry's code and state are untouched.
        vm.mockCallRevert(REGISTRY, bytes(""), abi.encodeWithSignature("Error(string)", "local identity outage"));
        vm.expectRevert(GenesisMiner.IdentityUnavailable.selector);
        vm.prank(HOLDER);
        genesis.mint{value: PRICE}(keccak256("identity-outage"));
        vm.expectRevert(MiningPool.IdentityUnavailable.selector);
        vm.prank(HOLDER);
        pool.stake(_ids(first + 1));
        vm.expectRevert(MiningPool.IdentityUnavailable.selector);
        vm.prank(HOLDER);
        pool.submitTask(first, nonce, answer, 0);
        assertEq(pool.taskNonce(first), nonce);
        assertEq(pool.totalGrossMined(), 0);
        assertEq(genesis.publicMinted(), 2);
        vm.startPrank(admin);
        pool.setMiningOpen(false);
        genesis.setStakingOpen(false);
        vm.stopPrank();
        vm.prank(HOLDER);
        pool.unstake(_ids(first));
        assertFalse(genesis.isStaked(first));
        assertEq(genesis.totalStakeLocks(), 0);
        assertEq(pool.stakedBy(first), address(0));
        assertEq(pool.taskNonce(first), nonce + 1);
        assertEq(genesis.ownerOf(first), HOLDER);
        vm.clearMockedCalls();
        assertEq(REGISTRY.codehash, REGISTRY_CODE_HASH);
        assertEq(official.handleOf(HOLDER), "orcasai");
        assertEq(identity.agentIdOf(HOLDER), HOLDER_ID);
    }

    function testOfficialIdentityCannotMoveWithASecondaryMinerSale() public {
        vm.expectRevert(bytes4(keccak256("Soulbound()")));
        vm.prank(HOLDER);
        official.transferFrom(HOLDER, NO_ID, uint256(HOLDER_ID));
        assertEq(official.ownerOf(uint256(HOLDER_ID)), HOLDER);
        assertEq(official.ownerOfHandle("orcasai"), HOLDER);
        assertEq(identity.agentIdOf(HOLDER), HOLDER_ID);
        assertEq(identity.agentIdOf(NO_ID), bytes32(0));
    }

    function _openMint() private {
        vm.prank(admin);
        genesis.setMintOpen(true);
    }

    function _openMining() private {
        vm.startPrank(admin);
        genesis.setStakingOpen(true);
        pool.setMiningOpen(true);
        vm.stopPrank();
    }

    function _mint(uint256 quantity) private returns (uint256 first) {
        vm.prank(HOLDER);
        first = genesis.mintBatch{value: quantity * PRICE}(quantity, keccak256("real-identity-mint"));
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _solution(uint256 id) private view returns (uint256 nonce, uint256 answer) {
        uint16[] memory edges;
        (, nonce,, edges) = pool.getTask(id);
        // This solver is test-only. Validity cannot attest an actual LLM invocation.
        answer = LocalTaskSolver.solve(edges);
    }

    function _solve(uint256 id) private {
        (uint256 nonce, uint256 answer) = _solution(id);
        vm.prank(HOLDER);
        pool.submitTask(id, nonce, answer, 0);
    }
}
