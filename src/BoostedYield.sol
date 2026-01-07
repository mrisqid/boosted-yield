// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////
                        OPENZEPPELIN IMPORTS
//////////////////////////////////////////////////////////////*/

import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                        CONTRACT OVERVIEW
//////////////////////////////////////////////////////////////*/

/// @title BoostedYield
/// @author Your Team
/// @notice
/// Multi-token NFT-based staking contract with duration-based yield distribution.
/// Each NFT represents a staking position for a specific ERC20 token and duration.
///
/// @dev
/// - Multiple staking tokens supported
/// - Falcon-style feeGrowthX128 accounting
/// - Single ERC721 for all positions
/// - Upgradeable via UUPS
contract BoostedYield is
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC20 staking token configuration
    struct TokenConfig {
        IERC20 token;
        string symbol;
        bool enabled;
    }

    /// @notice Duration-tier accounting (per token)
    struct DurationInfo {
        bool isSupported;
        bool mintEnabled;
        uint256 totalLiquidity;
        uint256 feeGrowthX128;
    }

    /// @notice NFT staking position
    struct Position {
        uint256 tokenId;
        uint256 principal;
        uint40 duration;
        uint40 startTime;
        uint40 maturityTime;
        uint256 feeGrowthInsideLastX128;
        uint256 tokensOwed;
    }

    /// @notice Bucket for matured positions
    struct MaturityBucket {
        uint256 totalLiquidity;
        uint256 feeGrowthX128AtMaturity;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC721 token counter
    uint256 internal _nextNftId;

    /// @notice Staking token registry
    uint256 public nextTokenId;
    mapping(uint256 => TokenConfig) public tokenConfigs;

    /// @notice tokenId => duration => DurationInfo
    mapping(uint256 => mapping(uint256 => DurationInfo)) internal durationInfo;

    /// @notice tokenId => duration => maturityTime => bucket
    mapping(uint256 => mapping(uint256 => mapping(uint256 => MaturityBucket)))
        public maturityBuckets;

    /// @notice tokenId => duration => last matured timestamp
    mapping(uint256 => mapping(uint256 => uint256)) public lastMaturedDate;

    /// @notice nftId => Position
    mapping(uint256 => Position) internal positions;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenAdded(uint256 indexed tokenId, address token, string symbol);
    event DurationUpdated(
        uint256 indexed tokenId,
        uint256 duration,
        bool supported,
        bool mintEnabled
    );

    event PositionMinted(
        uint256 indexed nftId,
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 duration
    );

    event RewardsDeposited(
        uint256 indexed tokenId,
        uint256 duration,
        uint256 amount
    );
    event FeesCollected(uint256 indexed nftId, uint256 amount);
    event PositionClosed(
        uint256 indexed nftId,
        address indexed user,
        uint256 principal,
        uint256 fees
    );

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address rewarder) external initializer {
        __ERC721_init("Boosted Yield Position", "BYP");
        __ERC721Enumerable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARDER_ROLE, rewarder);

        _nextNftId = 1;
    }

    /*//////////////////////////////////////////////////////////////
                        UUPS AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(
        address
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addToken(
        address token,
        string calldata symbol
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token");

        nextTokenId++;
        tokenConfigs[nextTokenId] = TokenConfig({
            token: IERC20(token),
            symbol: symbol,
            enabled: true
        });

        emit TokenAdded(nextTokenId, token, symbol);
    }

    function updateDuration(
        uint256 tokenId,
        uint256 duration,
        bool supported,
        bool mintEnabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(duration > 0, "Invalid duration");

        DurationInfo storage d = durationInfo[tokenId][duration];

        if (!d.isSupported && supported) {
            durationInfo[tokenId][duration] = DurationInfo({
                isSupported: true,
                mintEnabled: mintEnabled,
                totalLiquidity: 0,
                feeGrowthX128: 0
            });
        } else {
            d.isSupported = supported;
            d.mintEnabled = mintEnabled;
        }

        emit DurationUpdated(tokenId, duration, supported, mintEnabled);
    }

    /*//////////////////////////////////////////////////////////////
                        USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function mint(
        uint256 tokenId,
        uint256 amount,
        uint256 duration
    ) external nonReentrant returns (uint256 nftId) {
        TokenConfig storage tokenCfg = tokenConfigs[tokenId];
        require(tokenCfg.enabled, "Token disabled");
        require(amount > 0, "Invalid amount");

        DurationInfo storage d = durationInfo[tokenId][duration];
        require(d.isSupported && d.mintEnabled, "Invalid duration");

        uint256 maturity = block.timestamp + duration;

        // floor to day precision
        maturity = maturity - (maturity % 1 days);
        require(maturity <= type(uint40).max, "Maturity overflow");

        _nextNftId++;
        nftId = _nextNftId;

        d.totalLiquidity += amount;
        maturityBuckets[tokenId][duration][maturity].totalLiquidity += amount;

        positions[nftId] = Position({
            tokenId: tokenId,
            principal: amount,
            // casting to uint40 is safe because duration is bounded above
            // forge-lint: disable-next-line(unsafe-typecast)
            duration: uint40(duration),
            startTime: uint40(block.timestamp),
            // casting to uint40 is safe because maturity <= type(uint40).max
            // forge-lint: disable-next-line(unsafe-typecast)
            maturityTime: uint40(maturity),
            feeGrowthInsideLastX128: d.feeGrowthX128,
            tokensOwed: 0
        });

        tokenCfg.token.safeTransferFrom(msg.sender, address(this), amount);
        _safeMint(msg.sender, nftId);

        emit PositionMinted(nftId, msg.sender, tokenId, amount, duration);
    }

    function collect(uint256 nftId) external nonReentrant returns (uint256) {
        require(ownerOf(nftId) == msg.sender, "Not owner");

        Position storage p = positions[nftId];
        _updatePosition(nftId);

        uint256 owed = p.tokensOwed;
        if (owed > 0) {
            p.tokensOwed = 0;
            tokenConfigs[p.tokenId].token.safeTransfer(msg.sender, owed);
            emit FeesCollected(nftId, owed);
        }

        return owed;
    }

    function withdraw(uint256 nftId) external nonReentrant {
        require(ownerOf(nftId) == msg.sender, "Not owner");

        Position storage p = positions[nftId];
        require(block.timestamp >= p.startTime + p.duration, "Not matured");

        _updatePosition(nftId);

        uint256 principal = p.principal;
        uint256 fees = p.tokensOwed;
        uint256 tokenId = p.tokenId;

        delete positions[nftId];
        _burn(nftId);

        IERC20 token = tokenConfigs[tokenId].token;

        token.safeTransfer(msg.sender, principal);

        if (fees > 0) {
            token.safeTransfer(msg.sender, fees);
            emit FeesCollected(nftId, fees);
        }

        emit PositionClosed(nftId, msg.sender, principal, fees);
    }

    /*//////////////////////////////////////////////////////////////
                        REWARDER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositRewards(
        uint256 tokenId,
        uint256 duration,
        uint256 amount
    ) external nonReentrant onlyRole(REWARDER_ROLE) {
        require(amount > 0, "Invalid amount");

        DurationInfo storage d = durationInfo[tokenId][duration];
        require(d.totalLiquidity > 0, "No liquidity");

        uint256 delta = (amount << 128) / d.totalLiquidity;
        d.feeGrowthX128 += delta;

        tokenConfigs[tokenId].token.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        emit RewardsDeposited(tokenId, duration, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function _updatePosition(uint256 nftId) internal {
        Position storage p = positions[nftId];

        uint256 currentFeeGrowth = durationInfo[p.tokenId][p.duration]
            .feeGrowthX128;

        uint256 delta = currentFeeGrowth - p.feeGrowthInsideLastX128;

        if (delta > 0) {
            uint256 accrued = (p.principal * delta) >> 128;
            p.tokensOwed += accrued;
            p.feeGrowthInsideLastX128 = currentFeeGrowth;
        }
    }

    function getPosition(
        uint256 nftId
    ) external view returns (Position memory) {
        return positions[nftId];
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
