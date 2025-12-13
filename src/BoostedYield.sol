// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////
                        OPENZEPPELIN IMPORTS
//////////////////////////////////////////////////////////////*/

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                        CONTRACT OVERVIEW
//////////////////////////////////////////////////////////////*/

/// @title BoostedYieldLockerUpgradeable
/// @author Your Name / Team
/// @notice
/// An upgradeable ERC721-based yield locking contract.
/// Users lock ERC20 tokens for a predefined lock period and
/// receive an NFT representing their locked position.
/// The NFT is required to redeem the locked tokens after maturity.
///
/// @dev
/// - Uses UUPS upgrade pattern
/// - Uses ERC721 NFTs as position receipts
/// - Uses SafeERC20 for token safety
/// - Lock periods are configurable and dynamic
contract BoostedYieldLockerUpgradeable is
    ERC721Upgradeable,
    ERC721BurnableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Configuration for supported ERC20 tokens
    /// @param tokenAddr ERC20 token contract address
    /// @param tokenName Human-readable token name (UI purpose)
    /// @param enabled Whether the token can be locked
    struct TokenConfig {
        address tokenAddr;
        string tokenName;
        bool enabled;
    }

    /// @notice Configuration for lock periods
    /// @param duration Lock duration in seconds
    /// @param label Human-readable label (e.g. "3 Months")
    /// @param enabled Whether this lock period is usable
    struct LockPeriodConfig {
        uint256 duration;
        string label;
        bool enabled;
    }

    /// @notice Represents a user lock position tied to an NFT
    /// @param tokenId ID of the token configuration used
    /// @param amount Amount of ERC20 tokens locked
    /// @param startTime Timestamp when lock started
    /// @param unlockTime Timestamp when tokens can be redeemed
    /// @param lockPeriodId ID of the lock period configuration
    struct LockPosition {
        uint256 tokenId;
        uint256 amount;
        uint256 startTime;
        uint256 unlockTime;
        uint256 lockPeriodId;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Incremental ID for lock period configurations
    uint256 public nextLockPeriodId;

    /// @dev Internal counter for NFT IDs (starts at 1)
    uint256 private _nextNftId;

    /// @notice tokenConfigId => TokenConfig
    mapping(uint256 => TokenConfig) public tokenConfigs;

    /// @notice lockPeriodId => LockPeriodConfig
    mapping(uint256 => LockPeriodConfig) public lockPeriods;

    /// @notice nftId => LockPosition
    mapping(uint256 => LockPosition) public positions;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an ERC20 token is configured
    event TokenConfigured(
        uint256 indexed tokenId,
        address indexed tokenAddr,
        string tokenName,
        bool enabled
    );

    /// @notice Emitted when a lock period is configured
    event LockPeriodConfigured(
        uint256 indexed lockPeriodId,
        uint256 duration,
        string label,
        bool enabled
    );

    /// @notice Emitted when a user locks tokens and receives an NFT
    event Locked(
        address indexed user,
        uint256 indexed nftId,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 lockPeriodId,
        uint256 startTime,
        uint256 unlockTime
    );

    /// @notice Emitted when a user redeems tokens and burns the NFT
    event Redeemed(
        address indexed user,
        uint256 indexed nftId,
        uint256 indexed tokenId,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the contract (called once via proxy)
    /// @param owner_ Address to be set as the contract owner
    function initialize(address owner_) external initializer {
        __ERC721_init("Boosted Yield Position", "BYP");
        __ERC721Burnable_init();
        __Ownable_init(owner_);

        _nextNftId = 1;

        // Default lock periods
        _addLockPeriod(90 days, "3 Months");
        _addLockPeriod(180 days, "6 Months");
        _addLockPeriod(365 days, "12 Months");
    }

    /*//////////////////////////////////////////////////////////////
                        UUPS AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts upgrades to the contract owner
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds or updates an ERC20 token configuration
    /// @param tokenId Arbitrary token configuration ID
    /// @param tokenAddr ERC20 token address
    /// @param tokenName Human-readable name
    /// @param enabled Whether locking is enabled
    function configureToken(
        uint256 tokenId,
        address tokenAddr,
        string calldata tokenName,
        bool enabled
    ) external onlyOwner {
        require(tokenAddr != address(0), "Invalid token");

        tokenConfigs[tokenId] = TokenConfig({
            tokenAddr: tokenAddr,
            tokenName: tokenName,
            enabled: enabled
        });

        emit TokenConfigured(tokenId, tokenAddr, tokenName, enabled);
    }

    /// @notice Adds or updates a lock period configuration
    /// @param lockPeriodId Lock period ID
    /// @param duration Lock duration in seconds
    /// @param label Human-readable label
    /// @param enabled Whether the lock period is active
    function configureLockPeriod(
        uint256 lockPeriodId,
        uint256 duration,
        string calldata label,
        bool enabled
    ) external onlyOwner {
        require(duration > 0, "Invalid duration");

        lockPeriods[lockPeriodId] = LockPeriodConfig({
            duration: duration,
            label: label,
            enabled: enabled
        });

        emit LockPeriodConfigured(lockPeriodId, duration, label, enabled);
    }

    /*//////////////////////////////////////////////////////////////
                        USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Locks ERC20 tokens and mints an NFT position
    /// @param tokenId Token configuration ID
    /// @param lockPeriodId Lock period configuration ID
    /// @param amount Amount of tokens to lock
    /// @return nftId Newly minted NFT ID
    function lock(
        uint256 tokenId,
        uint256 lockPeriodId,
        uint256 amount
    ) external nonReentrant returns (uint256 nftId) {
        TokenConfig memory token = tokenConfigs[tokenId];
        LockPeriodConfig memory period = lockPeriods[lockPeriodId];

        require(token.enabled, "Token disabled");
        require(period.enabled, "Lock period disabled");
        require(amount > 0, "Invalid amount");

        uint256 unlockTime = block.timestamp + period.duration;

        IERC20(token.tokenAddr).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        nftId = _nextNftId++;
        _safeMint(msg.sender, nftId);

        positions[nftId] = LockPosition({
            tokenId: tokenId,
            amount: amount,
            startTime: block.timestamp,
            unlockTime: unlockTime,
            lockPeriodId: lockPeriodId
        });

        emit Locked(
            msg.sender,
            nftId,
            tokenId,
            amount,
            lockPeriodId,
            block.timestamp,
            unlockTime
        );
    }

    /// @notice Redeems locked tokens after lock period ends
    /// @param nftId NFT representing the lock position
    function redeem(uint256 nftId) external nonReentrant {
        require(ownerOf(nftId) == msg.sender, "Not NFT owner");

        LockPosition memory pos = positions[nftId];
        require(block.timestamp >= pos.unlockTime, "Still locked");

        TokenConfig memory config = tokenConfigs[pos.tokenId];

        delete positions[nftId];
        _burn(nftId);

        IERC20(config.tokenAddr).safeTransfer(msg.sender, pos.amount);

        emit Redeemed(msg.sender, nftId, pos.tokenId, pos.amount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Adds a new lock period and auto-increments ID
    function _addLockPeriod(uint256 duration, string memory label) internal {
        uint256 id = ++nextLockPeriodId;

        lockPeriods[id] = LockPeriodConfig({
            duration: duration,
            label: label,
            enabled: true
        });
    }
}
