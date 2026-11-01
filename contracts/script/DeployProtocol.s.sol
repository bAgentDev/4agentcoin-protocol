// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";

/// @notice Production preparation with verified external configuration; every gate stays closed.
/// @dev No private key is read. Any later broadcast requires an external user-controlled signer.
contract DeployProtocol is Script {
    function run() external returns (GenesisMiner genesis, FourAgentCoin token, MiningPool pool) {
        require(block.chainid == 56 || block.chainid == 97, "Only BSC mainnet/testnet");
        require(vm.envBool("GENESIS_EXTERNALS_VERIFIED"), "Verify official identity adapter first");
        require(vm.envBool("GENESIS_METADATA_VERIFIED"), "Verify metadata before deployment");
        address signer = vm.envAddress("DEPLOYER_ADDRESS");
        require(signer != address(0), "Missing external signer address");
        GenesisMiner.Config memory c = GenesisMiner.Config({
            reserveRecipient: vm.envAddress("GENESIS_RESERVE_RECIPIENT"),
            identityVerifier: vm.envAddress("GENESIS_IDENTITY_VERIFIER"),
            imageURI: vm.envString("GENESIS_IMAGE_URI")
        });
        require(c.identityVerifier.code.length > 0, "Missing verified project identity adapter");
        require(_prefix(bytes(c.imageURI), bytes("ipfs://")) || _prefix(bytes(c.imageURI), bytes("https://")), "Image must use ipfs or https");
        address lpRecipient = vm.envAddress("PROTOCOL_LP_RECIPIENT");
        address feeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        uint256 initialReward = vm.envUint("PROTOCOL_INITIAL_BASE_REWARD");
        vm.startBroadcast(signer);
        genesis = new GenesisMiner(c);
        token = new FourAgentCoin(lpRecipient, feeRecipient);
        pool = new MiningPool(address(genesis), address(token), feeRecipient, initialReward);
        genesis.setMiningPool(address(pool));
        token.setMiningPool(address(pool));
        vm.stopBroadcast();
        require(genesis.owner() == signer && token.owner() == signer && pool.owner() == signer, "Owner must be external signer");
        require(!genesis.mintOpen() && !genesis.stakingOpen() && !pool.miningOpen(), "Production gates must stay closed");
        console2.log("GenesisMiner", address(genesis));
        console2.log("FourAgentCoin", address(token));
        console2.log("MiningPool", address(pool));
        console2.log("ChainId", block.chainid);
        console2.log("Verify official adapter and configure LP pair/exemptions before manual opening");
    }
    function _prefix(bytes memory value, bytes memory prefix) private pure returns (bool) {
        if (value.length <= prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) if (value[i] != prefix[i]) return false;
        return true;
    }
}
