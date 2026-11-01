// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Project adapter port, NOT a verified Binance/SPACE ID registry ABI.
/// A production adapter must be independently checked against the real official registry.
interface IAgentIdentityVerifier {
    function isEligible(address account) external view returns (bool);
    /// @notice Stable registry identity across wallet binding changes; zero means unavailable.
    function agentIdOf(address account) external view returns (bytes32);
}

/// @notice MiningPool uses non-custodial locks; only the configured pool may call these.
interface IGenesisStakeLock {
    function lockForStake(uint256 tokenId, address staker) external;
    function unlockFromStake(uint256 tokenId, address staker) external;
}
