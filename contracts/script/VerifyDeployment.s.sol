// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";

interface IVerifyV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IVerifyV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IVerifyV2Pair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 timestamp);
    function totalSupply() external view returns (uint256);
    function balanceOf(address holder) external view returns (uint256);
}

/// @notice Read-only checks against a reviewed deployment manifest. Never broadcasts.
/// @dev Evidence fields record prior human verification; this script cannot establish
/// official registry provenance from a flag or URL alone. No administrator Agent ID is required.
contract VerifyDeployment is Script {
    address private constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function run() external view {
        string memory manifest = vm.readFile(vm.envOr("DEPLOYMENT_MANIFEST", string("../config/deployments.bsc.json")));
        require(vm.parseJsonBool(manifest, ".enabled"), "BLOCKED: deployment manifest is disabled");
        require(vm.parseJsonUint(manifest, ".schemaVersion") == 1, "Unsupported deployment manifest schema");
        require(vm.parseJsonUint(manifest, ".chainId") == 56 && block.chainid == 56, "BLOCKED: BSC mainnet chain 56 required");
        require(_same(vm.parseJsonString(manifest, ".expected.deploymentMode"), "uups_genesis_pool_fixed_token"), "Unexpected deployment mode");

        GenesisMiner genesis = GenesisMiner(_checkedAddress(manifest, ".contracts.genesis.address"));
        FourAgentCoin token = FourAgentCoin(_checkedAddress(manifest, ".contracts.token.address"));
        MiningPool pool = MiningPool(_checkedAddress(manifest, ".contracts.pool.address"));
        _checkProxy(manifest, ".contracts.genesis", address(genesis));
        _checkCode(address(token), vm.parseJsonBytes32(manifest, ".contracts.token.codeHash"));
        _checkProxy(manifest, ".contracts.pool", address(pool));

        _checkRoles(manifest, genesis, token, pool);
        _checkCore(manifest, genesis, token, pool);
        _checkIdentity(manifest, genesis);
        _checkMetadata(manifest, genesis, 0, true);
        if (genesis.publicMinted() != 0) {
            _checkMetadata(manifest, genesis, genesis.RESERVED_ALLOCATION(), false);
            uint256 last = genesis.totalAllocated() - 1;
            if (last != genesis.RESERVED_ALLOCATION()) _checkMetadata(manifest, genesis, last, false);
        }
        _checkPancake(manifest, token);

        console2.log("Reviewed manifest, current code, roles, bindings and sampled metadata match.");
        console2.log("This is not a security audit or independent proof of official identity provenance.");
    }

    function _checkRoles(string memory manifest, GenesisMiner genesis, FourAgentCoin token, MiningPool pool) private view {
        address admin = _checkedAddress(manifest, ".roles.admin");
        address fees = _checkedAddress(manifest, ".roles.feeRecipient");
        address lpTreasury = _checkedAddress(manifest, ".roles.lpTreasury");
        require(genesis.owner() == admin && token.owner() == admin && pool.owner() == admin, "Core owner does not match admin");
        require(genesis.pendingOwner() == address(0) && token.pendingOwner() == address(0) && pool.pendingOwner() == address(0), "Ownership handoff is still pending");
        require(genesis.reserveRecipient() == _checkedAddress(manifest, ".roles.reserveRecipient"), "Reserve recipient mismatch");
        require(token.lpRecipient() == lpTreasury, "Initial LP token treasury mismatch");
        require(token.feeRecipient() == fees && pool.feeRecipient() == fees, "Fee recipient mismatch");
        require(token.isTaxExempt(lpTreasury) == vm.parseJsonBool(manifest, ".expected.lpTreasuryTaxExempt"), "LP treasury tax exemption mismatch");
        // These destinations are chosen when funds/LP shares are sent, not immutable core getters.
        _checkedAddress(manifest, ".roles.operationsTreasury");
        _checkedAddress(manifest, ".roles.lpTokenRecipient");
    }

    function _checkCore(string memory manifest, GenesisMiner genesis, FourAgentCoin token, MiningPool pool) private view {
        require(genesis.miningPool() == address(pool) && token.miningPool() == address(pool), "Core mining-pool binding mismatch");
        require(address(pool.genesis()) == address(genesis) && address(pool.token()) == address(token), "Pool NFT/token binding mismatch");
        require(genesis.mintOpen() == vm.parseJsonBool(manifest, ".expected.mintOpen"), "Mint gate mismatch");
        require(genesis.stakingOpen() == vm.parseJsonBool(manifest, ".expected.stakingOpen"), "Staking gate mismatch");
        require(pool.miningOpen() == vm.parseJsonBool(manifest, ".expected.miningOpen"), "Mining gate mismatch");
        require(genesis.SUPPLY_CAP() == 21_000 && genesis.RESERVED_ALLOCATION() == 2_100 && genesis.PUBLIC_ALLOCATION() == 18_900, "NFT allocations mismatch");
        require(genesis.MAX_MINTS_PER_AGENT() == 21 && genesis.salePrice() == 0.0021 ether, "Mint quota/price mismatch");
        require(genesis.POWER_SCALE() == 1_000_000 && genesis.MIN_POWER() == 50_000_000 && genesis.MAX_POWER() == 250_000_000 && genesis.RESERVED_POWER() == 150_000_000, "NFT power constants mismatch");
        require(genesis.MARKET_FEE_BPS() == 500 && token.SWAP_TAX_BPS() == 100 && pool.feeBps() == 300, "Protocol fee rates mismatch");
        require(pool.NODE_COUNT() == 16 && pool.SLOT_COUNT() == 4 && pool.REFERENCE_POWER() == 150_000_000, "Task constants mismatch");
        require(pool.initialBaseReward() == _decimal(manifest, ".expected.initialBaseRewardWei"), "Initial base reward mismatch");
        require(token.decimals() == 18 && _same(token.name(), "4AgentCoin") && _same(token.symbol(), "4AGC"), "Token metadata mismatch");
        require(token.MAX_SUPPLY() == 21_000_000 ether && token.LP_ALLOCATION() == 1_050_000 ether && token.MINING_ALLOCATION() == 19_950_000 ether, "4AGC allocations mismatch");
        require(token.miningMinted() <= token.MINING_ALLOCATION(), "Mining allocation exceeded");
        require(pool.totalGrossMined() == token.miningMinted(), "Pool/token gross issuance mismatch");
        require(token.totalSupply() == token.LP_ALLOCATION() + token.miningMinted() && token.totalSupply() <= token.MAX_SUPPLY(), "Token supply accounting mismatch");
        require(genesis.reservedAllocated() == 2_100 && genesis.publicMinted() <= 18_900, "NFT issuance exceeded");
        require(genesis.totalAllocated() == genesis.reservedAllocated() + genesis.publicMinted() && genesis.totalSupply() == genesis.totalAllocated(), "NFT allocation accounting mismatch");
        require(genesis.saleRevenue() == genesis.publicMinted() * genesis.salePrice(), "Mint revenue accounting mismatch");
        uint256 lpBudget = genesis.saleRevenue() / 2;
        uint256 operationsBudget = genesis.saleRevenue() - lpBudget;
        require(genesis.liquidityWithdrawn() <= lpBudget && genesis.operationsWithdrawn() <= operationsBudget, "Mint revenue budget exceeded");
        uint256 outstanding = lpBudget - genesis.liquidityWithdrawn() + operationsBudget - genesis.operationsWithdrawn() + genesis.marketFeeBalance();
        require(address(genesis).balance >= outstanding, "Genesis BNB accounting is underfunded");
    }

    /// @dev Runtime alone cannot identify an upgrade: pin the ERC1967 implementation too.
    function _checkProxy(string memory manifest, string memory key, address proxy) private view {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        _checkCode(proxy, vm.parseJsonBytes32(manifest, string.concat(key, ".codeHash")));
        address expected = _checkedAddress(manifest, string.concat(key, ".implementationAddress"));
        bytes32 stored = vm.load(proxy, slot);
        require(uint256(stored) >> 160 == 0 && address(uint160(uint256(stored))) == expected, "Unreviewed proxy implementation");
        _checkCode(expected, vm.parseJsonBytes32(manifest, string.concat(key, ".implementationCodeHash")));
        (bool ok, bytes memory result) = expected.staticcall(abi.encodeWithSignature("proxiableUUID()"));
        require(ok && result.length == 32 && abi.decode(result, (bytes32)) == slot, "Implementation is not ERC1967 UUPS");
    }

    function _checkIdentity(string memory manifest, GenesisMiner genesis) private view {
        require(vm.parseJsonBool(manifest, ".identity.verified") && vm.parseJsonBool(manifest, ".identity.stableAgentIdSemanticsVerified") && vm.parseJsonBool(manifest, ".identity.adapterRegistryBindingVerified"), "BLOCKED: official identity verification is incomplete");
        require(_officialBinanceURL(vm.parseJsonString(manifest, ".identity.officialSourceUrl")), "BLOCKED: official Binance identity source required");
        require(bytes(vm.parseJsonString(manifest, ".identity.verificationEvidence")).length != 0 && bytes(vm.parseJsonString(manifest, ".identity.verifiedAt")).length != 0, "BLOCKED: identity evidence/time is missing");
        address adapter = _checkedAddress(manifest, ".identity.adapterAddress");
        address registry = _checkedAddress(manifest, ".identity.registryAddress");
        _checkCode(adapter, vm.parseJsonBytes32(manifest, ".identity.adapterCodeHash"));
        _checkCode(registry, vm.parseJsonBytes32(manifest, ".identity.registryCodeHash"));
        require(genesis.identityVerifier() == adapter, "Genesis identity adapter mismatch");
        bytes memory selector = vm.parseJsonBytes(manifest, ".identity.adapterRegistrySelector");
        require(selector.length == 4 && bytes4(selector) != bytes4(0), "BLOCKED: actual adapter registry getter is unknown");
        (bool success, bytes memory result) = adapter.staticcall(selector);
        require(success && result.length == 32, "BLOCKED: adapter registry getter failed");
        require(abi.decode(result, (address)) == registry, "BLOCKED: adapter registry binding mismatch");
    }

    function _checkMetadata(string memory manifest, GenesisMiner genesis, uint256 tokenId, bool reserved) private view {
        GenesisMiner.TokenView memory token = genesis.getToken(tokenId);
        require(token.owner != address(0) && token.isReserved == reserved, "NFT metadata sample ownership/series mismatch");
        require(token.power >= 50_000_000 && token.power <= 250_000_000, "NFT sample power out of bounds");
        if (reserved) require(token.power == 150_000_000, "Reserved NFT power is not 150 HP");
        bytes memory uri = bytes(genesis.tokenURI(tokenId));
        require(uri.length > 29 && _same(string(Bytes.slice(uri, 0, 29)), "data:application/json;base64,"), "Unexpected tokenURI encoding");
        string memory metadata = string(Base64.decode(string(Bytes.slice(uri, 29))));
        string memory image = vm.parseJsonString(manifest, ".expected.imageURI");
        require(bytes(image).length != 0 && _same(vm.parseJsonString(metadata, ".image"), image), "NFT metadata image mismatch");
        require(_same(vm.parseJsonString(metadata, ".attributes[1].trait_type"), "Hashrate"), "NFT Hashrate attribute missing");
        require(_metadataPower(metadata) == token.power, "NFT metadata Hashrate differs from onchain power");
    }

    function _checkPancake(string memory manifest, FourAgentCoin token) private view {
        require(vm.parseJsonBool(manifest, ".pancake.verified"), "BLOCKED: Pancake addresses are unverified");
        require(_same(vm.parseJsonString(manifest, ".pancake.officialSourceUrl"), "https://developer.pancakeswap.finance/contracts/v2/addresses"), "Unexpected Pancake source URL");
        require(bytes(vm.parseJsonString(manifest, ".pancake.verificationEvidence")).length != 0, "Pancake verification evidence missing");
        require(_checkedAddress(manifest, ".pancake.router") == V2_ROUTER && _checkedAddress(manifest, ".pancake.factory") == V2_FACTORY && _checkedAddress(manifest, ".pancake.wBNB") == WBNB, "Official BSC V2 addresses mismatch");
        _checkCode(V2_ROUTER, vm.parseJsonBytes32(manifest, ".pancake.routerCodeHash"));
        _checkCode(V2_FACTORY, vm.parseJsonBytes32(manifest, ".pancake.factoryCodeHash"));
        _checkCode(WBNB, vm.parseJsonBytes32(manifest, ".pancake.wBNBCodeHash"));
        require(IVerifyV2Router(V2_ROUTER).factory() == V2_FACTORY && IVerifyV2Router(V2_ROUTER).WETH() == WBNB, "Router factory/WBNB binding mismatch");
        address actualPair = IVerifyV2Factory(V2_FACTORY).getPair(address(token), WBNB);
        address recordedPair = vm.parseJsonAddress(manifest, ".pancake.pair");
        if (recordedPair != address(0)) {
            require(actualPair == recordedPair, "Recorded pair differs from Factory.getPair");
            _checkCode(recordedPair, vm.parseJsonBytes32(manifest, ".pancake.pairCodeHash"));
        }
        if (!vm.parseJsonBool(manifest, ".expected.requirePair")) {
            console2.log("LP NOT ACCEPTED: requirePair=false; liquidity and LP ownership were not verified.");
            console2.log("Factory pair currently", actualPair);
            return;
        }
        require(recordedPair != address(0) && actualPair == recordedPair, "BLOCKED: recorded Pancake pair is missing");
        IVerifyV2Pair pair = IVerifyV2Pair(recordedPair);
        require(pair.factory() == V2_FACTORY, "Pair factory mismatch");
        address token0 = pair.token0();
        address token1 = pair.token1();
        require((token0 == address(token) && token1 == WBNB) || (token0 == WBNB && token1 == address(token)), "Pair token bindings mismatch");
        require(token.isAMMPair(recordedPair) && !token.isTaxExempt(recordedPair), "Pair must be registered and not tax exempt");
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0 && pair.totalSupply() != 0, "BLOCKED: pair has no initialized liquidity");
        uint256 minimumLP = _decimal(manifest, ".expected.minimumLPBalanceWei");
        require(minimumLP != 0, "BLOCKED: reviewed minimum LP balance is required");
        address holder = _checkedAddress(manifest, ".roles.lpTokenRecipient");
        require(pair.balanceOf(holder) >= minimumLP, "BLOCKED: designated holder has insufficient LP shares");
        console2.log("LP reserves and designated holder balance meet the reviewed minimum.");
    }

    function _checkedAddress(string memory manifest, string memory key) private pure returns (address account) {
        account = vm.parseJsonAddress(manifest, key);
        require(account != address(0), string.concat("BLOCKED: missing address ", key));
    }

    function _checkCode(address account, bytes32 expectedHash) private view {
        require(expectedHash != bytes32(0), "BLOCKED: expected runtime code hash is missing");
        require(account.code.length != 0 && account.codehash == expectedHash, "Runtime code/hash mismatch");
    }

    function _decimal(string memory manifest, string memory key) private pure returns (uint256 value) {
        bytes memory digits = bytes(vm.parseJsonString(manifest, key));
        require(digits.length != 0, string.concat("Missing decimal value ", key));
        for (uint256 i; i < digits.length; ++i) {
            require(digits[i] >= "0" && digits[i] <= "9", string.concat("Invalid decimal value ", key));
            value = value * 10 + uint8(digits[i]) - 48;
        }
    }

    function _same(string memory a, string memory b) private pure returns (bool) { return keccak256(bytes(a)) == keccak256(bytes(b)); }

    function _officialBinanceURL(string memory url) private pure returns (bool) {
        return _prefix(url, "https://web3.binance.com/") || _prefix(url, "https://www.binance.com/")
            || _prefix(url, "https://binance.com/") || _prefix(url, "https://developers.binance.com/");
    }

    function _prefix(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory data = bytes(value);
        bytes memory expected = bytes(prefix);
        if (data.length < expected.length) return false;
        for (uint256 i; i < expected.length; ++i) if (data[i] != expected[i]) return false;
        return true;
    }

    /// @dev Parse the generated JSON number exactly, retaining six fractional digits.
    function _metadataPower(string memory metadata) private pure returns (uint256 value) {
        bytes memory data = bytes(metadata);
        bytes memory marker = bytes('"trait_type":"Hashrate","value":');
        for (uint256 start; start + marker.length <= data.length; ++start) {
            bool matches = true;
            for (uint256 j; j < marker.length; ++j) if (data[start + j] != marker[j]) { matches = false; break; }
            if (!matches) continue;
            bool decimal;
            uint256 fractionalDigits;
            for (uint256 i = start + marker.length; i < data.length; ++i) {
                bytes1 digit = data[i];
                if (digit == "," || digit == "}") {
                    require(decimal && fractionalDigits == 6, "Hashrate must have six decimal places");
                    return value;
                }
                if (digit == ".") {
                    require(!decimal, "Invalid Hashrate decimal point");
                    decimal = true;
                } else {
                    require(digit >= "0" && digit <= "9", "Invalid numeric Hashrate");
                    value = value * 10 + uint8(digit) - 48;
                    if (decimal) ++fractionalDigits;
                }
            }
        }
        revert("Hashrate JSON value missing");
    }
}
