// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {BoostedYieldLockerUpgradeable} from "../src/BoostedYield.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BoostedYieldTest is Test {
    BoostedYieldLockerUpgradeable locker;
    MockERC20 token;

    address owner = address(0x1);
    address user = address(0x2);

    uint256 constant TOKEN_ID = 1;
    uint256 constant LOCK_PERIOD_3M = 1;
    uint256 constant STAKE_AMOUNT = 1_000 ether;

    function setUp() public {
        vm.startPrank(owner);

        // deploy contracts
        locker = new BoostedYieldLockerUpgradeable();
        locker.initialize(owner);

        token = new MockERC20();

        // configure token
        locker.configureToken(TOKEN_ID, address(token), "Mock Token", true);

        vm.stopPrank();

        // fund user
        token.mint(user, 10_000 ether);

        vm.prank(user);
        token.approve(address(locker), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_setsDefaults() public view {
        assertEq(locker.owner(), owner);
        assertEq(locker.nextLockPeriodId(), 3);

        (uint256 duration,, bool enabled) = locker.lockPeriods(1);
        assertEq(duration, 90 days);
        assertTrue(enabled);
    }

    /*//////////////////////////////////////////////////////////////
                              LOCK
    //////////////////////////////////////////////////////////////*/

    function test_lock_createsNFTAndStoresPosition() public {
        vm.prank(user);
        uint256 nftId = locker.lock(TOKEN_ID, LOCK_PERIOD_3M, STAKE_AMOUNT);

        // NFT ownership
        assertEq(locker.ownerOf(nftId), user);

        // position data
        (uint256 tokenId, uint256 amount, uint256 startTime, uint256 unlockTime, uint256 lockPeriodId) =
            locker.positions(nftId);

        assertEq(tokenId, TOKEN_ID);
        assertEq(amount, STAKE_AMOUNT);
        assertEq(lockPeriodId, LOCK_PERIOD_3M);
        assertEq(unlockTime, startTime + 90 days);

        // token transferred
        assertEq(token.balanceOf(address(locker)), STAKE_AMOUNT);
    }

    function test_lock_reverts_ifTokenDisabled() public {
        vm.prank(owner);
        locker.configureToken(TOKEN_ID, address(token), "Mock Token", false);

        vm.prank(user);
        vm.expectRevert("Token disabled");
        locker.lock(TOKEN_ID, LOCK_PERIOD_3M, STAKE_AMOUNT);
    }

    function test_lock_reverts_ifAmountZero() public {
        vm.prank(user);
        vm.expectRevert("Invalid amount");
        locker.lock(TOKEN_ID, LOCK_PERIOD_3M, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_redeem_afterLockPeriod() public {
        vm.prank(user);
        uint256 nftId = locker.lock(TOKEN_ID, LOCK_PERIOD_3M, STAKE_AMOUNT);

        // fast forward time
        vm.warp(block.timestamp + 90 days + 1);

        uint256 userBalanceBefore = token.balanceOf(user);

        vm.prank(user);
        locker.redeem(nftId);

        // NFT burned
        vm.expectRevert();
        locker.ownerOf(nftId);

        // token returned
        assertEq(token.balanceOf(user), userBalanceBefore + STAKE_AMOUNT);
    }

    function test_redeem_reverts_ifStillLocked() public {
        vm.prank(user);
        uint256 nftId = locker.lock(TOKEN_ID, LOCK_PERIOD_3M, STAKE_AMOUNT);

        vm.prank(user);
        vm.expectRevert("Still locked");
        locker.redeem(nftId);
    }

    function test_redeem_reverts_ifNotOwner() public {
        vm.prank(user);
        uint256 nftId = locker.lock(TOKEN_ID, LOCK_PERIOD_3M, STAKE_AMOUNT);

        vm.warp(block.timestamp + 90 days + 1);

        vm.prank(address(0x3));
        vm.expectRevert("Not NFT owner");
        locker.redeem(nftId);
    }
}
