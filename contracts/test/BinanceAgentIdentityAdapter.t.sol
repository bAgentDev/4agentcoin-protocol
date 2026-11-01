// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BinanceAgentIdentityAdapter} from "../src/BinanceAgentIdentityAdapter.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {LocalTaskSolver} from "./Mocks.sol";

/// @dev Unit-test storage installed at the fixed registry address; never a production identity source.
contract BinanceHandleRegistryReadMock {
    mapping(address => string) private handles;
    mapping(address => uint256) private balances;
    mapping(bytes32 => address) private handleOwners;
    mapping(uint256 => address) private tokenOwners;
    uint8 public failQuery;

    error QueryFailed(uint8 query);
    error UnknownToken();

    function setIdentity(address account, string calldata handle) external {
        handles[account] = handle;
        balances[account] = bytes(handle).length == 0 ? 0 : 1;
        if (bytes(handle).length != 0) {
            bytes32 id = keccak256(bytes(handle));
            handleOwners[id] = account;
            tokenOwners[uint256(id)] = account;
        }
    }

    function setBalance(address account, uint256 value) external { balances[account] = value; }
    function setHandleOwner(bytes32 id, address value) external { handleOwners[id] = value; }
    function setTokenOwner(uint256 id, address value) external { tokenOwners[id] = value; }
    function setFailQuery(uint8 query) external { failQuery = query; }

    function handleOf(address account) external view returns (string memory) {
        if (failQuery == 1) revert QueryFailed(1);
        return handles[account];
    }

    function balanceOf(address account) external view returns (uint256) {
        if (failQuery == 2) revert QueryFailed(2);
        return balances[account];
    }

    function ownerOfHandle(string calldata handle) external view returns (address) {
        if (failQuery == 3) revert QueryFailed(3);
        return handleOwners[keccak256(bytes(handle))];
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (failQuery == 4) revert QueryFailed(4);
        address account = tokenOwners[id];
        if (account == address(0)) revert UnknownToken();
        return account;
    }
}

abstract contract BinanceIdentityFixture is Test {
    address internal constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    BinanceAgentIdentityAdapter internal adapter;
    BinanceHandleRegistryReadMock internal source;
    address internal alice = makeAddr("official-agent-alice");
    address internal bob = makeAddr("official-agent-bob");
    address internal outsider = makeAddr("no-agent-id");

    function _setupIdentity() internal {
        BinanceHandleRegistryReadMock template = new BinanceHandleRegistryReadMock();
        vm.etch(REGISTRY, address(template).code);
        source = BinanceHandleRegistryReadMock(REGISTRY);
        adapter = new BinanceAgentIdentityAdapter();
        source.setIdentity(alice, "aliceagent");
        source.setIdentity(bob, "bobagent");
    }
}

