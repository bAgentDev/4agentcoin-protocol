// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";

contract LocalTokenMinter {
    function mint(FourAgentCoin token, address to, uint256 amount) external { token.mintMining(to, amount); }
}
contract LocalPair {
    function send(FourAgentCoin token, address to, uint256 amount) external { token.transfer(to, amount); }
}
contract FourAgentCoinTest is Test {
    FourAgentCoin token;
    LocalTokenMinter pool;
    LocalPair pair;
    address lp = makeAddr("lp");
    address fees = makeAddr("fees");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    function setUp() public {
        token = new FourAgentCoin(lp, fees);
        pool = new LocalTokenMinter();
        pair = new LocalPair();
        token.setMiningPool(address(pool));
    }
    function testAllocationsAndNoOwnerMintOrPostMiningPoolReplacement() public {
        assertEq(token.name(), "4AgentCoin");
        assertEq(token.symbol(), "4AGC");
        assertEq(token.balanceOf(lp), 1_050_000 ether);
        vm.expectRevert(FourAgentCoin.OnlyMiningPool.selector);
        token.mintMining(alice, 1);
        pool.mint(token, alice, token.MINING_ALLOCATION());
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(token.miningMinted(), token.MINING_ALLOCATION());
        vm.expectRevert(FourAgentCoin.MiningCapExceeded.selector);
        pool.mint(token, alice, 1);
        LocalTokenMinter replacement = new LocalTokenMinter();
        vm.expectRevert(FourAgentCoin.MiningPoolLocked.selector);
        token.setMiningPool(address(replacement));
    }
    function testOrdinaryTransfersAndLPBudgetHaveNoTaxRegisteredPairBuysSellsPayOnePercent() public {
        token.setAMMPair(address(pair), true);
        vm.prank(lp);
        token.transfer(address(pair), 10_000 ether);
        assertEq(token.balanceOf(fees), 0);
        pair.send(token, alice, 100 ether);
        assertEq(token.balanceOf(alice), 99 ether);
        assertEq(token.balanceOf(fees), 1 ether);
        vm.prank(alice);
        token.transfer(bob, 50 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        vm.prank(bob);
        token.transfer(address(pair), 50 ether);
        assertEq(token.balanceOf(fees), 1.5 ether);
        token.setTaxExempt(alice, true);
        pair.send(token, alice, 100 ether);
        assertEq(token.balanceOf(alice), 149 ether);
        assertEq(token.totalSupply(), token.LP_ALLOCATION());
    }
    function testUnregisteredPairDoesNotTaxAndOwnerControlsRegistry() public {
        pool.mint(token, alice, 100 ether);
        vm.prank(alice);
        token.transfer(address(pair), 100 ether);
        pair.send(token, bob, 100 ether);
        assertEq(token.balanceOf(fees), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        token.setAMMPair(address(pair), true);
        vm.expectRevert(FourAgentCoin.InvalidAddress.selector);
        token.setAMMPair(bob, true);
    }
    function testFuzzMiningNeverExceedsBudget(uint256 raw) public {
        uint256 amount = bound(raw, 1, token.MINING_ALLOCATION());
        pool.mint(token, alice, amount);
        assertEq(token.totalSupply(), token.LP_ALLOCATION() + amount);
        uint256 remaining = token.MINING_ALLOCATION() - amount;
        vm.expectRevert(FourAgentCoin.MiningCapExceeded.selector);
        pool.mint(token, bob, remaining + 1);
    }
}
