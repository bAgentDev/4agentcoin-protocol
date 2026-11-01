// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {MockIdentityVerifier} from "../test/Mocks.sol";

/// @notice Only for an unlocked local Anvil account on chain 31337. Never a production deployment.
contract LocalGenesis is Script {
    function run() external returns (GenesisMiner miner) {
        require(block.chainid == 31337, "Local mocks require chain 31337");
        address admin = vm.envAddress("LOCAL_ADMIN");
        require(admin != address(0), "Set LOCAL_ADMIN to an unlocked local account");
        vm.startBroadcast(admin);
        MockIdentityVerifier verifier = new MockIdentityVerifier();
        miner = new GenesisMiner(GenesisMiner.Config({
            reserveRecipient: admin, identityVerifier: address(verifier),
            imageURI: "http://127.0.0.1:5173/nft/genesis-miner.png"
        }));
        verifier.setEligible(admin, true);
        verifier.setAgentId(admin, keccak256("LOCAL_DEMO_AGENT_ID"));
        miner.setMintOpen(true);
        vm.stopBroadcast();
        string memory key = "localGenesis";
        vm.serializeBool(key, "localMocks", true);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "address", address(miner));
        vm.serializeAddress(key, "admin", admin);
        vm.serializeAddress(key, "identityVerifier", address(verifier));
        // Scan from zero locally so simulated and mined block numbering cannot omit ERC2309.
        vm.serializeUint(key, "deploymentBlock", 0);
        string memory json = vm.serializeUint(key, "readyTokenId", 0);
        vm.createDir("./broadcast/local", true);
        vm.writeJson(json, "./broadcast/local/genesis.json");
        console2.log("GenesisMiner", address(miner));
        console2.log("Admin", admin);
        console2.log("IdentityVerifier_LOCAL_MOCK", address(verifier));
        console2.log("ReadyTokenId", uint256(0));
        console2.log("ReservedPowerMicroHP", miner.RESERVED_POWER());
        console2.log("Config", "broadcast/local/genesis.json");
    }
}
