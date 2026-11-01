// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GenesisMiner} from "./GenesisMiner.sol";
import {FourAgentCoin} from "./FourAgentCoin.sol";
import {IAgentIdentityVerifier} from "./ProtocolInterfaces.sol";
import {AgentTaskVerifier} from "./AgentTaskVerifier.sol";

/// @notice Non-custodial Genesis locks and a single atomic task/reward transaction.
/// @dev Task validity is fully on-chain; this does not attest use of an LLM.
/// ReentrancyGuard uses a namespaced slot; a proxy's initial zero status is accepted and normalized on first use.
contract MiningPool is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    uint256 public constant NODE_COUNT = 16;
    uint256 public constant SLOT_COUNT = 4;
    uint256 public constant feeBps = 300;
    uint256 public constant REFERENCE_POWER = 150_000_000;
    GenesisMiner public genesis;
    FourAgentCoin public token;
    uint256 public initialBaseReward;
    address public feeRecipient;
    bool public miningOpen;
    uint256 public totalGrossMined;
    uint256 public totalSolved;
    mapping(uint256 => address) public stakedBy;
    mapping(uint256 => bytes32) public stakeAgentId;
    mapping(uint256 => uint256) public taskNonce;
    mapping(uint256 => bytes32) public taskSeed;
    mapping(uint256 => uint256) public lastSolvedBlock;
    mapping(address => uint256) public completedTasks;
    mapping(address => uint256) public netEarned;

    error InvalidConfiguration();
    error MiningClosed();
    error EmptyBatch();
    error AlreadyStaked();
    error NotStaker();
    error IdentityUnavailable();
    error NotEligible();
    error IdentityChanged();
    error StaleTask();
    error InvalidAnswer();
    error SameBlock();
    error RewardBelowMinimum();
    error MiningExhausted();
    event Staked(uint256 indexed tokenId, address indexed staker, bytes32 indexed agentId);
    event Unstaked(uint256 indexed tokenId, address indexed staker);
    event TaskIssued(uint256 indexed tokenId, address indexed staker, uint256 nonce, bytes32 seed);
    event TaskSolved(uint256 indexed tokenId, address indexed staker, uint256 nonce, uint256 gross, uint256 fee, uint256 net);
    event MiningOpenChanged(bool open);
    event FeeRecipientChanged(address indexed recipient);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address genesis_, address token_, address feeRecipient_, uint256 initialBaseReward_, address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        if (genesis_.code.length == 0 || token_.code.length == 0 || feeRecipient_ == address(0) || initialBaseReward_ == 0) revert InvalidConfiguration();
        if (initialBaseReward_ > FourAgentCoin(token_).MINING_ALLOCATION()) revert InvalidConfiguration();
        genesis = GenesisMiner(genesis_);
        token = FourAgentCoin(token_);
        feeRecipient = feeRecipient_;
        initialBaseReward = initialBaseReward_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setMiningOpen(bool open) external onlyOwner {
        if (open && (genesis.miningPool() != address(this) || token.miningPool() != address(this))) revert InvalidConfiguration();
        miningOpen = open;
        emit MiningOpenChanged(open);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidConfiguration();
        feeRecipient = recipient;
        emit FeeRecipientChanged(recipient);
    }

    function stake(uint256[] calldata tokenIds) external nonReentrant {
        if (!miningOpen) revert MiningClosed();
        if (tokenIds.length == 0) revert EmptyBatch();
        bytes32 agentId = _eligibleAgent(msg.sender);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (stakedBy[id] != address(0)) revert AlreadyStaked();
            genesis.lockForStake(id, msg.sender);
            stakedBy[id] = msg.sender;
            stakeAgentId[id] = agentId;
            _issue(id, msg.sender);
            emit Staked(id, msg.sender, agentId);
        }
    }

    /// @notice Withdrawal stays available during pauses and identity revocation.
    function unstake(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert EmptyBatch();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (stakedBy[id] != msg.sender) revert NotStaker();
            delete stakedBy[id];
            delete stakeAgentId[id];
            delete taskSeed[id];
            ++taskNonce[id];
            genesis.unlockFromStake(id, msg.sender);
            emit Unstaked(id, msg.sender);
        }
    }

    function getTask(uint256 tokenId) external view returns (bytes32 seed, uint256 nonce, uint256 power, uint16[] memory edges) {
        if (stakedBy[tokenId] == address(0)) revert NotStaker();
        seed = taskSeed[tokenId];
        nonce = taskNonce[tokenId];
        power = genesis.getToken(tokenId).power;
        edges = AgentTaskVerifier.generate(seed);
    }

    /// @notice Era k starts at M - floor(M / 2**k), based on gross mining issuance.
    /// A success uses the pre-submit era and may cross its threshold, but never the cap.
    function currentEra() public view returns (uint256 era) {
        uint256 allocation = token.MINING_ALLOCATION();
        while (era < 255 && totalGrossMined >= allocation - (allocation >> (era + 1))) {
            ++era;
            if ((allocation >> era) == 0) break;
        }
    }

    function currentBaseReward() public view returns (uint256) { return initialBaseReward >> currentEra(); }

    function previewReward(uint256 tokenId) public view returns (uint256 gross, uint256 fee, uint256 net, uint256 era) {
        uint256 power = genesis.getToken(tokenId).power;
        era = currentEra();
        gross = Math.mulDiv(initialBaseReward >> era, power, REFERENCE_POWER);
        uint256 remaining = token.MINING_ALLOCATION() - totalGrossMined;
        if (gross > remaining) gross = remaining;
        fee = Math.mulDiv(gross, feeBps, 10_000);
        net = gross - fee;
    }

    function submitTask(uint256 tokenId, uint256 expectedNonce, uint256 packedAnswer, uint256 minGrossReward) external nonReentrant {
        if (!miningOpen) revert MiningClosed();
        if (stakedBy[tokenId] != msg.sender) revert NotStaker();
        if (_eligibleAgent(msg.sender) != stakeAgentId[tokenId]) revert IdentityChanged();
        if (expectedNonce != taskNonce[tokenId]) revert StaleTask();
        if (lastSolvedBlock[tokenId] == block.number) revert SameBlock();
        if (!AgentTaskVerifier.verify(taskSeed[tokenId], packedAnswer)) revert InvalidAnswer();
        (uint256 gross, uint256 fee, uint256 net,) = previewReward(tokenId);
        if (gross == 0) revert MiningExhausted();
        if (gross < minGrossReward) revert RewardBelowMinimum();
        totalGrossMined += gross;
        ++totalSolved;
        ++completedTasks[msg.sender];
        netEarned[msg.sender] += net;
        lastSolvedBlock[tokenId] = block.number;
        _issue(tokenId, msg.sender);
        token.mintMining(msg.sender, net);
        if (fee != 0) token.mintMining(feeRecipient, fee);
        emit TaskSolved(tokenId, msg.sender, expectedNonce, gross, fee, net);
    }

    function _issue(uint256 tokenId, address staker) private {
        uint256 nonce = ++taskNonce[tokenId];
        bytes32 seed = keccak256(abi.encode(
            block.chainid, address(this), address(genesis), staker, tokenId, nonce, stakeAgentId[tokenId],
            taskSeed[tokenId], block.prevrandao, blockhash(block.number - 1)
        ));
        taskSeed[tokenId] = seed;
        emit TaskIssued(tokenId, staker, nonce, seed);
    }

    function _eligibleAgent(address account) private view returns (bytes32 agentId) {
        address verifier = genesis.identityVerifier();
        if (verifier == address(0) || verifier.code.length == 0) revert IdentityUnavailable();
        bool eligible;
        try IAgentIdentityVerifier(verifier).isEligible(account) returns (bool result) { eligible = result; }
        catch { revert IdentityUnavailable(); }
        if (!eligible) revert NotEligible();
        try IAgentIdentityVerifier(verifier).agentIdOf(account) returns (bytes32 id) { agentId = id; }
        catch { revert IdentityUnavailable(); }
        if (agentId == bytes32(0)) revert IdentityUnavailable();
    }
}
