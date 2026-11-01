// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";

interface IPancakeV2RouterFork {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline)
        external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
}

interface IPancakeV2FactoryFork {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakeV2PairFork is IERC20 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function MINIMUM_LIQUIDITY() external view returns (uint256);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 timestampLast);
}

/// @dev Opt-in only: FOUNDRY_PROFILE=bsc_fork, BSC_RPC_URL and an explicit BSC_FORK_BLOCK_NUMBER.
/// Uses real BSC V2 bytecode with locally created tokens/funds. No broadcast, real funds or identity attestation.
contract PancakeV2ForkTest is Test {
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint256 constant LP_TOKENS = 1_050_000 ether;
    uint256 constant LP_BNB = 19.845 ether;

    address admin = makeAddr("fork-admin");
    address treasury = makeAddr("fork-lp-treasury");
    address lpHolder = makeAddr("fork-lp-token-recipient");
    address fees = makeAddr("fork-fees");
    address alice = makeAddr("fork-alice");
    address bob = makeAddr("fork-bob");
    FourAgentCoin token;
    IPancakeV2RouterFork router;
    IPancakeV2PairFork pair;

    function setUp() public {
        string memory rpc = vm.envString("BSC_RPC_URL");
        uint256 sourceBlock = vm.envUint("BSC_FORK_BLOCK_NUMBER");
        require(sourceBlock > 0, "BSC_FORK_BLOCK_NUMBER must be explicit and positive");
        vm.createSelectFork(rpc, sourceBlock);
        bytes memory sourceChain = vm.rpc("eth_chainId", "[]");
        uint256 chainId;
        require(sourceChain.length > 0 && sourceChain.length <= 32, "Invalid RPC chain ID encoding");
        for (uint256 i; i < sourceChain.length; ++i) chainId = (chainId << 8) | uint8(sourceChain[i]);
        assertEq(chainId, 56, "RPC must be BSC mainnet");
        assertEq(block.chainid, 56, "Fork source chain must be BSC");
        assertEq(block.number, sourceBlock);
        // Read the selected source header via BLOCKHASH, without relying on JSON object encoding.
        vm.roll(sourceBlock + 1);
        bytes32 sourceHash = blockhash(sourceBlock);
        assertNotEq(sourceHash, bytes32(0), "Selected source block hash unavailable");
        emit log_named_uint("BSC source block", sourceBlock);
        emit log_named_bytes32("BSC source block hash", sourceHash);
        vm.roll(sourceBlock);
        vm.chainId(31337);
        assertEq(block.chainid, 31337, "All mutations must remain local");

        assertGt(ROUTER.code.length, 0, "Real router bytecode missing");
        assertGt(FACTORY.code.length, 0, "Real factory bytecode missing");
        assertGt(WBNB.code.length, 0, "Real WBNB bytecode missing");
        router = IPancakeV2RouterFork(ROUTER);
        assertEq(router.factory(), FACTORY);
        assertEq(router.WETH(), WBNB);

        vm.prank(admin);
        token = new FourAgentCoin(treasury, fees);
        assertEq(token.owner(), admin);
        assertEq(token.balanceOf(treasury), LP_TOKENS);
        assertTrue(token.isTaxExempt(treasury));
        assertFalse(token.isTaxExempt(fees));
        assertEq(IPancakeV2FactoryFork(FACTORY).getPair(address(token), WBNB), address(0));
        pair = IPancakeV2PairFork(IPancakeV2FactoryFork(FACTORY).createPair(address(token), WBNB));
        assertGt(address(pair).code.length, 0);
        assertEq(pair.factory(), FACTORY);
        assertEq(IPancakeV2FactoryFork(FACTORY).getPair(address(token), WBNB), address(pair));
        assertTrue((pair.token0() == address(token) && pair.token1() == WBNB) || (pair.token1() == address(token) && pair.token0() == WBNB));
        vm.prank(admin);
        token.setAMMPair(address(pair), true);
        assertFalse(token.isTaxExempt(address(pair)), "Registering a pair must not exempt it");
        vm.deal(treasury, 100 ether);
        vm.deal(alice, 10 ether);
    }

    function testSourceContractsAndSeparateLocalRoles() public view {
        assertEq(block.chainid, 31337);
        assertNotEq(admin, treasury);
        assertNotEq(treasury, fees);
        assertNotEq(treasury, lpHolder);
        assertEq(token.totalSupply(), LP_TOKENS);
        assertEq(token.miningMinted(), 0);
        assertEq(token.balanceOf(admin), 0);
        assertEq(token.balanceOf(fees), 0);
        assertFalse(token.isTaxExempt(alice));
    }

    function testInitialLiquidityIsUntaxedAndSharesGoToSeparateRecipient() public {
        uint256 treasuryBNBBefore = treasury.balance;
        uint256 liquidity = _seed(LP_TOKENS, LP_BNB);
        (uint256 tokenReserve, uint256 nativeReserve) = _reserves();
        assertEq(tokenReserve, LP_TOKENS);
        assertEq(nativeReserve, LP_BNB);
        assertEq(token.balanceOf(address(pair)), tokenReserve);
        assertEq(IERC20(WBNB).balanceOf(address(pair)), nativeReserve);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(fees), 0, "Default treasury exemption must avoid liquidity tax");
        assertEq(treasury.balance, treasuryBNBBefore - LP_BNB);
        uint256 totalLP = Math.sqrt(LP_TOKENS * LP_BNB);
        assertEq(pair.totalSupply(), totalLP);
        assertEq(pair.balanceOf(address(0)), pair.MINIMUM_LIQUIDITY());
        assertEq(liquidity, totalLP - pair.MINIMUM_LIQUIDITY());
        assertEq(pair.balanceOf(lpHolder), liquidity);
        assertEq(pair.balanceOf(treasury), 0);
        assertEq(pair.balanceOf(admin), 0);
        emit log_named_address("Local pair using real BSC factory", address(pair));
        emit log_named_uint("LP shares held by separate recipient", liquidity);
    }

    function testSupportingFeeBuySellTaxOnePercentAndOrdinaryTransferUntaxed() public {
        _seed(LP_TOKENS, LP_BNB);
        address[] memory buyPath = _path(WBNB, address(token));
        uint256 buyBNB = 0.01 ether;
        uint256 grossBought = router.getAmountsOut(buyBNB, buyPath)[1];
        uint256 buyTax = grossBought / 100;
        (uint256 tokenBefore, uint256 nativeBefore) = _reserves();
        vm.prank(alice);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: buyBNB}(grossBought - buyTax, buyPath, alice, block.timestamp + 60);
        assertEq(token.balanceOf(alice), grossBought - buyTax);
        assertEq(token.balanceOf(fees), buyTax);
        (uint256 tokenAfterBuy, uint256 nativeAfterBuy) = _reserves();
        assertEq(tokenAfterBuy, tokenBefore - grossBought);
        assertEq(nativeAfterBuy, nativeBefore + buyBNB);

        uint256 transferAmount = 1 ether;
        uint256 aliceBeforeTransfer = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, transferAmount);
        assertEq(token.balanceOf(bob), transferAmount);
        assertEq(token.balanceOf(alice), aliceBeforeTransfer - transferAmount);
        assertEq(token.balanceOf(fees), buyTax, "Ordinary wallet transfer must not be taxed");

        uint256 sold = token.balanceOf(alice) / 2;
        uint256 sellTax = sold / 100;
        address[] memory sellPath = _path(address(token), WBNB);
        uint256 expectedBNB = router.getAmountsOut(sold - sellTax, sellPath)[1];
        vm.prank(alice);
        token.approve(ROUTER, sold);
        uint256 aliceBNBBefore = alice.balance;
        uint256 aliceTokensBefore = token.balanceOf(alice);
        vm.prank(alice);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(sold, expectedBNB, sellPath, alice, block.timestamp + 60);
        assertEq(alice.balance, aliceBNBBefore + expectedBNB);
        assertEq(token.balanceOf(alice), aliceTokensBefore - sold);
        assertEq(token.balanceOf(fees), buyTax + sellTax);
        (uint256 tokenAfterSell, uint256 nativeAfterSell) = _reserves();
        assertEq(tokenAfterSell, tokenAfterBuy + sold - sellTax);
        assertEq(nativeAfterSell, nativeAfterBuy - expectedBNB);
        assertEq(token.totalSupply(), LP_TOKENS);
        assertFalse(token.isTaxExempt(address(pair)));
    }

    function testNonAdminCannotRegisterPairOrExemptThePair() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        token.setAMMPair(address(pair), false);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        token.setTaxExempt(address(pair), true);
        assertTrue(token.isAMMPair(address(pair)));
        assertFalse(token.isTaxExempt(address(pair)));
    }

    function testLiquidityWithoutAllowanceRevertsAllFundsAndShares() public {
        assertEq(token.allowance(treasury, ROUTER), 0);
        bytes32 beforeState = _liquidityState();
        vm.expectRevert(_error("TransferHelper: TRANSFER_FROM_FAILED"));
        vm.prank(treasury);
        router.addLiquidityETH{value: LP_BNB}(address(token), LP_TOKENS, LP_TOKENS, LP_BNB, lpHolder, block.timestamp + 60);
        assertEq(_liquidityState(), beforeState);
    }

    function testExpiredLiquidityDeadlineRevertsAllFundsAndShares() public {
        _approveTreasury(LP_TOKENS);
        bytes32 beforeState = _liquidityState();
        vm.expectRevert(_error("PancakeRouter: EXPIRED"));
        vm.prank(treasury);
        router.addLiquidityETH{value: LP_BNB}(address(token), LP_TOKENS, LP_TOKENS, LP_BNB, lpHolder, block.timestamp - 1);
        assertEq(_liquidityState(), beforeState);
    }

    function testBothLiquidityMinimumsRevertAtomicallyAgainstExistingReserves() public {
        _seed(1_000_000 ether, 10 ether);
        _approveTreasury(20_000 ether);
        bytes32 beforeState = _liquidityState();
        vm.expectRevert(_error("PancakeRouter: INSUFFICIENT_B_AMOUNT"));
        vm.prank(treasury);
        router.addLiquidityETH{value: 1 ether}(address(token), 20_000 ether, 20_000 ether, 0.3 ether, lpHolder, block.timestamp + 60);
        assertEq(_liquidityState(), beforeState);
        vm.expectRevert(_error("PancakeRouter: INSUFFICIENT_A_AMOUNT"));
        vm.prank(treasury);
        router.addLiquidityETH{value: 0.1 ether}(address(token), 20_000 ether, 15_000 ether, 0.1 ether, lpHolder, block.timestamp + 60);
        assertEq(_liquidityState(), beforeState);
    }

    function testDifferentFundingActorCannotSpendTreasuryAllocation() public {
        _approveTreasury(LP_TOKENS);
        assertEq(token.balanceOf(alice), 0);
        bytes32 beforeState = _liquidityState();
        uint256 aliceBNBBefore = alice.balance;
        vm.expectRevert(_error("TransferHelper: TRANSFER_FROM_FAILED"));
        vm.prank(alice);
        router.addLiquidityETH{value: 1 ether}(address(token), 10_000 ether, 10_000 ether, 1 ether, lpHolder, block.timestamp + 60);
        assertEq(_liquidityState(), beforeState);
        assertEq(alice.balance, aliceBNBBefore);
    }

    function _approveTreasury(uint256 amount) private {
        vm.prank(treasury);
        token.approve(ROUTER, amount);
    }

    function _seed(uint256 amountToken, uint256 amountBNB) private returns (uint256 liquidity) {
        _approveTreasury(amountToken);
        vm.prank(treasury);
        (uint256 usedToken, uint256 usedBNB, uint256 minted) = router.addLiquidityETH{value: amountBNB}(address(token), amountToken, amountToken, amountBNB, lpHolder, block.timestamp + 60);
        assertEq(usedToken, amountToken);
        assertEq(usedBNB, amountBNB);
        return minted;
    }

    function _reserves() private view returns (uint256 tokenReserve, uint256 nativeReserve) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        return pair.token0() == address(token) ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }

    function _liquidityState() private view returns (bytes32) {
        (uint256 tokenReserve, uint256 nativeReserve) = _reserves();
        return keccak256(abi.encode(token.balanceOf(treasury), treasury.balance, token.balanceOf(fees), token.balanceOf(address(pair)), IERC20(WBNB).balanceOf(address(pair)), tokenReserve, nativeReserve, pair.totalSupply(), pair.balanceOf(lpHolder), token.allowance(treasury, ROUTER)));
    }

    function _path(address from, address to) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }

    function _error(string memory reason) private pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", reason);
    }
}
