// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BoostedYield} from "../src/BoostedYield.sol";
import {IBoostedYield} from "../src/interfaces/IBoostedYield.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BoostedYieldTest is Test {
    BoostedYield vault;
    MockERC20 token;

    address admin = address(0x1);
    address rewarder = address(0x2);
    address user = address(0x3);

    uint256 constant DURATION = 30 days;
    uint256 constant STAKE_AMOUNT = 1_000 ether;
    uint256 constant REWARD_AMOUNT = 500 ether;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.startPrank(admin);

        BoostedYield impl = new BoostedYield();

        bytes memory initData = abi.encodeCall(BoostedYield.initialize, (admin, rewarder));

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        vault = BoostedYield(address(proxy));

        token = new MockERC20();

        vault.addToken(address(token), "MOCK");
        vault.updateDuration(address(token), DURATION, true, true);

        vm.stopPrank();

        token.mint(user, 10_000 ether);
        token.mint(rewarder, 10_000 ether);

        vm.prank(user);
        token.approve(address(vault), type(uint256).max);

        vm.prank(rewarder);
        token.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_setsRolesAndFlags() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.REWARDER_ROLE(), rewarder));
        assertTrue(vault.yieldCollectionEnabled());
    }

    /*//////////////////////////////////////////////////////////////
                                MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_createsPositionNFT() public {
        vm.prank(user);
        uint256 nftId = vault.mint(address(token), STAKE_AMOUNT, DURATION);

        assertEq(vault.ownerOf(nftId), user);

        BoostedYield.Position memory pos = vault.getPosition(nftId);

        assertEq(pos.token, address(token));
        assertEq(pos.principal, STAKE_AMOUNT);
        assertEq(pos.duration, DURATION);
        assertGt(pos.startTime, 0);
        assertGt(pos.maturityTime, pos.startTime);
        assertEq(pos.tokensOwed, 0);

        assertEq(token.balanceOf(address(vault)), STAKE_AMOUNT);
    }

    function test_mint_reverts_ifAmountZero() public {
        vm.prank(user);
        vm.expectRevert(IBoostedYield.InvalidAmount.selector);
        vault.mint(address(token), 0, DURATION);
    }

    function test_mint_reverts_ifDurationNotSupported() public {
        vm.prank(user);
        vm.expectRevert(IBoostedYield.InvalidDuration.selector);
        vault.mint(address(token), STAKE_AMOUNT, 15 days);
    }

    /*//////////////////////////////////////////////////////////////
                            REWARDS
    //////////////////////////////////////////////////////////////*/

    function test_depositRewards_and_collect() public {
        vm.prank(user);
        uint256 nftId = vault.mint(address(token), STAKE_AMOUNT, DURATION);

        vm.prank(rewarder);
        vault.depositRewards(address(token), DURATION, REWARD_AMOUNT);

        uint256 unrealized = vault.unrealizedRewards(nftId);
        assertEq(unrealized, REWARD_AMOUNT);

        vm.prank(user);
        uint256 collected = vault.collect(nftId);

        assertEq(collected, REWARD_AMOUNT);
        assertEq(vault.unrealizedRewards(nftId), 0);
    }

    function test_collect_reverts_whenDisabled() public {
        vm.prank(admin);
        vault.setYieldCollectionEnabled(false);

        vm.prank(user);
        uint256 nftId = vault.mint(address(token), STAKE_AMOUNT, DURATION);

        vm.prank(rewarder);
        vault.depositRewards(address(token), DURATION, REWARD_AMOUNT);

        vm.prank(user);
        vm.expectRevert(IBoostedYield.OperationNotAllowed.selector);
        vault.collect(nftId);
    }

    /*//////////////////////////////////////////////////////////////
                                MATURITY
    //////////////////////////////////////////////////////////////*/

    function test_maturity_bucket_snapshots_feeGrowth() public {
        vm.prank(user);
        uint256 nftId = vault.mint(address(token), STAKE_AMOUNT, DURATION);

        vm.prank(rewarder);
        vault.depositRewards(address(token), DURATION, REWARD_AMOUNT);

        vm.warp(block.timestamp + DURATION + 1);

        BoostedYield.Position memory pos = vault.getPosition(nftId);

        vault.mature(address(token), DURATION, pos.maturityTime);

        BoostedYield.DurationInfo memory info = vault.getDurationInfo(address(token), DURATION);

        assertGt(info.feeGrowthX128, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_afterMaturity() public {
        vm.prank(user);
        uint256 nftId = vault.mint(address(token), STAKE_AMOUNT, DURATION);

        vm.prank(rewarder);
        vault.depositRewards(address(token), DURATION, REWARD_AMOUNT);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        vault.withdraw(nftId);

        assertEq(token.balanceOf(user), balanceBefore + STAKE_AMOUNT + REWARD_AMOUNT);
    }

    function test_withdraw_reverts_ifNotMatured() public {
        vm.prank(user);
        uint256 nftId = vault.mint(address(token), STAKE_AMOUNT, DURATION);

        vm.prank(user);
        vm.expectRevert(IBoostedYield.ImmaturePosition.selector);
        vault.withdraw(nftId);
    }
}
