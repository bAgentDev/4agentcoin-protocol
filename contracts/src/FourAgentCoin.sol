// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FourAgentCoin is ERC20, Ownable2Step {
    uint256 public constant MAX_SUPPLY = 21_000_000 ether;
    uint256 public constant LP_ALLOCATION = 1_050_000 ether;
    uint256 public constant MINING_ALLOCATION = 19_950_000 ether;
    uint256 public constant SWAP_TAX_BPS = 100;
    address public immutable lpRecipient;
    address public feeRecipient;
    address public miningPool;
    uint256 public miningMinted;
    mapping(address => bool) public isAMMPair;
    mapping(address => bool) public isTaxExempt;

    error InvalidAddress();
    error OnlyMiningPool();
    error MiningPoolLocked();
    error MiningCapExceeded();
    error ZeroMint();
    event MiningPoolChanged(address indexed pool);
    event AMMPairChanged(address indexed pair, bool registered);
    event TaxExemptionChanged(address indexed account, bool exempt);
    event FeeRecipientChanged(address indexed recipient);

    constructor(address lpRecipient_, address feeRecipient_) ERC20("4AgentCoin", "4AGC") Ownable(msg.sender) {
        if (lpRecipient_ == address(0) || feeRecipient_ == address(0)) revert InvalidAddress();
        lpRecipient = lpRecipient_;
        feeRecipient = feeRecipient_;
        isTaxExempt[lpRecipient_] = true;
        emit TaxExemptionChanged(lpRecipient_, true);
        _mint(lpRecipient_, LP_ALLOCATION);
    }

    function setMiningPool(address pool) external onlyOwner {
        if (miningMinted != 0) revert MiningPoolLocked();
        if (pool == address(0) || pool.code.length == 0) revert InvalidAddress();
        miningPool = pool;
        emit MiningPoolChanged(pool);
    }

    function setAMMPair(address pair, bool registered) external onlyOwner {
        if (pair == address(0) || pair.code.length == 0) revert InvalidAddress();
        isAMMPair[pair] = registered;
        emit AMMPairChanged(pair, registered);
    }

    function setTaxExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isTaxExempt[account] = exempt;
        emit TaxExemptionChanged(account, exempt);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidAddress();
        feeRecipient = recipient;
        emit FeeRecipientChanged(recipient);
    }

    /// @dev There is no owner mint path. The configured pool accounts for gross issuance.
    function mintMining(address recipient, uint256 amount) external {
        if (msg.sender != miningPool || miningPool == address(0)) revert OnlyMiningPool();
        if (amount == 0) revert ZeroMint();
        if (amount > MINING_ALLOCATION - miningMinted) revert MiningCapExceeded();
        miningMinted += amount;
        _mint(recipient, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && (isAMMPair[from] || isAMMPair[to])
            && !isTaxExempt[from] && !isTaxExempt[to]) {
            uint256 fee = Math.mulDiv(value, SWAP_TAX_BPS, 10_000);
            if (fee != 0) super._update(from, feeRecipient, fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
