// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBoostedYield {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OperationNotAllowed();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidToken();
    error ImmaturePosition();

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct TokenConfig {
        string symbol;
        bool enabled;
    }

    struct DurationInfo {
        bool isSupported;
        bool mintEnabled;
        uint256 totalLiquidity;
        uint256 feeGrowthX128;
    }

    struct Position {
        address token;
        uint256 principal;
        uint40 duration;
        uint40 startTime;
        uint40 maturityTime;
        uint256 feeGrowthInsideLastX128;
        uint256 tokensOwed;
    }

    struct MaturityBucket {
        uint256 totalLiquidity;
        uint256 feeGrowthX128AtMaturity;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event YieldCollectionChanged(bool oldEnabled, bool newEnabled);

    event TokenAdded(address indexed token, string symbol);

    event DurationUpdated(address indexed token, uint256 duration, bool supported, bool mintEnabled);

    event PositionMinted(
        uint256 indexed nftId, address indexed user, address indexed token, uint256 principal, uint256 duration
    );

    event RewardsDeposited(address indexed token, uint256 duration, uint256 amount);

    event FeesCollected(uint256 indexed nftId, uint256 amount);

    event PositionClosed(uint256 indexed nftId, address indexed user, uint256 principal, uint256 fees);

    event MaturityProcessed(uint256 duration, uint256 timestamp, uint256 totalLiquidity, uint256 feeGrowthX128);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address admin, address rewarder) external;

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setYieldCollectionEnabled(bool enabled) external;

    function addToken(address token, string calldata symbol) external;

    function updateDuration(address token, uint256 duration, bool supported, bool mintEnabled) external;

    /*//////////////////////////////////////////////////////////////
                            USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function mint(address token, uint256 principal, uint256 duration) external returns (uint256 nftId);

    function collect(uint256 nftId) external returns (uint256);

    function withdraw(uint256 nftId) external;

    function unrealizedRewards(uint256 nftId) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        REWARDER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositRewards(address token, uint256 duration, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getPosition(uint256 nftId) external view returns (Position memory);

    function getDurationInfo(address token, uint256 duration) external view returns (DurationInfo memory);

    function isDurationSupported(address token, uint256 duration) external view returns (bool);

    function isMintEnabled(address token, uint256 duration) external view returns (bool);

    function getMaturityBucket(address token, uint256 duration, uint256 timestamp)
        external
        view
        returns (MaturityBucket memory);

    function getTokenConfig(address token) external view returns (TokenConfig memory);

    function getLastMaturedDate(address token, uint256 duration) external view returns (uint256);

    function yieldCollectionEnabled() external view returns (bool);
}
