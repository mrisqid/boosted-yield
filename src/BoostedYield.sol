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

import {IBoostedYield} from "./interfaces/IBoostedYield.sol";

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
    IBoostedYield,
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
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    bool public yieldCollectionEnabled;

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
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier yieldCollectionAllowed() {
        _yieldCollectionAllowed();
        _;
    }

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

        if (admin == address(0) || rewarder == address(0)) {
            revert InvalidAddress();
        }

        yieldCollectionEnabled = true;

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

    function setYieldCollectionEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit YieldCollectionChanged(yieldCollectionEnabled, enabled);
        yieldCollectionEnabled = enabled;
    }

    function addToken(
        address token,
        string calldata symbol
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), InvalidAddress());

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
        require(duration > 0, InvalidDuration());

        DurationInfo storage d = durationInfo[tokenId][duration];

        // If duration wasn't previously supported, require mintEnabled to be false
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
        uint256 principal,
        uint256 duration
    ) external nonReentrant returns (uint256 nftId) {
        TokenConfig storage tokenCfg = tokenConfigs[tokenId];
        require(tokenCfg.enabled, InvalidToken());
        require(principal > 0, InvalidAmount());

        DurationInfo storage d = durationInfo[tokenId][duration];
        require(d.isSupported && d.mintEnabled, InvalidDuration());

        // Calculate maturity timestamp - rounded down to the nearest day
        uint256 maturity = block.timestamp + duration;
        maturity = maturity - (maturity % 1 days);
        require(maturity <= type(uint40).max, "Maturity overflow");

        // Mint NFT
        _nextNftId++;
        nftId = _nextNftId;

        // Update duration liquidity tracking
        d.totalLiquidity += principal;

        // Update maturity bucket
        maturityBuckets[tokenId][duration][maturity]
            .totalLiquidity += principal;

        // Create position
        positions[nftId] = Position({
            tokenId: tokenId,
            principal: principal,
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

        // Transfer principal from user
        tokenCfg.token.safeTransferFrom(msg.sender, address(this), principal);
        _safeMint(msg.sender, nftId);

        emit PositionMinted(nftId, msg.sender, tokenId, principal, duration);
    }

    function mature(
        uint256 tokenId,
        uint256 duration,
        uint256 timestamp
    ) public {
        // Round timestamp to days to match mint behavior
        timestamp = timestamp - (timestamp % 1 days);
        require(timestamp <= block.timestamp, ImmaturePosition());

        // Iterate through supported durations
        MaturityBucket storage bucket = maturityBuckets[tokenId][duration][
            timestamp
        ];

        if (bucket.totalLiquidity > 0) {
            // Snapshot current fee growth for this duration
            bucket.feeGrowthX128AtMaturity = durationInfo[tokenId][duration]
                .feeGrowthX128;

            // Remove liquidity from active tracking
            durationInfo[tokenId][duration].totalLiquidity -= bucket
                .totalLiquidity;

            emit MaturityProcessed(
                duration,
                timestamp,
                bucket.totalLiquidity,
                bucket.feeGrowthX128AtMaturity
            );
            // Clear bucket (optional, but saves gas on future reads)
            bucket.totalLiquidity = 0;
        }
    }

    function collect(
        uint256 nftId
    ) external nonReentrant yieldCollectionAllowed returns (uint256) {
        _checkAuthorized(_ownerOf(nftId), msg.sender, nftId);

        Position storage p = positions[nftId];

        // Update fees owed
        _updatePosition(nftId);

        uint256 owed = p.tokensOwed;
        if (owed > 0) {
            p.tokensOwed = 0;
            tokenConfigs[p.tokenId].token.safeTransfer(msg.sender, owed);
            emit FeesCollected(nftId, owed);
        }

        return owed;
    }

    function unrealizedRewards(uint256 nftId) external view returns (uint256) {
        (uint256 feesAccrued, ) = _unrealizedRewards(positions[nftId]);
        return feesAccrued;
    }

    function withdraw(uint256 nftId) external nonReentrant {
        _checkAuthorized(_ownerOf(nftId), msg.sender, nftId);

        Position storage p = positions[nftId];
        require(
            block.timestamp >= p.startTime + p.duration,
            ImmaturePosition()
        );

        // Mature the position if it hasn't been matured yet
        if (
            maturityBuckets[p.tokenId][p.duration][p.maturityTime]
                .feeGrowthX128AtMaturity == 0
        ) {
            mature(p.tokenId, p.duration, p.maturityTime);
        }

        // Collect any remaining fees
        _updatePosition(nftId);
        uint256 tokensOwed = p.tokensOwed;
        p.tokensOwed = 0;

        // Transfer principal + fees
        uint256 totalAmount = p.principal + tokensOwed;

        // Update bucket state
        p.principal = 0;

        // Burn NFT
        _burn(nftId);

        // Transfer funds
        tokenConfigs[p.tokenId].token.safeTransfer(msg.sender, totalAmount);

        emit PositionClosed(
            p.tokenId,
            msg.sender,
            totalAmount - tokensOwed,
            p.duration
        );
        emit FeesCollected(p.tokenId, tokensOwed);
    }

    function getPosition(
        uint256 nftId
    ) external view returns (Position memory) {
        Position storage position = positions[nftId];
        return position;
    }

    function isDurationSupported(
        uint256 tokenId,
        uint256 duration
    ) external view returns (bool) {
        return durationInfo[tokenId][duration].isSupported;
    }

    function isMintEnabled(
        uint256 tokenId,
        uint256 duration
    ) external view returns (bool) {
        return durationInfo[tokenId][duration].mintEnabled;
    }

    function getDurationInfo(
        uint256 tokenId,
        uint256 duration
    ) external view returns (DurationInfo memory) {
        return durationInfo[tokenId][duration];
    }

    function getMaturityBucket(
        uint256 tokenId,
        uint256 duration,
        uint256 timestamp
    ) external view returns (MaturityBucket memory) {
        return maturityBuckets[tokenId][duration][timestamp];
    }

    function getTokenConfig(
        uint256 tokenId
    ) external view returns (TokenConfig memory) {
        return tokenConfigs[tokenId];
    }

    function getLastMaturedDate(
        uint256 tokenId,
        uint256 duration
    ) external view returns (uint256) {
        return lastMaturedDate[tokenId][duration];
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

    /*//////////////////////////////////////////////////////////////
                        REWARDER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositRewards(
        uint256 tokenId,
        uint256 duration,
        uint256 amount
    ) external nonReentrant onlyRole(REWARDER_ROLE) {
        TokenConfig storage tokenCfg = tokenConfigs[tokenId];
        require(tokenCfg.enabled, InvalidToken());
        require(durationInfo[tokenId][duration].isSupported, InvalidDuration());
        require(amount > 0, InvalidAmount());

        // Clean up matured buckets first
        _cleanupMaturedBuckets(tokenId, duration);

        uint256 totalActiveLiquidity = durationInfo[tokenId][duration]
            .totalLiquidity;
        // We return instead of revert to commit bucket maturity changes
        if (totalActiveLiquidity == 0) {
            return;
        }

        // Update fee growth directly for the duration
        uint256 feeGrowthDeltaX128 = (amount << 128) / totalActiveLiquidity;
        durationInfo[tokenId][duration].feeGrowthX128 += feeGrowthDeltaX128;

        // Transfer rewards
        tokenCfg.token.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardsDeposited(tokenId, duration, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function _updatePosition(uint256 nftId) internal {
        Position storage p = positions[nftId];

        uint256 feesAccrued;
        uint256 currentFeeGrowth;
        (feesAccrued, currentFeeGrowth) = _unrealizedRewards(p);

        if (feesAccrued > 0) {
            p.tokensOwed += feesAccrued;
            p.feeGrowthInsideLastX128 = currentFeeGrowth;
        }
    }

    function _cleanupMaturedBuckets(
        uint256 tokenId,
        uint256 duration
    ) internal {
        uint256 lastMatured = lastMaturedDate[tokenId][duration];
        uint256 currentDate = block.timestamp - (block.timestamp % 1 days);

        // If nothing matured yet, start from the earliest possible safe date
        if (lastMatured == 0) {
            // If duration is longer than time elapsed, nothing can be matured yet
            if (block.timestamp < duration) {
                lastMaturedDate[tokenId][duration] = currentDate;
                return;
            }

            uint256 maturity = block.timestamp - duration;
            lastMatured = maturity - (maturity % 1 days);
        }

        for (uint256 date = lastMatured; date <= currentDate; date += 1 days) {
            MaturityBucket storage bucket = maturityBuckets[tokenId][duration][
                date
            ];

            if (bucket.totalLiquidity > 0) {
                mature(tokenId, duration, date);
            }
        }

        lastMaturedDate[tokenId][duration] = currentDate;
    }

    function _unrealizedRewards(
        Position memory position
    ) internal view returns (uint256, uint256) {
        uint256 currentFeeGrowth;

        // If position is matured, use the snapshotted fee growth
        if (block.timestamp >= position.maturityTime) {
            currentFeeGrowth = maturityBuckets[position.tokenId][
                position.duration
            ][position.maturityTime].feeGrowthX128AtMaturity;
        } else {
            // Otherwise use current fee growth for the duration
            currentFeeGrowth = durationInfo[position.tokenId][position.duration]
                .feeGrowthX128;
        }

        uint256 feeGrowthDeltaX128 = currentFeeGrowth -
            position.feeGrowthInsideLastX128;

        // Return the fees accrued and the current fee growth so that trackers know the
        // reference value
        return (
            (position.principal * feeGrowthDeltaX128) >> 128,
            currentFeeGrowth
        );
    }

    function _yieldCollectionAllowed() internal view {
        if (!yieldCollectionEnabled) {
            revert OperationNotAllowed();
        }
    }
}
