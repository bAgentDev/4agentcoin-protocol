// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Deterministic on-chain resource allocation tasks: 16 nodes, four slots.
/// @dev A degree-three graph is always four-colorable. This verifies a valid
/// assignment, not that a particular model or an LLM produced that assignment.
library AgentTaskVerifier {
    uint256 internal constant NODE_COUNT = 16;
    uint256 internal constant SLOT_COUNT = 4;

    /// @return edges Each edge is packed as (lowerNode << 8) | higherNode.
    function generate(bytes32 seed) internal pure returns (uint16[] memory edges) {
        edges = new uint16[](24);
        uint8[16] memory degree;
        uint256 count;
        for (uint256 a; a < NODE_COUNT; ++a) {
            for (uint256 b = a + 1; b < NODE_COUNT; ++b) {
                if (degree[a] < 3 && degree[b] < 3 && uint256(keccak256(abi.encode(seed, a, b))) % 1000 < 350) {
                    edges[count++] = uint16((a << 8) | b);
                    ++degree[a];
                    ++degree[b];
                }
            }
        }
        assembly ("memory-safe") { mstore(edges, count) }
    }

    function verify(bytes32 seed, uint256 packedAnswer) internal pure returns (bool) {
        if (packedAnswer >> (2 * NODE_COUNT) != 0) return false;
        uint16[] memory edges = generate(seed);
        for (uint256 i; i < edges.length; ++i) {
            uint256 a = edges[i] >> 8;
            uint256 b = edges[i] & 0xff;
            if (((packedAnswer >> (2 * a)) & 3) == ((packedAnswer >> (2 * b)) & 3)) return false;
        }
        return true;
    }
}