contract BinanceAgentIdentityAdapterTest is BinanceIdentityFixture {
    function setUp() public { _setupIdentity(); }

    function testIdentityEqualsOfficialRawHandleTokenId() public view {
        bytes32 id = keccak256(bytes("aliceagent"));
        assertEq(adapter.registry(), REGISTRY);
        assertTrue(adapter.isEligible(alice));
        assertEq(adapter.agentIdOf(alice), id);
        assertEq(source.ownerOf(uint256(id)), alice);
        assertNotEq(adapter.agentIdOf(alice), keccak256(bytes("aliceagent.ai")));
        assertNotEq(adapter.agentIdOf(alice), keccak256(abi.encode(alice)));
    }

    function testAbsentAndZeroAddressesHaveNoIdentity() public view {
        assertFalse(adapter.isEligible(outsider));
        assertEq(adapter.agentIdOf(outsider), bytes32(0));
        assertFalse(adapter.isEligible(address(0)));
        assertEq(adapter.agentIdOf(address(0)), bytes32(0));
    }

    function testExistingHandlesDoNotDependOnCurrentRegistrationLengthSettings() public {
        string[4] memory handles = [
            string("a"),
            "abcdefghijklmnop",
            "abcdefghijklmnopqrst",
            "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl"
        ];
        for (uint256 i; i < handles.length; ++i) {
            source.setIdentity(alice, handles[i]);
            assertTrue(adapter.isEligible(alice));
            assertEq(adapter.agentIdOf(alice), keccak256(bytes(handles[i])));
        }
    }

    function testIncompleteAndMismatchedRecordsAreUnavailable() public {
        bytes32 id = keccak256(bytes("aliceagent"));
        source.setBalance(alice, 0);
        _expectInconsistent();
        source.setBalance(alice, 2);
        _expectInconsistent();
        source.setBalance(alice, 1);
        source.setHandleOwner(id, bob);
        _expectInconsistent();
        source.setHandleOwner(id, alice);
        source.setTokenOwner(uint256(id), bob);
        _expectInconsistent();
        source.setIdentity(alice, "");
        source.setBalance(alice, 1);
        _expectInconsistent();
    }

    function _expectInconsistent() private {
        vm.expectRevert(BinanceAgentIdentityAdapter.InconsistentIdentity.selector);
        adapter.isEligible(alice);
        vm.expectRevert(BinanceAgentIdentityAdapter.InconsistentIdentity.selector);
        adapter.agentIdOf(alice);
    }

    function testEveryUpstreamQueryFailurePropagatesInsteadOfDenyingMembership() public {
        for (uint8 query = 1; query <= 4; ++query) {
            source.setFailQuery(query);
            bytes memory reason = abi.encodeWithSelector(BinanceHandleRegistryReadMock.QueryFailed.selector, query);
            vm.expectRevert(reason);
            adapter.isEligible(alice);
            vm.expectRevert(reason);
            adapter.agentIdOf(alice);
        }
    }

    function testMissingRegistryCodeIsUnavailable() public {
        vm.etch(REGISTRY, hex"");
        vm.expectRevert(BinanceAgentIdentityAdapter.RegistryUnavailable.selector);
        adapter.isEligible(alice);
        vm.expectRevert(BinanceAgentIdentityAdapter.RegistryUnavailable.selector);
        adapter.agentIdOf(alice);
    }

    function testMalformedRegistryReturnDataIsUnavailable() public {
        vm.mockCall(REGISTRY, abi.encodeWithSignature("handleOf(address)", alice), hex"01");
        vm.expectRevert();
        adapter.isEligible(alice);
        vm.expectRevert();
        adapter.agentIdOf(alice);
    }
}

