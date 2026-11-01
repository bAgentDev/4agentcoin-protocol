// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IAgentIdentityVerifier} from "../src/ProtocolInterfaces.sol";
import {GenesisMiner} from "../src/GenesisMiner.sol";

/// @dev LOCAL TEST ONLY. This is not the official Agent ID registry or a production adapter.
contract MockIdentityVerifier is IAgentIdentityVerifier {
    mapping(address => bool) public eligible;
    mapping(address => bytes32) public agentIds;
    bool public fail;
    bool public failAgentId;
    function setEligible(address account, bool value) external { eligible[account] = value; }
    function setAgentId(address account, bytes32 agentId) external { agentIds[account] = agentId; }
    function setFail(bool value) external { fail = value; }
    function setFailAgentId(bool value) external { failAgentId = value; }
    function isEligible(address account) external view returns (bool) {
        require(!fail, "local verifier unavailable");
        return eligible[account];
    }
    function agentIdOf(address account) external view returns (bytes32) {
        require(!failAgentId, "local agent ID unavailable");
        return agentIds[account];
    }
}

contract MockMiningPool {
    function stake(GenesisMiner miner, uint256 id) external { miner.lockForStake(id, msg.sender); }
    function unstake(GenesisMiner miner, uint256 id) external { miner.unlockFromStake(id, msg.sender); }
}

contract RejectingSeller is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    function listMiner(GenesisMiner miner, uint256 id, uint256 price) external { miner.list(id, price); }
    function withdraw(GenesisMiner miner, address payable recipient) external { miner.withdrawProceeds(recipient); }
    receive() external payable { revert("seller rejects native transfer"); }
}

contract RejectingBuyer is IERC721Receiver {
    function buyMiner(GenesisMiner miner, uint256 id, uint256 listingId, uint256 price) external payable {
        miner.buy{value: msg.value}(id, listingId, price);
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("buyer rejects NFT");
    }
}

contract ReenteringSeller is IERC721Receiver {
    GenesisMiner public immutable miner;
    bool public reentryBlocked;
    constructor(GenesisMiner target) { miner = target; }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    function listMiner(uint256 id, uint256 price) external { miner.list(id, price); }
    function withdraw() external { miner.withdrawProceeds(payable(address(this))); }
    receive() external payable {
        try miner.withdrawProceeds(payable(address(this))) { reentryBlocked = false; }
        catch { reentryBlocked = true; }
    }
}

/// @dev Test-only solver demonstrates that graph validity does not attest model use.
library LocalTaskSolver {
    function solve(uint16[] memory edges) internal pure returns (uint256 packed) {
        for (uint256 node; node < 16; ++node) {
            uint256 forbidden;
            for (uint256 i; i < edges.length; ++i) {
                uint256 a = edges[i] >> 8;
                uint256 b = edges[i] & 0xff;
                if (b == node) forbidden |= 1 << ((packed >> (2 * a)) & 3);
            }
            uint256 color;
            while ((forbidden & (1 << color)) != 0) ++color;
            require(color < 4, "degree invariant");
            packed |= color << (2 * node);
        }
    }
}


/// @dev Captures the real state observed during a paid mint receiver callback.
contract InspectingMintReceiver is IERC721Receiver {
    GenesisMiner public immutable miner;
    uint256 public observedPower;
    uint256 public observedTokens;
    bool public rejectSecond;
    constructor(GenesisMiner target) { miner = target; }
    function setRejectSecond(bool reject) external { rejectSecond = reject; }
    function mintBatch(uint256 quantity, bytes32 salt) external payable {
        miner.mintBatch{value: msg.value}(quantity, salt);
    }
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(miner), "unexpected NFT");
        GenesisMiner.TokenView memory token = miner.getToken(tokenId);
        require(token.owner == address(this) && token.power >= 50_000_000 && token.power <= 250_000_000, "HP must already be fixed");
        observedPower = token.power;
        ++observedTokens;
        require(!rejectSecond || observedTokens != 2, "receiver rejects second NFT");
        return IERC721Receiver.onERC721Received.selector;
    }
}
