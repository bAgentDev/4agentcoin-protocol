// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {AgentTaskVerifier} from "../src/AgentTaskVerifier.sol";
import {LocalTaskSolver} from "./Mocks.sol";

contract AgentTaskVerifierTest is Test {
    function testFuzzGeneratedTasksBoundDegreeAndAcceptValidAssignment(bytes32 seed) public pure {
        uint16[] memory edges = AgentTaskVerifier.generate(seed);
        uint8[16] memory degree;
        assertLe(edges.length, 24);
        for (uint256 i; i < edges.length; ++i) {
            uint256 a = edges[i] >> 8;
            uint256 b = edges[i] & 0xff;
            assertLt(a, b);
            assertLt(b, 16);
            assertLe(++degree[a], 3);
            assertLe(++degree[b], 3);
            if (i != 0) assertGt(edges[i], edges[i - 1]);
        }
        uint256 answer = LocalTaskSolver.solve(edges);
        assertTrue(AgentTaskVerifier.verify(seed, answer));
        assertFalse(AgentTaskVerifier.verify(seed, answer | (1 << 32)));
        if (edges.length != 0) {
            uint256 a = edges[0] >> 8;
            uint256 b = edges[0] & 0xff;
            uint256 bad = (answer & ~(uint256(3) << (2 * b))) | (((answer >> (2 * a)) & 3) << (2 * b));
            assertFalse(AgentTaskVerifier.verify(seed, bad));
        }
    }
}
