// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";
import {FourAgentCoin} from "../src/FourAgentCoin.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {BinanceAgentIdentityAdapter} from "../src/BinanceAgentIdentityAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Production preparation with verified external configuration; every gate stays closed.
/// @dev No private key is read. Any later broadcast requires an external user-controlled signer.
contract DeployProtocol is Script {
    address private constant AGENT_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address private constant AGENT_IDENTITY_CONFIG = 0x8238589B02cc9349bcd46e76981Ef2c8A16eC5a8;
    bytes32 private constant AGENT_REGISTRY_CODE_HASH = 0xc4006e6e6ffaaf6996116617392beabe4f5f0a0795841322f91c2ceac34d6ace;
    function run() external returns (GenesisMiner genesis, FourAgentCoin token, MiningPool pool) {
        require(block.chainid == 56, "Verified Agent ID registry requires BSC mainnet");
        require(vm.envBool("GENESIS_EXTERNALS_VERIFIED"), "Review official Agent ID evidence first");
        require(AGENT_REGISTRY.code.length > 0 && AGENT_REGISTRY.codehash == AGENT_REGISTRY_CODE_HASH, "Official Agent ID registry runtime differs from reviewed source");
        (bool identityConfigOK, bytes memory registryResult) = AGENT_IDENTITY_CONFIG.staticcall(hex"bfa325ba");
        require(identityConfigOK && registryResult.length == 32 && abi.decode(registryResult, (address)) == AGENT_REGISTRY, "Official Agent ID registry configuration changed; review required");
        require(vm.envBool("GENESIS_METADATA_VERIFIED"), "Verify metadata before deployment");
        address signer = vm.envAddress("DEPLOYER_ADDRESS");
        require(signer != address(0), "Missing external signer address");
        GenesisMiner.Config memory c = GenesisMiner.Config({
            reserveRecipient: vm.envAddress("GENESIS_RESERVE_RECIPIENT"),
            identityVerifier: address(0),
            imageURI: vm.envString("GENESIS_IMAGE_URI")
        });
        require(_prefix(bytes(c.imageURI), bytes("ipfs://")) || _prefix(bytes(c.imageURI), bytes("https://")), "Image must use ipfs or https");
        address lpRecipient = vm.envAddress("PROTOCOL_LP_RECIPIENT");
        address feeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        uint256 initialReward = vm.envUint("PROTOCOL_INITIAL_BASE_REWARD");
        vm.startBroadcast(signer);
        BinanceAgentIdentityAdapter identity = new BinanceAgentIdentityAdapter();
        c.identityVerifier = address(identity);
        GenesisMiner genesisImplementation = new GenesisMiner();
        genesis = GenesisMiner(address(new ERC1967Proxy(address(genesisImplementation), abi.encodeCall(GenesisMiner.initialize, (c, signer)))));
        token = new FourAgentCoin(lpRecipient, feeRecipient);
        MiningPool poolImplementation = new MiningPool();
        pool = MiningPool(address(new ERC1967Proxy(address(poolImplementation), abi.encodeCall(MiningPool.initialize, (address(genesis), address(token), feeRecipient, initialReward, signer)))));
        genesis.setMiningPool(address(pool));
        token.setMiningPool(address(pool));
        vm.stopBroadcast();
        require(identity.registry() == AGENT_REGISTRY && identity.expectedRegistryCodeHash() == AGENT_REGISTRY_CODE_HASH && genesis.identityVerifier() == address(identity), "Official identity adapter binding mismatch");
        require(genesis.owner() == signer && token.owner() == signer && pool.owner() == signer, "Owner must be external signer");
        require(!genesis.mintOpen() && !genesis.stakingOpen() && !pool.miningOpen(), "Production gates must stay closed");
        console2.log("BinanceAgentIdentityAdapter", address(identity));
        console2.log("AgentIDRegistry", identity.registry());
        console2.log("GenesisMiner", address(genesis));
        console2.log("GenesisMinerImplementation", address(genesisImplementation));
        console2.log("FourAgentCoin", address(token));
        console2.log("MiningPool", address(pool));
        console2.log("MiningPoolImplementation", address(poolImplementation));
        console2.log("ChainId", block.chainid);
        console2.log("All gates remain closed; verify receipts, roles and bindings before manual opening");
    }
    function _prefix(bytes memory value, bytes memory prefix) private pure returns (bool) {
        if (value.length <= prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) if (value[i] != prefix[i]) return false;
        return true;
    }
}
