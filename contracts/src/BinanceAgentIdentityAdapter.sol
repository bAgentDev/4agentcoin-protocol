// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentityVerifier} from "./ProtocolInterfaces.sol";

/// @dev Read ABI of the verified, non-upgradeable SPACE ID Agent ID registry on BSC.
interface IBinanceAgentHandleRegistry {
    function handleOf(address account) external view returns (string memory);
    function balanceOf(address account) external view returns (uint256);
    function ownerOfHandle(string calldata handle) external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Connects protocol eligibility to the official Binance Agent ID registry.
/// @dev The registry's immovable NFT ID is keccak256 of its bare, permanently bound handle.
/// Deployment and clients must verify the registry runtime against expectedRegistryCodeHash.
/// This contract has no administrator, configurable identity records or registry replacement.
contract BinanceAgentIdentityAdapter is IAgentIdentityVerifier {
    address public constant registry = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    bytes32 public constant expectedRegistryCodeHash = 0xc4006e6e6ffaaf6996116617392beabe4f5f0a0795841322f91c2ceac34d6ace;

    error RegistryUnavailable();
    error InconsistentIdentity();

    function isEligible(address account) external view returns (bool) {
        return _agentId(account) != bytes32(0);
    }

    function agentIdOf(address account) external view returns (bytes32) {
        return _agentId(account);
    }

    function _agentId(address account) private view returns (bytes32 id) {
        if (account == address(0)) return bytes32(0);
        if (registry.code.length == 0) revert RegistryUnavailable();
        IBinanceAgentHandleRegistry source = IBinanceAgentHandleRegistry(registry);

        // Upstream failures propagate so protocol callers report unavailable identity,
        // rather than incorrectly reporting that the account has no Agent ID.
        string memory handle = source.handleOf(account);
        uint256 balance = source.balanceOf(account);
        if (bytes(handle).length == 0 && balance == 0) return bytes32(0);
        if (bytes(handle).length == 0 || balance != 1) revert InconsistentIdentity();

        // Use the registry's bare handle, without adding ".ai", lowercasing or applying
        // today's registration-length settings to identities minted under earlier settings.
        id = keccak256(bytes(handle));
        if (id == bytes32(0) || source.ownerOfHandle(handle) != account || source.ownerOf(uint256(id)) != account) {
            revert InconsistentIdentity();
        }
    }
}
