// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {MockIdentityVerifier, InspectingMintReceiver, MockMiningPool, RejectingSeller, PayableSeller, RejectingBuyer, ReenteringSeller} from "./Mocks.sol";

contract GenesisMinerTest is Test {
    GenesisMiner internal miner;
    MockIdentityVerifier internal identity;
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant PRICE = 0.0021 ether;

    function setUp() public {
        identity = new MockIdentityVerifier();
        GenesisMiner implementation = new GenesisMiner();
        miner = GenesisMiner(address(new ERC1967Proxy(address(implementation), abi.encodeCall(GenesisMiner.initialize, (_config(address(identity)), admin)))));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function _config(address verifier) internal view returns (GenesisMiner.Config memory) {
        return GenesisMiner.Config(admin, verifier, "ipfs://local-test/genesis-miner.png");
    }

    function _ready(uint256 id, address holder) internal {
        vm.prank(admin);
        miner.transferFrom(admin, holder, id);
    }

    function _open() internal {
        identity.setEligible(alice, true);
        identity.setAgentId(alice, keccak256("alice-agent"));
        vm.prank(admin);
        miner.setMintOpen(true);
    }

    function _list(uint256 id, uint256 price) internal returns (uint256) {
        vm.prank(alice);
        miner.list(id, price);
        return miner.getListing(id).listingId;
    }

    function testConsecutiveReserveAndProgress() public view {
        assertEq(miner.totalSupply(), 2100);
        assertEq(miner.totalAllocated(), 2100);
        assertEq(miner.reservedAllocated(), 2100);
        assertEq(miner.publicMinted(), 0);
        assertEq(miner.ownerOf(0), admin);
        assertEq(miner.ownerOf(2099), admin);
        assertEq(miner.balanceOf(admin), 2100);
        assertEq(miner.saleRevenue(), 0);
        assertFalse(miner.genesisComplete());
        assertEq(miner.getToken(0).power, 150_000_000);
    }

    function _metadata(uint256 tokenId) internal view returns (string memory) {
        bytes memory uri = bytes(miner.tokenURI(tokenId));
        assertEq(string(Bytes.slice(uri, 0, 29)), "data:application/json;base64,");
        return string(Base64.decode(string(Bytes.slice(uri, 29))));
    }



    /// @dev Reads unquoted decimal digits without rounding through floating-point JSON conversion.
    function _scaledAttribute(string memory json, string memory trait) internal pure returns (uint256 value) {
        bytes memory document = bytes(json);
        bytes memory marker = bytes(string.concat('"trait_type":"', trait, '","value":'));
        for (uint256 start; start + marker.length <= document.length; ++start) {
            bool matches = true;
            for (uint256 j; j < marker.length; ++j) {
                if (document[start + j] != marker[j]) { matches = false; break; }
            }
            if (!matches) continue;
            uint256 fractionalDigits;
            bool decimal;
            for (uint256 i = start + marker.length; i < document.length; ++i) {
                bytes1 character = document[i];
                if (character == "," || character == "}") {
                    assertEq(fractionalDigits, 6, "metadata must retain all six decimal places");
                    return value;
                }
                if (character == ".") {
                    assertFalse(decimal, "duplicate decimal point");
                    decimal = true;
                } else {
                    assertTrue(character >= "0" && character <= "9", "attribute must be an unquoted JSON number");
                    value = value * 10 + uint8(character) - 48;
                    if (decimal) ++fractionalDigits;
                }
            }
        }
        revert("missing numeric attribute");
    }

    function testMetadataSupportsERC4906AndExistingNFTInterfaces() public view {
        assertTrue(miner.supportsInterface(0x49064906));
        assertTrue(miner.supportsInterface(0x01ffc9a7));
        assertTrue(miner.supportsInterface(0x80ac58cd));
        assertTrue(miner.supportsInterface(0x5b5e139f));
        assertFalse(miner.supportsInterface(0xffffffff));
    }

    function testReservedMetadataIsFixedFromConstruction() public view {
        string memory json = _metadata(0);
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "Finalized");
        assertEq(_scaledAttribute(json, "Hashrate"), 150_000_000);
    }

    function testPaidMintIsImmediatelyReadyForListing() public {
        _open();
        vm.prank(alice);
        uint256 id = miner.mint{value: PRICE}(bytes32(0));
        assertEq(_scaledAttribute(_metadata(id), "Hashrate"), miner.getToken(id).power);
        vm.prank(alice);
        miner.list(id, 1 ether);
        assertTrue(miner.getListing(id).active);
    }

    function testFuzzFinalizedMetadataMatchesFixedOnChainPower(uint256 saltWord) public {
        _open();
        bytes32 salt = bytes32(saltWord);
        uint256 expectedId = miner.totalAllocated();
        bytes32 entropy = keccak256(abi.encode("GENESIS_MINT_POWER_V1", salt, blockhash(block.number - 1), expectedId, keccak256("alice-agent"), uint256(0), block.chainid, address(miner)));
        vm.prank(alice);
        uint256 id = miner.mint{value: PRICE}(salt);
        string memory json = _metadata(id);
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "Finalized");
        assertEq(vm.parseJsonString(json, ".attributes[1].trait_type"), "Hashrate");
        assertEq(vm.parseJsonString(json, ".attributes[1].display_type"), "number");
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "Genesis");
        uint256 power = miner.getToken(id).power;
        uint256 q = 1e18;
        uint256 u = uint256(entropy) % (q + 1);
        uint256 r = u * u / q;
        uint256 adjusted = r * 10_300 * q / (10_000 * q + 300 * r);
        assertEq(power, 50_000_000 + 200_000_000 * adjusted / q);
        assertGe(power, 50_000_000);
        assertLe(power, 250_000_000);
        assertEq(_scaledAttribute(json, "Hashrate"), power);
        string memory fixedURI = miner.tokenURI(id);
        vm.prank(alice); miner.transferFrom(alice, bob, id);
        assertEq(miner.tokenURI(id), fixedURI);
        assertEq(miner.getToken(id).power, power);
    }

    function testImageURIChangeEscapesJSONAndRefreshesAllAllocatedTokens() public {
        _open();
        vm.prank(alice);
        uint256 id = miner.mint{value: PRICE}(bytes32(0));
        string memory image = 'https://example.com/nft/"\\\n\t\r\x01.png';
        vm.expectEmit(false, false, false, true, address(miner));
        emit IERC4906.BatchMetadataUpdate(0, id);
        vm.prank(admin);
        miner.setImageURI(image);
        assertEq(vm.parseJsonString(_metadata(0), ".image"), image);
        assertEq(vm.parseJsonString(_metadata(id), ".image"), image);
        assertEq(vm.parseJsonString(_metadata(id), ".attributes[2].trait_type"), "Series");
        assertEq(vm.parseJsonString(_metadata(id), ".attributes[2].value"), "Genesis");
        assertFalse(vm.keyExistsJson(_metadata(id), ".attributes[3]"));
    }

    function testImageURIConfigurationRejectsEmptyAndUnauthorizedChanges() public {
        GenesisMiner.Config memory config = _config(address(identity));
        config.imageURI = "";
        GenesisMiner implementation = new GenesisMiner();
        vm.expectRevert(GenesisMiner.InvalidConfiguration.selector);
        new ERC1967Proxy(address(implementation), abi.encodeCall(GenesisMiner.initialize, (config, admin)));
        vm.prank(admin);
        vm.expectRevert(GenesisMiner.InvalidConfiguration.selector);
        miner.setImageURI("");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        miner.setImageURI("ipfs://unauthorized.png");
        assertEq(miner.getToken(0).power, 150_000_000);
    }

    function testMetadataRejectsUnallocatedToken() public {
        uint256 id = miner.totalAllocated();
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", id));
        miner.tokenURI(id);
    }

    function testMintChecksIdentityAndTracksPaidRevenueOnly() public {
        _open();
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.NotEligible.selector);
        miner.mint{value: PRICE}(bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.IncorrectPayment.selector);
        miner.mint{value: PRICE + 1}(bytes32(uint256(1)));
        vm.prank(alice);
        uint256 id = miner.mint{value: PRICE}(bytes32(uint256(1)));
        assertEq(id, 2100);
        assertEq(miner.totalAllocated(), 2101);
        assertEq(miner.publicMinted(), 1);
        assertEq(miner.saleRevenue(), PRICE);
        assertGe(miner.getToken(id).power, 50_000_000);
        assertLe(miner.getToken(id).power, 250_000_000);
        vm.prank(admin);
        vm.expectRevert(GenesisMiner.IdentityLocked.selector);
        miner.setIdentityVerifier(address(0));
    }

    function testMissingIdentityAndFailedQueryFailClosed() public {
        vm.prank(admin);
        miner.setIdentityVerifier(address(0));
        vm.prank(admin);
        vm.expectRevert(GenesisMiner.InvalidConfiguration.selector);
        miner.setMintOpen(true);
        assertFalse(miner.isMintEligible(alice));
        vm.prank(admin);
        miner.setIdentityVerifier(address(identity));
        _open();
        identity.setFail(true);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.IdentityUnavailable.selector);
        miner.mint{value: PRICE}(bytes32(0));
        assertEq(miner.publicMinted(), 0);
        assertEq(miner.saleRevenue(), 0);
    }

    function testMintRequiresStableIdentityAndNeverFallsBackToWallet() public {
        _open();
        identity.setAgentId(alice, bytes32(0));
        assertFalse(miner.isMintEligible(alice));
        vm.prank(alice); vm.expectRevert(GenesisMiner.IdentityUnavailable.selector);
        miner.mint{value: PRICE}(bytes32(0));
        identity.setFailAgentId(true);
        vm.prank(alice); vm.expectRevert(GenesisMiner.IdentityUnavailable.selector);
        miner.mint{value: PRICE}(bytes32(0));
        assertEq(miner.publicMinted(), 0);
    }

    function testReceiverSeesFixedHPAndRejectingBatchRollsBackEverything() public {
        _open();
        InspectingMintReceiver receiver = new InspectingMintReceiver(miner);
        identity.setEligible(address(receiver), true);
        bytes32 agentId = keccak256("receiver-agent");
        identity.setAgentId(address(receiver), agentId);
        receiver.setRejectSecond(true);
        vm.expectRevert("receiver rejects second NFT");
        receiver.mintBatch{value: PRICE * 2}(2, bytes32(0));
        assertEq(miner.totalAllocated(), 2100);
        assertEq(miner.publicMinted(), 0);
        assertEq(miner.saleRevenue(), 0);
        assertEq(miner.mintedByAgent(agentId), 0);
        assertEq(receiver.observedTokens(), 0);
        receiver.setRejectSecond(false);
        receiver.mintBatch{value: PRICE * 2}(2, bytes32(0));
        assertEq(receiver.observedTokens(), 2);
        assertEq(receiver.observedPower(), miner.getToken(2101).power);
        assertNotEq(miner.getToken(2100).power, miner.getToken(2101).power);
    }

    function testBatchPowersAreFixedUniqueAndCannotBeRedrawn() public {
        _open();
        vm.prank(alice);
        uint256 firstId = miner.mintBatch{value: PRICE * 21}(21, bytes32(uint256(123)));
        for (uint256 i; i < 21; ++i) {
            uint256 power = miner.getToken(firstId + i).power;
            assertGe(power, 50_000_000);
            assertLe(power, 250_000_000);
            for (uint256 j; j < i; ++j) assertNotEq(power, miner.getToken(firstId + j).power);
        }
        uint256 fixedPower = miner.getToken(firstId).power;
        vm.prank(alice);
        (bool redraw,) = address(miner).call(abi.encodeWithSignature("requestPower(uint256,bytes32)", firstId, bytes32(0)));
        assertFalse(redraw);
        vm.prank(alice); miner.transferFrom(alice, bob, firstId);
        identity.setAgentId(bob, keccak256("another-agent"));
        assertEq(miner.getToken(firstId).power, fixedPower);
    }

    function testFixedSaltSampleFavorsLowerPowerForPublicMiners() public {
        _open();
        uint256 low;
        uint256 high;
        uint256 lowerHalf;
        uint256 upperHalf;
        for (uint256 i; i < 128; ++i) {
            identity.setAgentId(alice, keccak256(abi.encode("sample", i / 21)));
            vm.prank(alice);
            uint256 id = miner.mint{value: PRICE}(bytes32(i));
            uint256 power = miner.getToken(id).power;
            assertGe(power, 50_000_000);
            assertLe(power, 250_000_000);
            if (power < 100_000_000) ++low;
            if (power > 200_000_000) ++high;
            if (power <= 150_000_000) ++lowerHalf;
            else ++upperHalf;
        }
        assertGt(low, high);
        assertGt(lowerHalf, upperHalf);
        assertEq(miner.getToken(1).power, 150_000_000);
    }

    function testNoPublicBurn() public {
        vm.prank(admin);
        vm.expectRevert();
        miner.transferFrom(admin, address(0), 0);
        assertEq(miner.totalAllocated(), 2100);
    }

    function testMarketDoesNotRequireAgentIdAndPaysSellerImmediately() public {
        _ready(0, alice);
        uint256 listing = _list(0, 1 ether);
        assertFalse(identity.eligible(alice));
        assertFalse(identity.eligible(bob));
        uint256 sellerBefore = alice.balance;
        uint256 buyerBefore = bob.balance;
        vm.prank(bob);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
        assertEq(miner.ownerOf(0), bob);
        assertEq(alice.balance - sellerBefore, 0.95 ether);
        assertEq(buyerBefore - bob.balance, 1 ether);
        assertEq(miner.marketFeeBalance(), 0.05 ether);
        assertEq(miner.saleRevenue(), 0);
        assertEq(address(miner).balance, 0.05 ether);
        assertFalse(miner.getListing(0).active);
    }

    function testMarketPaysPayableContractSellerImmediately() public {
        PayableSeller seller = new PayableSeller();
        vm.prank(admin);
        miner.safeTransferFrom(admin, address(seller), 0);
        seller.listMiner(miner, 0, 1 ether);
        uint256 listing = miner.getListing(0).listingId;
        vm.prank(bob);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
        assertEq(miner.ownerOf(0), bob);
        assertEq(address(seller).balance, 0.95 ether);
        assertEq(seller.received(), 0.95 ether);
        assertEq(miner.marketFeeBalance(), 0.05 ether);
        assertEq(address(miner).balance, 0.05 ether);
    }

    function testExpectedListingAndExactPricePreventStaleOrder() public {
        _ready(0, alice);
        uint256 oldId = _list(0, 1 ether);
        vm.prank(alice);
        miner.cancel(0);
        uint256 nextId = _list(0, 2 ether);
        assertGt(nextId, oldId);
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.StaleListing.selector);
        miner.buy{value: 2 ether}(0, oldId, 2 ether);
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.StaleListing.selector);
        miner.buy{value: 2 ether}(0, nextId, 1 ether);
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.IncorrectPayment.selector);
        miner.buy{value: 2 ether + 1}(0, nextId, 2 ether);
        vm.prank(bob);
        miner.buy{value: 2 ether}(0, nextId, 2 ether);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.ListingUnavailable.selector);
        miner.cancel(0);
    }

    function testMarketOwnerAuthorizationAndDuplicateListing() public {
        _ready(0, alice);
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.NotTokenOwner.selector);
        miner.list(0, 1 ether);
        uint256 listing = _list(0, 1 ether);
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.NotTokenOwner.selector);
        miner.cancel(0);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.AlreadyListed.selector);
        miner.list(0, 1 ether);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.SelfPurchase.selector);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
    }

    function testTransferAndStakeInvalidateListing() public {
        _ready(0, alice);
        _list(0, 1 ether);
        vm.prank(alice);
        miner.transferFrom(alice, bob, 0);
        assertFalse(miner.getListing(0).active);
        (GenesisMiner.MarketListing[] memory rows, uint256 total) = miner.getActiveListings(0, 100);
        assertEq(rows.length, 0);
        assertEq(total, 0);
        _ready(1, alice);
        _list(1, 2 ether);
        MockMiningPool pool = new MockMiningPool();
        vm.startPrank(admin);
        miner.setMiningPool(address(pool));
        miner.setStakingOpen(true);
        vm.stopPrank();
        vm.startPrank(alice);
        miner.approve(address(pool), 1);
        pool.stake(miner, 1);
        assertFalse(miner.getListing(1).active);
        vm.expectRevert(GenesisMiner.TokenStaked.selector);
        miner.list(1, 2 ether);
        vm.expectRevert(GenesisMiner.TokenStaked.selector);
        miner.transferFrom(alice, bob, 1);
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(GenesisMiner.PoolHasLocks.selector);
        miner.setMiningPool(address(0));
        vm.prank(alice);
        pool.unstake(miner, 1);
        assertFalse(miner.isStaked(1));
    }

    function testStakingStartsClosedAndDoesNotOpenWithMintingOrTime() public {
        assertFalse(miner.stakingOpen());
        _ready(0, alice);
        MockMiningPool pool = new MockMiningPool();
        vm.prank(admin);
        miner.setMiningPool(address(pool));
        vm.prank(alice);
        miner.approve(address(pool), 0);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.StakingClosed.selector);
        pool.stake(miner, 0);
        _open();
        vm.prank(alice);
        miner.mint{value: PRICE}(bytes32(0));
        vm.warp(block.timestamp + 365 days);
        assertFalse(miner.stakingOpen());
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.StakingClosed.selector);
        pool.stake(miner, 0);
        assertFalse(miner.isStaked(0));
        assertEq(miner.totalStakeLocks(), 0);
    }

    function testOnlyOwnerCanOpenAndCloseStaking() public {
        MockMiningPool pool = new MockMiningPool();
        vm.prank(admin);
        miner.setMiningPool(address(pool));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        miner.setStakingOpen(true);
        assertFalse(miner.stakingOpen());
        vm.expectEmit(false, false, false, true, address(miner));
        emit GenesisMiner.StakingOpenChanged(true);
        vm.prank(admin);
        miner.setStakingOpen(true);
        assertTrue(miner.stakingOpen());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        miner.setStakingOpen(false);
        assertTrue(miner.stakingOpen());
        vm.expectEmit(false, false, false, true, address(miner));
        emit GenesisMiner.StakingOpenChanged(false);
        vm.prank(admin);
        miner.setStakingOpen(false);
        assertFalse(miner.stakingOpen());
    }

    function testOpeningStakingRequiresConfiguredPoolContract() public {
        vm.startPrank(admin);
        vm.expectRevert(GenesisMiner.InvalidConfiguration.selector);
        miner.setStakingOpen(true);
        miner.setStakingOpen(false);
        vm.stopPrank();
        MockMiningPool pool = new MockMiningPool();
        vm.prank(admin);
        miner.setMiningPool(address(pool));
        vm.etch(address(pool), hex"");
        vm.prank(admin);
        vm.expectRevert(GenesisMiner.InvalidConfiguration.selector);
        miner.setStakingOpen(true);
        assertFalse(miner.stakingOpen());
    }

    function testReserveRecipientCanStakeWithoutTransfer() public {
        MockMiningPool pool = new MockMiningPool();
        vm.startPrank(admin);
        miner.setMiningPool(address(pool));
        miner.setStakingOpen(true);
        miner.approve(address(pool), 0);
        pool.stake(miner, 0);
        vm.stopPrank();
        assertEq(miner.ownerOf(0), admin);
        assertTrue(miner.isStaked(0));
        assertEq(miner.stakedOwner(0), admin);
        assertEq(miner.totalStakeLocks(), 1);
    }

    function testClosingStakingBlocksNewLocksAndAllowsUnlock() public {
        _ready(0, alice);
        _ready(1, alice);
        MockMiningPool pool = new MockMiningPool();
        vm.startPrank(admin);
        miner.setMiningPool(address(pool));
        miner.setStakingOpen(true);
        vm.stopPrank();
        vm.startPrank(alice);
        miner.setApprovalForAll(address(pool), true);
        pool.stake(miner, 0);
        vm.stopPrank();
        vm.prank(admin);
        miner.setStakingOpen(false);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.StakingClosed.selector);
        pool.stake(miner, 1);
        assertTrue(miner.isStaked(0));
        assertEq(miner.totalStakeLocks(), 1);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.OnlyMiningPool.selector);
        miner.unlockFromStake(0, alice);
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.InvalidStake.selector);
        pool.unstake(miner, 0);
        vm.prank(alice);
        pool.unstake(miner, 0);
        assertFalse(miner.isStaked(0));
        assertEq(miner.stakedOwner(0), address(0));
        assertEq(miner.totalStakeLocks(), 0);
        vm.prank(admin);
        miner.setStakingOpen(true);
        vm.prank(alice);
        pool.stake(miner, 1);
        assertTrue(miner.isStaked(1));
        assertEq(miner.totalStakeLocks(), 1);
    }

    function testPublicMintCanStakeImmediatelyButStillRequiresApproval() public {
        _open();
        vm.prank(alice);
        uint256 id = miner.mint{value: PRICE}(bytes32(0));
        uint256 fixedPower = miner.getToken(id).power;
        MockMiningPool pool = new MockMiningPool();
        vm.startPrank(admin);
        miner.setMiningPool(address(pool)); miner.setStakingOpen(true);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(GenesisMiner.InvalidStake.selector); pool.stake(miner, id);
        miner.setApprovalForAll(address(pool), true);
        pool.stake(miner, id);
        vm.expectRevert(GenesisMiner.TokenStaked.selector); pool.stake(miner, id);
        pool.unstake(miner, id);
        vm.stopPrank();
        assertFalse(miner.isStaked(id));
        assertEq(miner.getToken(id).power, fixedPower);
    }

    function testPaginationRemovalDoesNotLoseTokenZero() public {
        for (uint256 i; i < 4; ++i) { _ready(i, alice); _list(i, i + 1); }
        (GenesisMiner.MarketListing[] memory first, uint256 total) = miner.getActiveListings(0, 2);
        assertEq(total, 4);
        assertEq(first[0].tokenId, 0);
        vm.prank(alice);
        miner.cancel(0);
        (GenesisMiner.MarketListing[] memory all, uint256 remaining) = miner.getActiveListings(0, 100);
        assertEq(all.length, 3);
        assertEq(remaining, 3);
        bool[4] memory seen;
        for (uint256 i; i < all.length; ++i) { assertFalse(seen[all[i].tokenId]); seen[all[i].tokenId] = true; }
        assertTrue(seen[1] && seen[2] && seen[3]);
        vm.expectRevert(GenesisMiner.InvalidPagination.selector);
        miner.getActiveListings(0, 101);
    }

    function testRejectingSellerRollsBackPaymentNFTListingAndFees() public {
        _open();
        vm.prank(alice);
        miner.mint{value: PRICE}(bytes32(0));
        _ready(1, alice);
        uint256 priorListing = _list(1, 0.2 ether);
        vm.prank(bob);
        miner.buy{value: 0.2 ether}(1, priorListing, 0.2 ether);
        RejectingSeller seller = new RejectingSeller();
        vm.prank(admin);
        miner.safeTransferFrom(admin, address(seller), 0);
        seller.listMiner(miner, 0, 1 ether);
        uint256 listing = miner.getListing(0).listingId;
        uint256 buyerBefore = bob.balance;
        uint256 sellerBefore = address(seller).balance;
        uint256 contractBefore = address(miner).balance;
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.PaymentFailed.selector);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
        assertEq(bob.balance, buyerBefore);
        assertEq(address(seller).balance, sellerBefore);
        assertEq(address(miner).balance, contractBefore);
        assertEq(miner.ownerOf(0), address(seller));
        GenesisMiner.Listing memory restored = miner.getListing(0);
        assertTrue(restored.active);
        assertEq(restored.listingId, listing);
        assertEq(restored.seller, address(seller));
        assertEq(restored.price, 1 ether);
        (GenesisMiner.MarketListing[] memory rows, uint256 total) = miner.getActiveListings(0, 100);
        assertEq(total, 1);
        assertEq(rows.length, 1);
        assertEq(rows[0].tokenId, 0);
        assertEq(rows[0].listingId, listing);
        assertEq(miner.marketFeeBalance(), 0.01 ether);
        assertEq(miner.saleRevenue(), PRICE);
    }

    function testRejectingBuyerRollsBackPaymentNFTListingAndFees() public {
        _open();
        vm.prank(alice);
        miner.mint{value: PRICE}(bytes32(0));
        _ready(0, alice);
        uint256 listing = _list(0, 1 ether);
        RejectingBuyer buyer = new RejectingBuyer();
        uint256 payerBefore = address(this).balance;
        uint256 sellerBefore = alice.balance;
        vm.expectRevert("buyer rejects NFT");
        buyer.buyMiner{value: 1 ether}(miner, 0, listing, 1 ether);
        assertEq(address(this).balance, payerBefore);
        assertEq(address(buyer).balance, 0);
        assertEq(alice.balance, sellerBefore);
        assertEq(address(miner).balance, PRICE);
        assertEq(miner.ownerOf(0), alice);
        GenesisMiner.Listing memory restored = miner.getListing(0);
        assertTrue(restored.active);
        assertEq(restored.listingId, listing);
        assertEq(restored.seller, alice);
        assertEq(restored.price, 1 ether);
        (GenesisMiner.MarketListing[] memory rows, uint256 total) = miner.getActiveListings(0, 100);
        assertEq(total, 1);
        assertEq(rows.length, 1);
        assertEq(rows[0].tokenId, 0);
        assertEq(rows[0].listingId, listing);
        assertEq(miner.marketFeeBalance(), 0);
        assertEq(miner.saleRevenue(), PRICE);
    }

    function testSellerPaymentReentryCannotBuyValidSecondListing() public {
        _open();
        vm.prank(alice);
        miner.mint{value: PRICE}(bytes32(0));
        ReenteringSeller seller = new ReenteringSeller(miner);
        vm.prank(admin);
        miner.safeTransferFrom(admin, address(seller), 0);
        seller.listMiner(0, 1 ether);
        uint256 listing = miner.getListing(0).listingId;
        _ready(1, alice);
        uint256 targetListing = _list(1, 0.5 ether);
        seller.setTarget(1, targetListing, 0.5 ether);
        uint256 targetSellerBefore = alice.balance;
        vm.prank(bob);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
        assertTrue(seller.reentryBlocked());
        assertEq(seller.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(address(seller).balance, 0.95 ether);
        assertEq(miner.ownerOf(0), bob);
        assertEq(miner.ownerOf(1), alice);
        assertTrue(miner.getListing(1).active);
        assertEq(miner.getListing(1).listingId, targetListing);
        assertEq(alice.balance, targetSellerBefore);
        assertEq(miner.marketFeeBalance(), 0.05 ether);
        assertEq(miner.saleRevenue(), PRICE);
        assertEq(address(miner).balance, PRICE + 0.05 ether);
        // The same funded call and listing succeed after the first buy has finished.
        seller.buyTarget();
        assertEq(miner.ownerOf(1), address(seller));
        assertEq(address(seller).balance, 0.45 ether);
        assertEq(alice.balance - targetSellerBefore, 0.475 ether);
        assertEq(miner.marketFeeBalance(), 0.075 ether);
        assertEq(address(miner).balance, PRICE + 0.075 ether);
    }

    function testRevenueBudgetsCannotTouchMarketFees() public {
        _open();
        vm.prank(alice);
        miner.mint{value: PRICE}(bytes32(0));
        _ready(0, alice);
        uint256 listing = _list(0, 5 ether);
        uint256 sellerBefore = alice.balance;
        vm.prank(bob);
        miner.buy{value: 5 ether}(0, listing, 5 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        miner.withdrawSaleRevenue(payable(alice), PRICE / 4, true);
        RejectingSeller recipient = new RejectingSeller();
        uint256 adminBefore = admin.balance;
        vm.startPrank(admin);
        vm.expectRevert(GenesisMiner.InsufficientRevenue.selector);
        miner.withdrawSaleRevenue(payable(admin), PRICE, true);
        vm.expectRevert(GenesisMiner.PaymentFailed.selector);
        miner.withdrawSaleRevenue(payable(address(recipient)), PRICE / 4, true);
        assertEq(miner.liquidityWithdrawn(), 0);
        assertEq(address(miner).balance, PRICE + 0.25 ether);
        miner.withdrawSaleRevenue(payable(admin), PRICE / 4, true);
        miner.withdrawSaleRevenue(payable(admin), PRICE / 4, true);
        miner.withdrawSaleRevenue(payable(admin), PRICE / 4, false);
        miner.withdrawSaleRevenue(payable(admin), PRICE / 4, false);
        vm.expectRevert(GenesisMiner.InsufficientRevenue.selector);
        miner.withdrawSaleRevenue(payable(admin), 1, false);
        vm.stopPrank();
        assertEq(admin.balance - adminBefore, PRICE);
        assertEq(miner.liquidityWithdrawn(), PRICE / 2);
        assertEq(miner.operationsWithdrawn(), PRICE / 2);
        assertEq(alice.balance - sellerBefore, 4.75 ether);
        assertEq(address(miner).balance, 0.25 ether);
        assertEq(miner.marketFeeBalance(), 0.25 ether);
    }

    function testFuzzMarketFundsConserve(uint96 rawPrice) public {
        uint256 price = bound(uint256(rawPrice), 1, 50 ether);
        _ready(0, alice);
        uint256 listing = _list(0, price);
        uint256 buyerBefore = bob.balance;
        uint256 sellerBefore = alice.balance;
        vm.prank(bob);
        miner.buy{value: price}(0, listing, price);
        uint256 expectedFee = price * 500 / 10_000;
        assertEq(buyerBefore - bob.balance, price);
        assertEq(alice.balance - sellerBefore, price - expectedFee);
        assertEq(miner.marketFeeBalance(), expectedFee);
        assertEq(address(miner).balance, expectedFee);
    }

    function testMarketFeeRoundsDownAndListingCancellationHasNoFee() public {
        assertEq(miner.MARKET_FEE_BPS(), 500);
        _ready(0, alice);
        _list(0, 20);
        vm.prank(alice);
        miner.cancel(0);
        assertEq(miner.marketFeeBalance(), 0);
        assertEq(address(miner).balance, 0);
        uint256[5] memory prices = [uint256(1), 19, 20, 21, 101];
        uint256 totalPrice;
        uint256 totalFee;
        uint256 sellerBefore = alice.balance;
        for (uint256 i; i < prices.length; ++i) {
            if (i != 0) _ready(i, alice);
            uint256 listing = _list(i, prices[i]);
            uint256 fee = prices[i] / 20;
            vm.expectEmit(true, true, false, true, address(miner));
            emit GenesisMiner.MarketFeeAccrued(i, listing, fee);
            vm.expectEmit(true, true, true, true, address(miner));
            emit GenesisMiner.ListingFilled(i, listing, alice, bob, prices[i]);
            vm.prank(bob);
            miner.buy{value: prices[i]}(i, listing, prices[i]);
            totalPrice += prices[i];
            totalFee += fee;
        }
        assertEq(totalFee, 7);
        assertEq(miner.marketFeeBalance(), totalFee);
        assertEq(alice.balance - sellerBefore, totalPrice - totalFee);
        assertEq(address(miner).balance, totalFee);
        assertEq(miner.saleRevenue(), 0);
    }

    function testMarketFeesRemainSeparateFromDirectSellerPaymentAndSaleRevenue() public {
        _open();
        vm.prank(alice);
        miner.mint{value: PRICE}(bytes32(0));
        _ready(0, alice);
        uint256 listing = _list(0, 1 ether);
        uint256 sellerBefore = alice.balance;
        vm.prank(bob);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
        vm.startPrank(admin);
        vm.expectRevert(GenesisMiner.InsufficientMarketFees.selector);
        miner.withdrawMarketFees(payable(admin), 0.05 ether + 1);
        miner.withdrawMarketFees(payable(admin), 0.05 ether);
        assertEq(miner.marketFeeBalance(), 0);
        assertEq(miner.saleRevenue(), PRICE);
        assertEq(alice.balance - sellerBefore, 0.95 ether);
        assertEq(address(miner).balance, PRICE);
        vm.expectRevert(GenesisMiner.InsufficientMarketFees.selector);
        miner.withdrawMarketFees(payable(admin), 1);
        miner.withdrawSaleRevenue(payable(admin), PRICE / 2, true);
        miner.withdrawSaleRevenue(payable(admin), PRICE / 2, false);
        vm.expectRevert(GenesisMiner.InsufficientRevenue.selector);
        miner.withdrawSaleRevenue(payable(admin), 1, true);
        vm.stopPrank();
        assertEq(address(miner).balance, 0);
        assertEq(alice.balance - sellerBefore, 0.95 ether);
    }

    function testMarketFeeWithdrawalAuthorizationValidationAndFailedPayment() public {
        _ready(0, alice);
        uint256 listing = _list(0, 1 ether);
        uint256 sellerBefore = alice.balance;
        vm.prank(bob);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        miner.withdrawMarketFees(payable(alice), 0.05 ether);
        RejectingSeller recipient = new RejectingSeller();
        vm.startPrank(admin);
        vm.expectRevert(GenesisMiner.InvalidAddress.selector);
        miner.withdrawMarketFees(payable(address(0)), 1);
        vm.expectRevert(GenesisMiner.InvalidAddress.selector);
        miner.withdrawMarketFees(payable(address(miner)), 1);
        vm.expectRevert(GenesisMiner.NothingToWithdraw.selector);
        miner.withdrawMarketFees(payable(admin), 0);
        vm.expectRevert(GenesisMiner.InsufficientMarketFees.selector);
        miner.withdrawMarketFees(payable(admin), 0.05 ether + 1);
        vm.expectRevert(GenesisMiner.PaymentFailed.selector);
        miner.withdrawMarketFees(payable(address(recipient)), 0.05 ether);
        assertEq(miner.marketFeeBalance(), 0.05 ether);
        assertEq(address(miner).balance, 0.05 ether);
        uint256 before = admin.balance;
        vm.expectEmit(true, false, false, true, address(miner));
        emit GenesisMiner.MarketFeesWithdrawn(admin, 0.02 ether);
        miner.withdrawMarketFees(payable(admin), 0.02 ether);
        vm.stopPrank();
        assertEq(admin.balance - before, 0.02 ether);
        assertEq(miner.marketFeeBalance(), 0.03 ether);
        assertEq(alice.balance - sellerBefore, 0.95 ether);
        assertEq(address(miner).balance, 0.03 ether);
    }

    function testMarketFeeWithdrawalReentryCannotCollectTwice() public {
        _ready(0, alice);
        uint256 listing = _list(0, 1 ether);
        uint256 sellerBefore = alice.balance;
        vm.prank(bob);
        miner.buy{value: 1 ether}(0, listing, 1 ether);
        ReenteringFeeOwner feeOwner = new ReenteringFeeOwner(miner);
        vm.prank(admin);
        miner.transferOwnership(address(feeOwner));
        feeOwner.acceptMinerOwnership();
        feeOwner.withdrawFees(0.025 ether);
        assertTrue(feeOwner.reentryBlocked());
        assertEq(address(feeOwner).balance, 0.025 ether);
        assertEq(miner.marketFeeBalance(), 0.025 ether);
        assertEq(alice.balance - sellerBefore, 0.95 ether);
        assertEq(address(miner).balance, 0.025 ether);
    }

    function testBatchBonusAndStableIdentityLifetimeCap() public {
        _open();
        vm.startPrank(alice);
        uint256 first = miner.mintBatch{value: PRICE * 10}(10, bytes32(0));
        assertEq(miner.mintBonusBps(first), 300);
        vm.expectRevert(GenesisMiner.AgentMintLimit.selector);
        miner.mintBatch{value: PRICE * 12}(12, bytes32(0));
        uint256 next = miner.mintBatch{value: PRICE * 11}(11, bytes32(0));
        assertEq(miner.mintBonusBps(next), 600);
        miner.transferFrom(alice, bob, first);
        vm.stopPrank();
        identity.setEligible(bob, true);
        identity.setAgentId(bob, keccak256("alice-agent"));
        vm.prank(bob);
        vm.expectRevert(GenesisMiner.AgentMintLimit.selector);
        miner.mint{value: PRICE}(bytes32(0));
        assertFalse(miner.isMintEligible(bob));
        identity.setAgentId(alice, keccak256("second-agent"));
        vm.prank(alice);
        uint256 last = miner.mintBatch{value: PRICE * 21}(21, bytes32(0));
        assertEq(miner.mintBonusBps(last), 1000);
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.InvalidQuantity.selector);
        miner.mintBatch(22, bytes32(0));
    }

    function testFullPublicAllocationThenActualCompletion() public {
        _open();
        for (uint256 i; i < 900; ++i) {
            identity.setAgentId(alice, keccak256(abi.encode("allocation", i)));
            vm.prank(alice);
            miner.mintBatch{value: PRICE * 21}(21, bytes32(i));
        }
        assertTrue(miner.genesisComplete());
        assertEq(miner.totalAllocated(), 21_000);
        assertEq(miner.publicMinted(), 18_900);
        assertEq(miner.saleRevenue(), 39.69 ether);
        assertFalse(miner.stakingOpen());
        vm.prank(alice);
        vm.expectRevert(GenesisMiner.SoldOut.selector);
        miner.mint{value: PRICE}(bytes32(0));
    }

}

contract ReenteringFeeOwner {
    GenesisMiner private immutable miner;
    bool public reentryBlocked;

    constructor(GenesisMiner target) { miner = target; }
    function acceptMinerOwnership() external { miner.acceptOwnership(); }
    function withdrawFees(uint256 amount) external { miner.withdrawMarketFees(payable(address(this)), amount); }
    receive() external payable {
        try miner.withdrawMarketFees(payable(address(this)), msg.value) {}
        catch { reentryBlocked = true; }
    }
}
