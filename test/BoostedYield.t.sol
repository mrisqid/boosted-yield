// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BoostedYield} from "../src/BoostedYield.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BoostedYieldTest is Test {
    BoostedYield vault;
    MockERC20 token;

    address admin = address(0x1);
    address rewarder = address(0x2);
    address user = address(0x3);

    uint256 constant TOKEN_ID = 1;
    uint256 constant DURATION = 30 days;
    uint256 constant STAKE_AMOUNT = 1_000 ether;
    uint256 constant REWARD_AMOUNT = 500 ether;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.startPrank(admin);

        // 1️⃣ Deploy implementation (initializer disabled)
        BoostedYield impl = new BoostedYield();

        // 2️⃣ Encode initializer call
        bytes memory initData = abi.encodeCall(
            BoostedYield.initialize,
            (admin, rewarder)
        );

        // 3️⃣ Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            initData
        );

        // 4️⃣ Cast proxy as BoostedYield
        vault = BoostedYield(address(proxy));

        // 5️⃣ Deploy mock token
        token = new MockERC20();

        // 6️⃣ Configure token + duration
        vault.addToken(address(token), "MOCK");

        vault.updateDuration(
            TOKEN_ID,
            DURATION,
            true,
            true
        );

        vm.stopPrank();

        // Fund accounts
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

    function test_initialize_setsRoles() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.REWARDER_ROLE(), rewarder));
    }

    /*//////////////////////////////////////////////////////////////
                                MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_createsNFTAndStoresPosition() public {
        vm.prank(user);
        uint256 nftId = vault.mint(TOKEN_ID, STAKE_AMOUNT, DURATION);

        assertEq(vault.ownerOf(nftId), user);

        BoostedYield.Position memory pos = vault.getPosition(nftId);

        assertEq(pos.tokenId, TOKEN_ID);
        assertEq(pos.principal, STAKE_AMOUNT);
        assertEq(pos.duration, DURATION);
        assertGt(pos.startTime, 0);
        assertGt(pos.maturityTime, pos.startTime);
        assertEq(pos.tokensOwed, 0);

        assertEq(token.balanceOf(address(vault)), STAKE_AMOUNT);
    }

    function test_mint_reverts_ifAmountZero() public {
        vm.prank(user);
        vm.expectRevert("Invalid amount");
        vault.mint(TOKEN_ID, 0, DURATION);
    }

    /*//////////////////////////////////////////////////////////////
                            REWARDS
    //////////////////////////////////////////////////////////////*/

    function test_depositRewards_and_collect() public {
        vm.prank(user);
        uint256 nftId = vault.mint(TOKEN_ID, STAKE_AMOUNT, DURATION);

        vm.prank(rewarder);
        vault.depositRewards(TOKEN_ID, DURATION, REWARD_AMOUNT);

        vm.prank(user);
        uint256 collected = vault.collect(nftId);

        assertEq(collected, REWARD_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_afterMaturity() public {
        vm.prank(user);
        uint256 nftId = vault.mint(TOKEN_ID, STAKE_AMOUNT, DURATION);

        vm.prank(rewarder);
        vault.depositRewards(TOKEN_ID, DURATION, REWARD_AMOUNT);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        vault.withdraw(nftId);

        assertEq(
            token.balanceOf(user),
            balanceBefore + STAKE_AMOUNT + REWARD_AMOUNT
        );
    }
}
