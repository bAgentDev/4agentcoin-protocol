// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Build/simulate with real verified configuration. Broadcasting requires an external signer.
/// This script never reads a private key. Pass --sender and a user-controlled external signing method.
contract DeployGenesis is Script {
    function run() external returns (GenesisMiner miner) {
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
        require(c.reserveRecipient != address(0), "Missing reserve recipient");
        require(c.identityVerifier.code.length > 0, "Missing verified project identity adapter");
        require(_prefix(bytes(c.imageURI), bytes("ipfs://")) || _prefix(bytes(c.imageURI), bytes("https://")), "Image must use ipfs or https");
        vm.startBroadcast(signer);
        GenesisMiner implementation = new GenesisMiner();
        miner = GenesisMiner(address(new ERC1967Proxy(address(implementation), abi.encodeCall(GenesisMiner.initialize, (c, signer)))));
        vm.stopBroadcast();
        require(miner.owner() == signer, "Owner must be external signer");
        console2.log("GenesisMiner", address(miner));
        console2.log("GenesisMinerImplementation", address(implementation));
        console2.log("Admin", signer);
        console2.log("ChainId", block.chainid);
        console2.log("MintOpen", miner.mintOpen());
        console2.log("Identity adapter and final review required before opening mint");
    }

    function _prefix(bytes memory value, bytes memory prefix) private pure returns (bool) {
        if (value.length <= prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) if (value[i] != prefix[i]) return false;
        return true;
    }
}
