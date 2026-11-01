// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721ConsecutiveUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721ConsecutiveUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IAgentIdentityVerifier, IGenesisStakeLock} from "./ProtocolInterfaces.sol";

/// @notice Genesis ERC721 with fixed-at-mint HP and a fixed-price BNB marketplace.
/// @dev Initial IDs 0..2099 are allocated with ERC2309; no 2100-token storage loop.
/// IdentityVerifier is a project adapter, not an assumed official registry ABI.
/// HP entropy is predictable and can be influenced by salt selection and block producers.
/// ReentrancyGuard uses a namespaced slot; a proxy's initial zero status is accepted and normalized on first use.
contract GenesisMiner is Initializable, ERC721ConsecutiveUpgradeable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuard, IGenesisStakeLock, IERC4906 {
    using Strings for uint256;

    uint256 public constant SUPPLY_CAP = 21_000;
    uint256 public constant RESERVED_ALLOCATION = 2_100;
    uint256 public constant PUBLIC_ALLOCATION = 18_900;
    uint256 public constant salePrice = 0.0021 ether;
    uint256 public constant POWER_SCALE = 1_000_000;
    uint256 public constant MIN_POWER = 50 * POWER_SCALE;
    uint256 public constant MAX_POWER = 250 * POWER_SCALE;
    uint256 public constant RESERVED_POWER = 150 * POWER_SCALE;
    uint256 public constant MAX_MINTS_PER_AGENT = 21;
    uint256 public constant MARKET_FEE_BPS = 500;

    struct Config {
        address reserveRecipient;
        address identityVerifier;
        string imageURI;
    }
    struct Listing { address seller; uint256 price; uint256 listingId; bool active; }
    struct MarketListing { uint256 tokenId; address seller; uint256 price; uint256 listingId; }
    struct TokenView {
        address owner;
        uint256 power;
        bool staked;
        bool isReserved;
    }

    error InvalidAddress();
    error InvalidConfiguration();
    error MintClosed();
    error IdentityUnavailable();
    error NotEligible();
    error IdentityLocked();
    error SoldOut();
    error IncorrectPayment();
    error InvalidQuantity();
    error AgentMintLimit();
    error NotTokenOwner();
    error TokenStaked();
    error OnlyMiningPool();
    error PoolHasLocks();
    error InvalidStake();
    error StakingClosed();
    error InvalidPrice();
    error AlreadyListed();
    error ListingUnavailable();
    error StaleListing();
    error SelfPurchase();
    error InvalidPagination();
    error NothingToWithdraw();
    error InsufficientRevenue();
    error InsufficientMarketFees();
    error PaymentFailed();
    error BurnNotSupported();

    event PublicMinted(address indexed minter, uint256 indexed tokenId, uint256 price);
    event BatchMinted(address indexed minter, bytes32 indexed agentId, uint256 firstTokenId, uint256 quantity, uint16 bonusBps);
    event PowerFinalized(uint256 indexed tokenId, uint256 power);
    event ListingCreated(uint256 indexed tokenId, uint256 indexed listingId, address indexed seller, uint256 price);
    event ListingCancelled(uint256 indexed tokenId, uint256 indexed listingId, address indexed seller);
    event ListingFilled(uint256 indexed tokenId, uint256 indexed listingId, address indexed seller, address buyer, uint256 price);
    event MarketFeeAccrued(uint256 indexed tokenId, uint256 indexed listingId, uint256 amount);
    event MarketFeesWithdrawn(address indexed recipient, uint256 amount);
    event SaleRevenueWithdrawn(address indexed recipient, uint256 amount, bool liquidity);
    event MintOpenChanged(bool open);
    event IdentityVerifierChanged(address indexed verifier);
    event MiningPoolChanged(address indexed pool);
    event StakingOpenChanged(bool open);
    event StakeLockChanged(uint256 indexed tokenId, address indexed staker, bool locked);
    event ImageURIChanged(string imageURI);

    address public reserveRecipient;
    address public identityVerifier;
    bool public mintOpen;
    bool public stakingOpen;
    uint256 public publicMinted;
    uint256 public saleRevenue;
    uint256 public liquidityWithdrawn;
    uint256 public operationsWithdrawn;
    uint256 public marketFeeBalance;
    address public miningPool;
    uint256 public totalStakeLocks;
    mapping(uint256 => bool) public isStaked;
    mapping(uint256 => address) public stakedOwner;
    mapping(bytes32 => uint256) public mintedByAgent;
    mapping(uint256 => bytes32) public mintOriginAgentId;
    mapping(uint256 => uint16) public mintBonusBps;

    uint256 private _nextId;
    uint256 private _nextListingId;
    string private _imageURI;
    mapping(uint256 => uint256) private _power;
    mapping(bytes32 => mapping(uint256 => bool)) private _agentPowerUsed;
    mapping(uint256 => Listing) private _listings;
    uint256[] private _activeListings;
    mapping(uint256 => uint256) private _activeIndex;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    /// @dev Must run in the ERC1967Proxy constructor: ERC2309 allocation is construction-only.
    function initialize(Config memory c, address initialOwner) external initializer {
        __ERC721_init("4AgentCoin Genesis Miner", "4AGC-GEN");
        __ERC721Consecutive_init();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        if (c.reserveRecipient == address(0) || c.reserveRecipient == address(this)) revert InvalidAddress();
        if (c.identityVerifier != address(0) && c.identityVerifier.code.length == 0) revert InvalidAddress();
        if (bytes(c.imageURI).length == 0) revert InvalidConfiguration();
        reserveRecipient = c.reserveRecipient;
        identityVerifier = c.identityVerifier;
        _imageURI = c.imageURI;
        _mintConsecutive(c.reserveRecipient, uint96(RESERVED_ALLOCATION));
        _nextId = RESERVED_ALLOCATION;
        _nextListingId = 1;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function totalAllocated() public view returns (uint256) { return _nextId; }
    function totalSupply() external view returns (uint256) { return _nextId; }
    function reservedAllocated() external pure returns (uint256) { return RESERVED_ALLOCATION; }
    function genesisComplete() external view returns (bool) { return _nextId == SUPPLY_CAP; }

    function setIdentityVerifier(address verifier) external onlyOwner {
        if (publicMinted != 0) revert IdentityLocked();
        if (verifier != address(0) && verifier.code.length == 0) revert InvalidAddress();
        identityVerifier = verifier;
        emit IdentityVerifierChanged(verifier);
    }

    function setMintOpen(bool open) external onlyOwner {
        if (open && identityVerifier.code.length == 0) revert InvalidConfiguration();
        mintOpen = open;
        emit MintOpenChanged(open);
    }

    function isMintEligible(address account) external view returns (bool) {
        if (identityVerifier == address(0)) return false;
        try IAgentIdentityVerifier(identityVerifier).isEligible(account) returns (bool eligible) {
            if (!eligible) return false;
        }
        catch { return false; }
        try IAgentIdentityVerifier(identityVerifier).agentIdOf(account) returns (bytes32 agentId) {
            return agentId != bytes32(0) && mintedByAgent[agentId] < MAX_MINTS_PER_AGENT;
        } catch { return false; }
    }

    function mint(bytes32 salt) external payable nonReentrant returns (uint256 tokenId) {
        return _mintBatch(1, salt);
    }

    function mintBatch(uint256 quantity, bytes32 salt) external payable nonReentrant returns (uint256 firstTokenId) {
        return _mintBatch(quantity, salt);
    }

    function _mintBatch(uint256 quantity, bytes32 salt) private returns (uint256 firstTokenId) {
        if (!mintOpen) revert MintClosed();
        if (quantity == 0 || quantity > MAX_MINTS_PER_AGENT) revert InvalidQuantity();
        if (_nextId + quantity > SUPPLY_CAP) revert SoldOut();
        if (msg.value != salePrice * quantity) revert IncorrectPayment();
        address verifier = identityVerifier;
        if (verifier == address(0)) revert IdentityUnavailable();
        bool eligible;
        try IAgentIdentityVerifier(verifier).isEligible(msg.sender) returns (bool result) { eligible = result; }
        catch { revert IdentityUnavailable(); }
        if (!eligible) revert NotEligible();
        bytes32 agentId;
        try IAgentIdentityVerifier(verifier).agentIdOf(msg.sender) returns (bytes32 result) { agentId = result; }
        catch { revert IdentityUnavailable(); }
        if (agentId == bytes32(0)) revert IdentityUnavailable();
        if (mintedByAgent[agentId] + quantity > MAX_MINTS_PER_AGENT) revert AgentMintLimit();
        uint16 bonusBps = quantity <= 10 ? 300 : quantity <= 20 ? 600 : 1000;
        firstTokenId = _nextId;
        _nextId += quantity;
        publicMinted += quantity;
        mintedByAgent[agentId] += quantity;
        saleRevenue += msg.value;
        for (uint256 i; i < quantity; ++i) {
            uint256 tokenId = firstTokenId + i;
            mintOriginAgentId[tokenId] = agentId;
            mintBonusBps[tokenId] = bonusBps;
            // Store power before the ERC721 receiver callback can inspect the new NFT.
            uint256 power = _assignPower(tokenId, agentId, bonusBps, salt, i);
            _safeMint(msg.sender, tokenId);
            emit PublicMinted(msg.sender, tokenId, salePrice);
            emit PowerFinalized(tokenId, power);
        }
        emit BatchMinted(msg.sender, agentId, firstTokenId, quantity, bonusBps);
    }

    /// @dev Local random salt adds variation, not an unbiasable source of randomness.
    /// Every input is public or caller-controlled; users can search salts or choose inclusion.
    function _assignPower(uint256 tokenId, bytes32 agentId, uint16 bonusBps, bytes32 salt, uint256 batchIndex) private returns (uint256) {
        bytes32 entropy = keccak256(abi.encode(
            "GENESIS_MINT_POWER_V1", salt, blockhash(block.number - 1), tokenId,
            agentId, batchIndex, block.chainid, address(this)
        ));
        uint256 precision = 1e18;
        uint256 u = uint256(entropy) % (precision + 1);
        uint256 r = Math.mulDiv(u, u, precision);
        uint256 adjusted = Math.mulDiv(r, (10_000 + uint256(bonusBps)) * precision, 10_000 * precision + uint256(bonusBps) * r);
        uint256 candidate = MIN_POWER + Math.mulDiv(MAX_POWER - MIN_POWER, adjusted, precision);
        for (uint256 attempt; attempt < MAX_MINTS_PER_AGENT; ++attempt) {
            if (!_agentPowerUsed[agentId][candidate]) {
                _agentPowerUsed[agentId][candidate] = true;
                _power[tokenId] = candidate;
                return candidate;
            }
            candidate = candidate == MAX_POWER ? MIN_POWER : candidate + 1;
        }
        // At most 20 other public miners share this ID, so 21 probes find a free value.
        revert InvalidConfiguration();
    }

    function getToken(uint256 tokenId) external view returns (TokenView memory) {
        address holder = ownerOf(tokenId);
        return TokenView(holder, tokenId < RESERVED_ALLOCATION ? RESERVED_POWER : _power[tokenId], isStaked[tokenId], tokenId < RESERVED_ALLOCATION);
    }

    function setMiningPool(address pool) external onlyOwner {
        if (totalStakeLocks != 0) revert PoolHasLocks();
        if (pool != address(0) && pool.code.length == 0) revert InvalidAddress();
        miningPool = pool;
        emit MiningPoolChanged(pool);
    }

    function setStakingOpen(bool open) external onlyOwner {
        if (open && (miningPool == address(0) || miningPool.code.length == 0)) revert InvalidConfiguration();
        stakingOpen = open;
        emit StakingOpenChanged(open);
    }

    function lockForStake(uint256 tokenId, address staker) external {
        if (msg.sender != miningPool || miningPool == address(0)) revert OnlyMiningPool();
        if (!stakingOpen) revert StakingClosed();
        if (ownerOf(tokenId) != staker || !_isAuthorized(staker, msg.sender, tokenId)) revert InvalidStake();
        if (isStaked[tokenId]) revert TokenStaked();
        _invalidateListing(tokenId);
        isStaked[tokenId] = true;
        stakedOwner[tokenId] = staker;
        ++totalStakeLocks;
        emit StakeLockChanged(tokenId, staker, true);
    }

    function unlockFromStake(uint256 tokenId, address staker) external {
        if (msg.sender != miningPool || miningPool == address(0)) revert OnlyMiningPool();
        if (!isStaked[tokenId] || stakedOwner[tokenId] != staker) revert InvalidStake();
        isStaked[tokenId] = false;
        delete stakedOwner[tokenId];
        --totalStakeLocks;
        emit StakeLockChanged(tokenId, staker, false);
    }

    function list(uint256 tokenId, uint256 price) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (isStaked[tokenId]) revert TokenStaked();
        if (price == 0) revert InvalidPrice();
        if (_listings[tokenId].active) revert AlreadyListed();
        uint256 listingId = _nextListingId++;
        _listings[tokenId] = Listing(msg.sender, price, listingId, true);
        _activeIndex[tokenId] = _activeListings.length + 1;
        _activeListings.push(tokenId);
        emit ListingCreated(tokenId, listingId, msg.sender, price);
    }

    function cancel(uint256 tokenId) external nonReentrant {
        Listing storage l = _listings[tokenId];
        if (!l.active) revert ListingUnavailable();
        if (l.seller != msg.sender) revert NotTokenOwner();
        _invalidateListing(tokenId);
    }

    function buy(uint256 tokenId, uint256 expectedListingId, uint256 expectedPrice) external payable nonReentrant {
        Listing memory l = _listings[tokenId];
        if (!l.active || ownerOf(tokenId) != l.seller) revert ListingUnavailable();
        if (l.listingId != expectedListingId || l.price != expectedPrice) revert StaleListing();
        if (msg.value != l.price) revert IncorrectPayment();
        if (l.seller == msg.sender) revert SelfPurchase();
        if (isStaked[tokenId]) revert TokenStaked();
        _removeListing(tokenId);
        uint256 fee = Math.mulDiv(l.price, MARKET_FEE_BPS, 10_000);
        uint256 sellerProceeds = l.price - fee;
        marketFeeBalance += fee;
        _safeTransfer(l.seller, msg.sender, tokenId);
        (bool success,) = payable(l.seller).call{value: sellerProceeds}("");
        if (!success) revert PaymentFailed();
        emit MarketFeeAccrued(tokenId, l.listingId, fee);
        emit ListingFilled(tokenId, l.listingId, l.seller, msg.sender, msg.value);
    }

    function getListing(uint256 tokenId) external view returns (Listing memory) { return _listings[tokenId]; }

    /// @dev Pagination is evaluated against one block snapshot; removal uses swap-and-pop.
    function getActiveListings(uint256 offset, uint256 limit) external view returns (MarketListing[] memory rows, uint256 total) {
        if (limit == 0 || limit > 100) revert InvalidPagination();
        total = _activeListings.length;
        if (offset >= total) return (new MarketListing[](0), total);
        uint256 count = total - offset;
        if (count > limit) count = limit;
        rows = new MarketListing[](count);
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = _activeListings[offset + i];
            Listing storage l = _listings[tokenId];
            rows[i] = MarketListing(tokenId, l.seller, l.price, l.listingId);
        }
    }

    function _invalidateListing(uint256 tokenId) private {
        Listing memory l = _listings[tokenId];
        if (!l.active) return;
        _removeListing(tokenId);
        emit ListingCancelled(tokenId, l.listingId, l.seller);
    }

    function _removeListing(uint256 tokenId) private {
        uint256 index = _activeIndex[tokenId] - 1;
        uint256 lastId = _activeListings[_activeListings.length - 1];
        _activeListings[index] = lastId;
        _activeIndex[lastId] = index + 1;
        _activeListings.pop();
        delete _activeIndex[tokenId];
        delete _listings[tokenId];
    }

    function withdrawMarketFees(address payable recipient, uint256 amount) external onlyOwner nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        if (amount == 0) revert NothingToWithdraw();
        if (amount > marketFeeBalance) revert InsufficientMarketFees();
        marketFeeBalance -= amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert PaymentFailed();
        emit MarketFeesWithdrawn(recipient, amount);
    }

    /// @notice Only actual mint revenue is withdrawable, separately for the two 50% budgets.
    /// Manual LP funding is not proof that an administrator subsequently added liquidity.
    function withdrawSaleRevenue(address payable recipient, uint256 amount, bool liquidity) external onlyOwner nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        if (amount == 0) revert NothingToWithdraw();
        uint256 budget = liquidity ? saleRevenue / 2 : saleRevenue - saleRevenue / 2;
        uint256 used = liquidity ? liquidityWithdrawn : operationsWithdrawn;
        if (amount > budget - used) revert InsufficientRevenue();
        if (liquidity) liquidityWithdrawn += amount;
        else operationsWithdrawn += amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert PaymentFailed();
        emit SaleRevenueWithdrawn(recipient, amount, liquidity);
    }

    /// @notice Shared full image URI; power attributes always come from on-chain state.
    function setImageURI(string calldata uri) external onlyOwner {
        if (bytes(uri).length == 0) revert InvalidConfiguration();
        _imageURI = uri;
        emit ImageURIChanged(uri);
        emit BatchMetadataUpdate(0, _nextId - 1);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint256 power = tokenId < RESERVED_ALLOCATION ? RESERVED_POWER : _power[tokenId];
        string memory attributes = string.concat(
            '{"trait_type":"Power Status","value":"Finalized"}',
            ',{"display_type":"number","trait_type":"Hashrate","value":', _scaledNumber(power), '}'
        );
        bytes memory json = abi.encodePacked(
            '{"name":"4AgentCoin Genesis Miner #', tokenId.toString(),
            '","description":"Genesis miner with on-chain assigned power in HP.","image":"',
            Strings.escapeJSON(_imageURI), '","attributes":[', attributes, ',{"trait_type":"Series","value":"Genesis"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// @dev JSON numbers keep the six on-chain decimal places, including leading fractional zeroes.
    function _scaledNumber(uint256 value) private pure returns (string memory) {
        bytes memory fraction = bytes((POWER_SCALE + value % POWER_SCALE).toString());
        fraction[0] = ".";
        return string.concat((value / POWER_SCALE).toString(), string(fraction));
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(0)) revert BurnNotSupported();
        if (isStaked[tokenId]) revert TokenStaked();
        _invalidateListing(tokenId);
        return super._update(to, tokenId, auth);
    }
}