contract BinanceIdentityProtocolTest is BinanceIdentityFixture {
    GenesisMiner internal genesis;
    FourAgentCoin internal token;
    MiningPool internal pool;
    address internal admin = makeAddr("ordinary-eoa-administrator");
    address internal fees = makeAddr("protocol-fees");
    uint256 internal constant PRICE = 0.0021 ether;

    function setUp() public {
        _setupIdentity();
        GenesisMiner implementation = new GenesisMiner();
        genesis = GenesisMiner(address(new ERC1967Proxy(address(implementation), abi.encodeCall(
            GenesisMiner.initialize, (GenesisMiner.Config(admin, address(adapter), "ipfs://identity-regression"), admin)
        ))));
        vm.prank(admin);
        token = new FourAgentCoin(admin, fees);
        MiningPool poolImplementation = new MiningPool();
        pool = MiningPool(address(new ERC1967Proxy(address(poolImplementation), abi.encodeCall(
            MiningPool.initialize, (address(genesis), address(token), fees, uint256(2.1 ether), admin)
        ))));
        vm.startPrank(admin);
        genesis.setMiningPool(address(pool));
        token.setMiningPool(address(pool));
        genesis.setMintOpen(true);
        genesis.setStakingOpen(true);
        pool.setMiningOpen(true);
        vm.stopPrank();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(outsider, 100 ether);
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _mint(uint256 quantity) private returns (uint256 first) {
        vm.prank(alice);
        first = genesis.mintBatch{value: quantity * PRICE}(quantity, keccak256(abi.encode(quantity)));
    }

    function _stake(uint256 id) private {
        vm.startPrank(alice);
        genesis.setApprovalForAll(address(pool), true);
        pool.stake(_ids(id));
        vm.stopPrank();
    }

    function _answer(uint256 id) private view returns (uint256 nonce, uint256 packed) {
        uint16[] memory edges;
        (, nonce,, edges) = pool.getTask(id);
        packed = LocalTaskSolver.solve(edges);
    }

    function testMintQuotaUsesOfficialIdAndNFTTransfersNeverRestoreIt() public {
        bytes32 aliceId = keccak256(bytes("aliceagent"));
        uint256 first = _mint(20);
        assertEq(genesis.mintedByAgent(aliceId), 20);
        assertEq(genesis.mintOriginAgentId(first), aliceId);
        assertEq(genesis.mintedByAgent(keccak256(bytes("aliceagent.ai"))), 0);
        assertEq(genesis.mintedByAgent(keccak256(abi.encode(alice))), 0);
        vm.prank(alice); genesis.transferFrom(alice, bob, first);
        assertEq(genesis.mintedByAgent(aliceId), 20);
        _mint(1);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.AgentMintLimit.selector);
        genesis.mint{value: PRICE}(bytes32(0));
        assertEq(genesis.mintedByAgent(aliceId), 21);
        assertEq(genesis.mintedByAgent(keccak256(bytes("bobagent"))), 0);
        vm.prank(bob); genesis.mintBatch{value: 21 * PRICE}(21, bytes32(uint256(21)));
        assertEq(genesis.mintedByAgent(keccak256(bytes("bobagent"))), 21);
    }

    function testNoIdentityBlocksMintAndStakeWhileOrdinaryAdminCanManage() public {
        assertFalse(adapter.isEligible(admin));
        assertEq(genesis.owner(), admin);
        assertEq(pool.owner(), admin);
        assertEq(token.owner(), admin);
        assertEq(genesis.ownerOf(0), admin);
        vm.prank(outsider);
        vm.expectRevert(GenesisMiner.NotEligible.selector);
        genesis.mint{value: PRICE}(bytes32(0));
        vm.prank(admin); genesis.transferFrom(admin, outsider, 0);
        vm.startPrank(outsider);
        genesis.setApprovalForAll(address(pool), true);
        vm.expectRevert(MiningPool.NotEligible.selector);
        pool.stake(_ids(0));
        vm.stopPrank();
        assertFalse(genesis.isStaked(0));
        assertEq(token.balanceOf(outsider), 0);
    }

    function testOfficialIdentityMintsStakesCompletesWorkAndExits() public {
        uint256 id = _mint(1);
        _stake(id);
        bytes32 aliceId = keccak256(bytes("aliceagent"));
        assertEq(pool.stakeAgentId(id), aliceId);
        assertEq(token.balanceOf(alice), 0);
        (uint256 gross, uint256 fee, uint256 net,) = pool.previewReward(id);
        (uint256 nonce, uint256 packed) = _answer(id);
        vm.prank(alice); pool.submitTask(id, nonce, packed, gross);
        assertEq(token.balanceOf(alice), net);
        assertEq(token.balanceOf(fees), fee);
        assertEq(token.miningMinted(), gross);
        assertEq(pool.completedTasks(alice), 1);
        vm.startPrank(admin);
        genesis.setStakingOpen(false);
        pool.setMiningOpen(false);
        vm.stopPrank();
        vm.prank(alice); pool.unstake(_ids(id));
        assertFalse(genesis.isStaked(id));
        assertEq(genesis.ownerOf(id), alice);
        assertEq(token.balanceOf(alice), net);
    }

    function testRegistryOutageBlocksNewWorkAndMintButNeverUnstake() public {
        uint256 id = _mint(2);
        _stake(id);
        (uint256 nonce, uint256 packed) = _answer(id);
        vm.prank(alice); pool.submitTask(id, nonce, packed, 0);
        uint256 earned = token.balanceOf(alice);
        vm.roll(block.number + 1);
        (nonce, packed) = _answer(id);
        source.setFailQuery(1);
        assertFalse(genesis.isMintEligible(alice));
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.IdentityUnavailable.selector);
        genesis.mint{value: PRICE}(bytes32(0));
        vm.prank(alice);
        vm.expectRevert(MiningPool.IdentityUnavailable.selector);
        pool.stake(_ids(id + 1));
        vm.prank(alice);
        vm.expectRevert(MiningPool.IdentityUnavailable.selector);
        pool.submitTask(id, nonce, packed, 0);
        vm.prank(alice); pool.unstake(_ids(id));
        assertFalse(genesis.isStaked(id));
        assertEq(token.balanceOf(alice), earned);
        vm.prank(alice); genesis.transferFrom(alice, outsider, id);
        assertEq(genesis.ownerOf(id), outsider);
        assertEq(genesis.mintedByAgent(keccak256(bytes("aliceagent"))), 2);
    }
}
