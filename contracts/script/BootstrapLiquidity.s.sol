// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";

interface IBootstrapFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IBootstrapPair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IBootstrapRouter {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(
        address token, uint256 amountTokenDesired, uint256 amountTokenMin,
        uint256 amountETHMin, address to, uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IBootstrapBalance {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice One explicitly selected preparation step, with an external signer and public manifest.
/// @dev No private key, Agent ID requirement for administrators, or automatic opening of gates.
/// Postconditions run in Foundry's simulation. Verify final on-chain state after any approved broadcast.
contract BootstrapLiquidity is Script {
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    struct Context {
        GenesisMiner genesis;
        FourAgentCoin token;
        MiningPool pool;
        address admin;
        address lpTreasury;
        address operationsTreasury;
        address lpTokenRecipient;
        address pair;
    }

    struct LiquidityPlan {
        uint256 tokens;
        uint256 bnb;
        uint256 minTokens;
        uint256 minBNB;
        uint256 minimumLiquidity;
        uint256 deadline;
    }

    function run() external {
        string memory manifest = vm.readFile(vm.envOr("DEPLOYMENT_MANIFEST", string("../config/deployments.bsc.json")));
        require(vm.parseJsonBool(manifest, ".enabled"), "Manifest disabled; verify deployment and identity first");
        require(vm.parseJsonUint(manifest, ".schemaVersion") == 1, "Unsupported deployment manifest schema");
        require(block.chainid == 56 && vm.parseJsonUint(manifest, ".chainId") == 56, "BSC mainnet only");
        address signer = vm.envAddress("SIGNER_ADDRESS");
        require(signer != address(0), "Missing external signer");
        string memory action = vm.envString("BOOTSTRAP_ACTION");
        Context memory c = _context(manifest);
        _verify(manifest, c);

        bytes32 selected = keccak256(bytes(action));
        if (selected == keccak256("withdrawLP")) _withdraw(manifest, c, signer, true);
        else if (selected == keccak256("withdrawOperations")) _withdraw(manifest, c, signer, false);
        else if (selected == keccak256("createPair")) _createPair(manifest, c, signer);
        else if (selected == keccak256("registerPair")) _registerPair(manifest, c, signer);
        else if (selected == keccak256("approve")) _approve(manifest, c, signer);
        else if (selected == keccak256("addLiquidity")) _addLiquidity(manifest, c, signer);
        else if (selected == keccak256("revokeApproval")) _revokeApproval(c, signer);
        else if (selected == keccak256("removeTreasuryExemption")) _removeExemption(manifest, c, signer);
        else revert("Unknown BOOTSTRAP_ACTION; select exactly one documented step");
        _gates(manifest, c);
        console2.log("Completed simulation step", action);
        console2.log("Broadcast requires separate approval; verify final receipts and state afterwards");
    }

    function _context(string memory m) private view returns (Context memory c) {
        c.genesis = GenesisMiner(vm.parseJsonAddress(m, ".contracts.genesis.address"));
        c.token = FourAgentCoin(vm.parseJsonAddress(m, ".contracts.token.address"));
        c.pool = MiningPool(vm.parseJsonAddress(m, ".contracts.pool.address"));
        c.admin = vm.parseJsonAddress(m, ".roles.admin");
        c.lpTreasury = vm.parseJsonAddress(m, ".roles.lpTreasury");
        c.operationsTreasury = vm.parseJsonAddress(m, ".roles.operationsTreasury");
        c.lpTokenRecipient = vm.parseJsonAddress(m, ".roles.lpTokenRecipient");
        c.pair = vm.parseJsonAddress(m, ".pancake.pair");
        require(c.admin != address(0) && c.lpTreasury != address(0) && c.operationsTreasury != address(0) && c.lpTokenRecipient != address(0), "Missing role");
        require(c.lpTreasury != ROUTER && c.lpTreasury != FACTORY && c.lpTreasury != c.pair && c.lpTokenRecipient != c.pair, "Invalid LP role");
    }

    function _verify(string memory m, Context memory c) private view {
        _code(m, ".contracts.genesis.codeHash", address(c.genesis));
        _code(m, ".contracts.token.codeHash", address(c.token));
        _code(m, ".contracts.pool.codeHash", address(c.pool));
        require(keccak256(bytes(vm.parseJsonString(m, ".expected.deploymentMode"))) == keccak256("constructor_non_upgradeable"), "Unexpected deployment mode");
        require(c.genesis.owner() == c.admin && c.token.owner() == c.admin && c.pool.owner() == c.admin, "Admin binding mismatch");
        require(c.genesis.miningPool() == address(c.pool) && c.token.miningPool() == address(c.pool) && address(c.pool.genesis()) == address(c.genesis) && address(c.pool.token()) == address(c.token), "Core binding mismatch");
        require(c.genesis.reserveRecipient() == vm.parseJsonAddress(m, ".roles.reserveRecipient") && c.token.lpRecipient() == c.lpTreasury, "Allocation role mismatch");
        address fees = vm.parseJsonAddress(m, ".roles.feeRecipient");
        require(fees != address(0) && c.token.feeRecipient() == fees && c.pool.feeRecipient() == fees, "Fee role mismatch");
        require(c.token.SWAP_TAX_BPS() == 100 && c.pool.feeBps() == 300 && c.genesis.MARKET_FEE_BPS() == 500, "Unexpected fees");
        require(c.pool.initialBaseReward() == _uint(m, ".expected.initialBaseRewardWei"), "Reward mismatch");
        require(vm.parseJsonBool(m, ".identity.verified") && vm.parseJsonBool(m, ".identity.stableAgentIdSemanticsVerified") && vm.parseJsonBool(m, ".identity.adapterRegistryBindingVerified"), "Identity evidence unverified");
        _evidence(m, ".identity.officialSourceUrl", ".identity.verificationEvidence");
        // The allowed source domain is a configuration guard; reviewed evidence
        // must still establish the actual official identity/registry provenance.
        require(_officialBinanceURL(vm.parseJsonString(m, ".identity.officialSourceUrl")), "Official Binance identity source required");
        require(bytes(vm.parseJsonString(m, ".identity.verifiedAt")).length != 0, "Missing identity verification date");
        address adapter = vm.parseJsonAddress(m, ".identity.adapterAddress");
        address registry = vm.parseJsonAddress(m, ".identity.registryAddress");
        _code(m, ".identity.adapterCodeHash", adapter);
        _code(m, ".identity.registryCodeHash", registry);
        require(c.genesis.identityVerifier() == adapter, "Identity adapter mismatch");
        bytes memory selector = vm.parseJsonBytes(m, ".identity.adapterRegistrySelector");
        require(selector.length == 4 && keccak256(selector) != keccak256(hex"00000000"), "Missing actual registry selector");
        (bool ok, bytes memory result) = adapter.staticcall(selector);
        require(ok && result.length == 32 && abi.decode(result, (address)) == registry, "Adapter registry binding mismatch");
        require(vm.parseJsonBool(m, ".pancake.verified"), "Pancake evidence unverified");
        _evidence(m, ".pancake.officialSourceUrl", ".pancake.verificationEvidence");
        require(_prefix(vm.parseJsonString(m, ".pancake.officialSourceUrl"), "https://developer.pancakeswap.finance/"), "Official Pancake source required");
        require(vm.parseJsonUint(m, ".pancake.observedBlockNumber") > 0 && vm.parseJsonBytes32(m, ".pancake.observedBlockHash") != bytes32(0), "Missing Pancake observation");
        require(vm.parseJsonAddress(m, ".pancake.router") == ROUTER && vm.parseJsonAddress(m, ".pancake.factory") == FACTORY && vm.parseJsonAddress(m, ".pancake.wBNB") == WBNB, "Not official BSC Pancake V2 addresses");
        _code(m, ".pancake.routerCodeHash", ROUTER);
        _code(m, ".pancake.factoryCodeHash", FACTORY);
        _code(m, ".pancake.wBNBCodeHash", WBNB);
        require(IBootstrapRouter(ROUTER).factory() == FACTORY && IBootstrapRouter(ROUTER).WETH() == WBNB, "Router binding mismatch");
        if (c.pair != address(0)) _pair(m, c);
        _gates(m, c);
    }

    function _withdraw(string memory m, Context memory c, address signer, bool liquidity) private {
        require(signer == c.admin, "Only configured admin can withdraw");
        uint256 amount = _uint(m, liquidity ? ".bootstrap.lpWithdrawalWei" : ".bootstrap.operationsWithdrawalWei");
        uint256 revenue = c.genesis.saleRevenue();
        uint256 budget = liquidity ? revenue / 2 : revenue - revenue / 2;
        uint256 used = liquidity ? c.genesis.liquidityWithdrawn() : c.genesis.operationsWithdrawn();
        require(amount > 0 && used <= budget && amount <= budget - used && address(c.genesis).balance >= amount, "Amount exceeds actual remaining sale budget");
        address payable recipient = payable(liquidity ? c.lpTreasury : c.operationsTreasury);
        require(recipient != address(c.genesis), "Invalid withdrawal recipient");
        vm.startBroadcast(signer);
        c.genesis.withdrawSaleRevenue(recipient, amount, liquidity);
        vm.stopBroadcast();
        require((liquidity ? c.genesis.liquidityWithdrawn() : c.genesis.operationsWithdrawn()) == used + amount, "Withdrawal accounting mismatch");
        console2.log("Withdrawn actual sale revenue wei", amount);
        console2.log("Recipient", recipient);
    }

    function _createPair(string memory m, Context memory c, address signer) private {
        require(signer == c.admin, "Only configured admin creates pair in this workflow");
        require(vm.parseJsonBool(m, ".bootstrap.expectedPairEmpty") && c.pair == address(0) && IBootstrapFactory(FACTORY).getPair(address(c.token), WBNB) == address(0), "Pair already exists; verify it and update manifest");
        vm.startBroadcast(signer);
        address pair = IBootstrapFactory(FACTORY).createPair(address(c.token), WBNB);
        vm.stopBroadcast();
        _pairIdentity(c, pair);
        require(!c.token.isTaxExempt(pair), "Pair must never be tax exempt");
        _empty(c, pair);
        console2.log("Created pair; record address/hash in manifest before registration", pair);
        console2.logBytes32(pair.codehash);
    }

    function _registerPair(string memory m, Context memory c, address signer) private {
        require(signer == c.admin, "Only configured admin registers pair");
        _pair(m, c);
        require(vm.parseJsonBool(m, ".bootstrap.expectedPairEmpty"), "Only first empty pair bootstrap is supported");
        _empty(c, c.pair);
        require(!c.token.isAMMPair(c.pair), "Pair already registered");
        vm.startBroadcast(signer);
        c.token.setAMMPair(c.pair, true);
        vm.stopBroadcast();
        require(c.token.isAMMPair(c.pair) && !c.token.isTaxExempt(c.pair), "Pair registration mismatch");
    }

    function _approve(string memory m, Context memory c, address signer) private {
        require(signer == c.lpTreasury, "Only configured LP treasury can approve");
        LiquidityPlan memory p = _plan(m, c);
        require(c.token.allowance(c.lpTreasury, ROUTER) == 0, "Revoke existing allowance first");
        vm.startBroadcast(signer);
        require(c.token.approve(ROUTER, p.tokens), "Approval failed");
        vm.stopBroadcast();
        require(c.token.allowance(c.lpTreasury, ROUTER) == p.tokens, "Exact approval mismatch");
    }

    function _addLiquidity(string memory m, Context memory c, address signer) private {
        require(signer == c.lpTreasury, "Only configured LP treasury can add liquidity");
        LiquidityPlan memory p = _plan(m, c);
        require(c.token.allowance(c.lpTreasury, ROUTER) == p.tokens, "Exact approval required");
        uint256 beforeTokens = c.token.balanceOf(c.lpTreasury);
        uint256 beforeBNB = c.lpTreasury.balance;
        uint256 beforeLP = IBootstrapPair(c.pair).balanceOf(c.lpTokenRecipient);
        // The token taxes pair transfers by 1%. Initial funding uses the existing
        // treasury exemption, so V2's exact-amount addLiquidityETH path is valid.
        vm.startBroadcast(signer);
        (uint256 tokens, uint256 bnb, uint256 minted) = IBootstrapRouter(ROUTER).addLiquidityETH{value: p.bnb}(
            address(c.token), p.tokens, p.minTokens, p.minBNB, c.lpTokenRecipient, p.deadline
        );
        vm.stopBroadcast();
        require(tokens >= p.minTokens && tokens <= p.tokens && bnb >= p.minBNB && bnb <= p.bnb && minted >= p.minimumLiquidity, "Liquidity result below bounds");
        require(c.token.balanceOf(c.lpTreasury) + tokens == beforeTokens && c.lpTreasury.balance + bnb == beforeBNB, "Actual usage/refund mismatch in simulation");
        require(IBootstrapPair(c.pair).balanceOf(c.lpTokenRecipient) == beforeLP + minted, "LP did not reach configured recipient");
        (uint112 r0, uint112 r1,) = IBootstrapPair(c.pair).getReserves();
        (uint256 tokenReserve, uint256 bnbReserve) = IBootstrapPair(c.pair).token0() == address(c.token) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        require(tokenReserve == tokens && bnbReserve == bnb && c.token.balanceOf(c.pair) == tokens && IBootstrapBalance(WBNB).balanceOf(c.pair) == bnb, "Reserve/actual funding mismatch");
        require(c.token.isAMMPair(c.pair) && !c.token.isTaxExempt(c.pair), "Pair tax configuration changed");
        console2.log("Actual token usage wei", tokens);
        console2.log("Actual BNB usage wei", bnb);
        console2.log("BNB refund wei", p.bnb - bnb);
        console2.log("LP received wei", minted);
        console2.log("Remaining router allowance wei", c.token.allowance(c.lpTreasury, ROUTER));
    }

    function _revokeApproval(Context memory c, address signer) private {
        require(signer == c.lpTreasury, "Only configured LP treasury can revoke");
        require(c.token.allowance(c.lpTreasury, ROUTER) > 0, "Allowance already zero");
        vm.startBroadcast(signer);
        require(c.token.approve(ROUTER, 0), "Revocation failed");
        vm.stopBroadcast();
        require(c.token.allowance(c.lpTreasury, ROUTER) == 0, "Allowance remains");
    }

    function _removeExemption(string memory m, Context memory c, address signer) private {
        require(signer == c.admin, "Only configured admin removes exemption");
        _pair(m, c);
        (uint112 r0, uint112 r1,) = IBootstrapPair(c.pair).getReserves();
        uint256 minimum = _uint(m, ".bootstrap.minimumLiquidityWei");
        require(minimum > 0 && r0 > 0 && r1 > 0 && IBootstrapPair(c.pair).balanceOf(c.lpTokenRecipient) >= minimum, "Verify funded pair and LP receipt first");
        require(c.token.isAMMPair(c.pair) && c.token.isTaxExempt(c.lpTreasury) && c.token.allowance(c.lpTreasury, ROUTER) == 0, "Verify registration/exemption and revoke allowance first");
        vm.startBroadcast(signer);
        c.token.setTaxExempt(c.lpTreasury, false);
        vm.stopBroadcast();
        require(!c.token.isTaxExempt(c.lpTreasury) && !c.token.isTaxExempt(c.pair), "Exemption remains");
    }

    function _plan(string memory m, Context memory c) private view returns (LiquidityPlan memory p) {
        _pair(m, c);
        require(vm.parseJsonBool(m, ".bootstrap.expectedPairEmpty"), "Only first empty pair bootstrap is supported");
        _empty(c, c.pair);
        require(c.token.isAMMPair(c.pair) && c.token.isTaxExempt(c.lpTreasury), "Register pair and retain treasury exemption first");
        p = LiquidityPlan({
            tokens: _uint(m, ".bootstrap.amountTokenWei"),
            bnb: _uint(m, ".bootstrap.amountBNBWei"),
            minTokens: _uint(m, ".bootstrap.minTokenWei"),
            minBNB: _uint(m, ".bootstrap.minBNBWei"),
            minimumLiquidity: _uint(m, ".bootstrap.minimumLiquidityWei"),
            deadline: vm.parseJsonUint(m, ".bootstrap.deadline")
        });
        require(p.tokens > 0 && p.tokens != type(uint256).max && p.bnb > 0 && p.minTokens > 0 && p.minTokens <= p.tokens && p.minBNB > 0 && p.minBNB <= p.bnb && p.minimumLiquidity > 0 && p.deadline > block.timestamp, "Set positive explicit LP amounts, minima and deadline");
        require(c.token.balanceOf(c.lpTreasury) >= p.tokens && c.lpTreasury.balance >= p.bnb, "Treasury lacks actual token/BNB principal");
    }

    function _pair(string memory m, Context memory c) private view {
        require(c.pair != address(0), "Create pair, verify and update manifest first");
        _code(m, ".pancake.pairCodeHash", c.pair);
        _pairIdentity(c, c.pair);
        require(!c.token.isTaxExempt(c.pair), "Pair must never be tax exempt");
    }

    function _pairIdentity(Context memory c, address pair) private view {
        require(pair.code.length > 0 && IBootstrapFactory(FACTORY).getPair(address(c.token), WBNB) == pair && IBootstrapPair(pair).factory() == FACTORY, "Factory/pair mismatch");
        address a = IBootstrapPair(pair).token0();
        address b = IBootstrapPair(pair).token1();
        require((a == address(c.token) && b == WBNB) || (a == WBNB && b == address(c.token)), "Pair tokens mismatch");
    }

    function _empty(Context memory c, address pair) private view {
        (uint112 r0, uint112 r1,) = IBootstrapPair(pair).getReserves();
        require(r0 == 0 && r1 == 0 && IBootstrapPair(pair).totalSupply() == 0 && c.token.balanceOf(pair) == 0 && IBootstrapBalance(WBNB).balanceOf(pair) == 0, "First LP requires a completely empty pair");
    }

    function _gates(string memory m, Context memory c) private view {
        require(c.genesis.mintOpen() == vm.parseJsonBool(m, ".expected.mintOpen") && c.genesis.stakingOpen() == vm.parseJsonBool(m, ".expected.stakingOpen") && c.pool.miningOpen() == vm.parseJsonBool(m, ".expected.miningOpen"), "Gate state differs from manifest");
    }

    function _code(string memory m, string memory key, address target) private view {
        bytes32 expected = vm.parseJsonBytes32(m, key);
        require(target != address(0) && target.code.length > 0 && expected != bytes32(0) && target.codehash == expected, "Runtime code hash mismatch");
    }

    function _evidence(string memory m, string memory sourceKey, string memory evidenceKey) private pure {
        bytes memory source = bytes(vm.parseJsonString(m, sourceKey));
        require(source.length > 8 && bytes(vm.parseJsonString(m, evidenceKey)).length > 0, "Missing verification source/evidence");
        require(source[0] == "h" && source[1] == "t" && source[2] == "t" && source[3] == "p" && source[4] == "s" && source[5] == ":" && source[6] == "/" && source[7] == "/", "Verification source must use HTTPS");
    }

    function _uint(string memory m, string memory key) private pure returns (uint256) {
        string memory value = vm.parseJsonString(m, key);
        bytes memory digits = bytes(value);
        require(digits.length > 0, "Missing decimal integer string");
        for (uint256 i; i < digits.length; ++i) require(digits[i] >= "0" && digits[i] <= "9", "Expected decimal integer string");
        return vm.parseUint(value);
    }

    function _officialBinanceURL(string memory url) private pure returns (bool) {
        return _prefix(url, "https://binance.com/") || _prefix(url, "https://www.binance.com/")
            || _prefix(url, "https://web3.binance.com/") || _prefix(url, "https://developers.binance.com/");
    }

    function _prefix(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory data = bytes(value);
        bytes memory expected = bytes(prefix);
        if (data.length < expected.length) return false;
        for (uint256 i; i < expected.length; ++i) if (data[i] != expected[i]) return false;
        return true;
    }
}
