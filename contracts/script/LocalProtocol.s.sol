// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {MockIdentityVerifier} from "../test/Mocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Local Anvil demo only. The identity mock does not authenticate official IDs.
contract LocalProtocol is Script {
    function run() external returns (GenesisMiner genesis, FourAgentCoin token, MiningPool pool) {
        require(block.chainid == 31337, "Local mocks require chain 31337");
        address admin = vm.envAddress("LOCAL_ADMIN");
        require(admin != address(0), "Set LOCAL_ADMIN to an unlocked local account");
        address feeRecipient = vm.envOr("LOCAL_FEE_RECIPIENT", admin);
        address lpRecipient = vm.envOr("LOCAL_LP_RECIPIENT", admin);
        bool open = vm.envOr("LOCAL_OPEN", true);
        uint256 initialReward = vm.envOr("LOCAL_INITIAL_BASE_REWARD", uint256(2.1 ether));
        vm.startBroadcast(admin);
        MockIdentityVerifier verifier = new MockIdentityVerifier();
        GenesisMiner.Config memory c = GenesisMiner.Config({
            reserveRecipient: admin, identityVerifier: address(verifier),
            imageURI: "http://127.0.0.1:5173/nft/genesis-miner.png"
        });
        GenesisMiner genesisImplementation = new GenesisMiner();
        genesis = GenesisMiner(address(new ERC1967Proxy(address(genesisImplementation), abi.encodeCall(GenesisMiner.initialize, (c, admin)))));
        token = new FourAgentCoin(lpRecipient, feeRecipient);
        MiningPool poolImplementation = new MiningPool();
        pool = MiningPool(address(new ERC1967Proxy(address(poolImplementation), abi.encodeCall(MiningPool.initialize, (address(genesis), address(token), feeRecipient, initialReward, admin)))));
        genesis.setMiningPool(address(pool));
        token.setMiningPool(address(pool));
        verifier.setEligible(admin, true);
        verifier.setAgentId(admin, keccak256("LOCAL_DEMO_AGENT_ID"));
        if (open) {
            genesis.setMintOpen(true);
            genesis.setStakingOpen(true);
            pool.setMiningOpen(true);
        }
        vm.stopBroadcast();
        string memory key = "localProtocol";
        vm.serializeBool(key, "localMocks", true);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "address", address(genesis));
        vm.serializeAddress(key, "genesis", address(genesis));
        vm.serializeAddress(key, "genesisImplementation", address(genesisImplementation));
        vm.serializeAddress(key, "token", address(token));
        vm.serializeAddress(key, "miningPool", address(pool));
        vm.serializeAddress(key, "poolImplementation", address(poolImplementation));
        vm.serializeAddress(key, "admin", admin);
        vm.serializeAddress(key, "feeRecipient", feeRecipient);
        vm.serializeAddress(key, "lpRecipient", lpRecipient);
        vm.serializeAddress(key, "identityVerifier", address(verifier));
        vm.serializeUint(key, "deploymentBlock", 0);
        string memory json = vm.serializeUint(key, "readyTokenId", 0);
        vm.createDir("./broadcast/local", true);
        vm.writeJson(json, "./broadcast/local/protocol.json");
        vm.writeJson(json, "./broadcast/local/genesis.json");
        console2.log("GenesisMiner", address(genesis));
        console2.log("GenesisMinerImplementation", address(genesisImplementation));
        console2.log("FourAgentCoin", address(token));
        console2.log("MiningPool", address(pool));
        console2.log("MiningPoolImplementation", address(poolImplementation));
        console2.log("IdentityVerifier_LOCAL_MOCK", address(verifier));
        console2.log("Config", "broadcast/local/protocol.json");
    }
}
