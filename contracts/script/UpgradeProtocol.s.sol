// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";

/// @notice A single, manually reviewed UUPS upgrade. No keys are read and no gates are opened.
/// @dev The storage report records an independently run upgrades-core validation, not an onchain proof.
/// Script assertions run in simulation; after broadcast, verify receipts and refresh reviewed implementation metadata.
contract UpgradeProtocol is Script {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        string memory m = vm.readFile(vm.envOr("DEPLOYMENT_MANIFEST", string("../config/deployments.bsc.json")));
        require(vm.parseJsonBool(m, ".enabled") && vm.parseJsonBool(m, ".upgrade.enabled"), "BLOCKED: upgrade is not enabled in reviewed manifest");
        require(vm.parseJsonUint(m, ".schemaVersion") == 1 && vm.parseJsonUint(m, ".chainId") == 56 && block.chainid == 56, "BSC manifest/chain required");
        require(_same(vm.parseJsonString(m, ".expected.deploymentMode"), "uups_genesis_pool_fixed_token"), "Unexpected deployment mode");
        address admin = vm.parseJsonAddress(m, ".roles.admin");
        address signer = vm.envAddress("SIGNER_ADDRESS");
        require(admin != address(0) && signer == admin, "Only configured administrator may upgrade");

        GenesisMiner genesis = GenesisMiner(vm.parseJsonAddress(m, ".contracts.genesis.address"));
        FourAgentCoin token = FourAgentCoin(vm.parseJsonAddress(m, ".contracts.token.address"));
        MiningPool pool = MiningPool(vm.parseJsonAddress(m, ".contracts.pool.address"));
        _proxy(m, ".contracts.genesis", address(genesis));
        _proxy(m, ".contracts.pool", address(pool));
        _code(address(token), vm.parseJsonBytes32(m, ".contracts.token.codeHash"));
        require(genesis.owner() == admin && pool.owner() == admin && token.owner() == admin, "Core administrator mismatch");
        require(genesis.pendingOwner() == address(0) && pool.pendingOwner() == address(0) && token.pendingOwner() == address(0), "Finish ownership handoff before upgrade");
        require(genesis.miningPool() == address(pool) && token.miningPool() == address(pool) && address(pool.genesis()) == address(genesis) && address(pool.token()) == address(token), "Stable proxy bindings mismatch");
        require(!genesis.mintOpen() && !genesis.stakingOpen() && !pool.miningOpen(), "Close mint, staking and mining manually before upgrade");

        string memory target = vm.parseJsonString(m, ".upgrade.target");
        address proxy;
        if (_same(target, "genesis")) proxy = address(genesis);
        else if (_same(target, "pool")) proxy = address(pool);
        else revert("Choose exactly genesis or pool; Token is fixed");
        address previous = _implementation(proxy);
        address next = vm.parseJsonAddress(m, ".upgrade.newImplementationAddress");
        bytes32 nextHash = vm.parseJsonBytes32(m, ".upgrade.newImplementationCodeHash");
        require(next != previous && next != proxy && next != address(genesis) && next != address(pool) && next != address(token), "Invalid new implementation");
        _code(next, nextHash);
        _uuid(next);
        _storageReport(m, previous.codehash, nextHash);
        bytes memory data = vm.parseJsonBytes(m, ".upgrade.callData");
        bytes32 stateBefore = _state(genesis, token, pool);

        console2.log("Proxy to upgrade", proxy);
        console2.log("Reviewed old implementation", previous);
        console2.log("Reviewed new implementation", next);
        console2.log("Migration calldata bytes", data.length);
        vm.startBroadcast(signer);
        UUPSUpgradeable(proxy).upgradeToAndCall(next, data);
        vm.stopBroadcast();

        require(_implementation(proxy) == next && proxy.codehash == vm.parseJsonBytes32(m, _same(target, "genesis") ? ".contracts.genesis.codeHash" : ".contracts.pool.codeHash"), "Upgrade target/proxy mismatch");
        require(_state(genesis, token, pool) == stateBefore, "Existing protocol state changed during upgrade simulation");
        console2.log("Simulation preserved the sampled core state and closed gates.");
        console2.log("After a separately authorized broadcast, verify the real receipt and storage; update reviewed implementation metadata before resuming clients.");
    }

    function _storageReport(string memory m, bytes32 previousHash, bytes32 nextHash) private view {
        require(vm.parseJsonBool(m, ".upgrade.storageValidationReviewed"), "Review storage validation before upgrading");
        bytes32 expectedReportHash = vm.parseJsonBytes32(m, ".upgrade.storageValidationReportHash");
        require(expectedReportHash != bytes32(0), "Missing reviewed storage report hash");
        string memory report = vm.readFile(vm.parseJsonString(m, ".upgrade.storageValidationReportPath"));
        require(keccak256(bytes(report)) == expectedReportHash, "Storage report differs from reviewed bytes");
        require(_same(vm.parseJsonString(report, ".tool"), "openzeppelin-upgrades-core") && _same(vm.parseJsonString(report, ".toolVersion"), "1.46.0"), "Wrong validation tool/version");
        require(vm.parseJsonBool(report, ".storageCompatible") && vm.parseJsonBool(report, ".unsafeSkipStorageCheck") == false, "Storage validation must pass without skipping compatibility");
        require(vm.parseJsonBytes32(report, ".referenceImplementationCodeHash") == previousHash && vm.parseJsonBytes32(report, ".newImplementationCodeHash") == nextHash, "Storage report is for different implementation code");
        require(bytes(vm.parseJsonString(report, ".referenceContract")).length > 0 && bytes(vm.parseJsonString(report, ".targetContract")).length > 0, "Storage report lacks compared contracts");
    }

    function _state(GenesisMiner g, FourAgentCoin t, MiningPool p) private view returns (bytes32) {
        bytes32 nft = keccak256(abi.encode(g.owner(), g.pendingOwner(), g.reserveRecipient(), g.identityVerifier(), g.miningPool(), g.totalAllocated(), g.publicMinted(), g.totalStakeLocks(), g.saleRevenue(), g.liquidityWithdrawn(), g.operationsWithdrawn(), g.marketFeeBalance(), g.mintOpen(), g.stakingOpen()));
        bytes32 mining = keccak256(abi.encode(p.owner(), p.pendingOwner(), address(p.genesis()), address(p.token()), p.feeRecipient(), p.initialBaseReward(), p.totalGrossMined(), p.totalSolved(), p.miningOpen()));
        return keccak256(abi.encode(nft, mining, t.owner(), t.pendingOwner(), t.miningPool(), t.feeRecipient(), t.totalSupply(), t.miningMinted(), t.MAX_SUPPLY(), t.LP_ALLOCATION(), t.MINING_ALLOCATION(), t.SWAP_TAX_BPS()));
    }

    function _proxy(string memory m, string memory key, address proxy) private view {
        _code(proxy, vm.parseJsonBytes32(m, string.concat(key, ".codeHash")));
        address expected = vm.parseJsonAddress(m, string.concat(key, ".implementationAddress"));
        require(_implementation(proxy) == expected, "Unreviewed current implementation");
        _code(expected, vm.parseJsonBytes32(m, string.concat(key, ".implementationCodeHash")));
        _uuid(expected);
    }

    function _implementation(address proxy) private view returns (address implementation) {
        bytes32 value = vm.load(proxy, IMPLEMENTATION_SLOT);
        require(uint256(value) >> 160 == 0, "Malformed ERC1967 slot");
        implementation = address(uint160(uint256(value)));
        require(implementation != address(0), "Missing ERC1967 implementation");
    }

    function _uuid(address implementation) private view {
        (bool ok, bytes memory result) = implementation.staticcall(abi.encodeWithSignature("proxiableUUID()"));
        require(ok && result.length == 32 && abi.decode(result, (bytes32)) == IMPLEMENTATION_SLOT, "Implementation is not ERC1967 UUPS");
    }

    function _code(address target, bytes32 expected) private view {
        require(target != address(0) && target.code.length > 0 && expected != bytes32(0) && target.codehash == expected, "Runtime hash mismatch");
    }

    function _same(string memory a, string memory b) private pure returns (bool) { return keccak256(bytes(a)) == keccak256(bytes(b)); }
}
