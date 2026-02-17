// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/VaultLending.sol";

contract VaultLendingTest is Test {
    VaultLending public vault;
    CollateralToken public collateralToken;
    address public owner;
    address public user1;
    address public user2;
    address public liquidator;

    // Initial collateral price: 1 token = 0.01 ETH
    uint256 constant INITIAL_PRICE = 0.01 ether;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        liquidator = makeAddr("liquidator");

        // Deploy vault
        vault = new VaultLending(INITIAL_PRICE);
        collateralToken = vault.collateralToken();

        // Mint collateral tokens to users
        collateralToken.mint(user1, 10000e18);
        collateralToken.mint(user2, 10000e18);

        // Fund the vault with ETH for lending
        vm.deal(address(vault), 100 ether);

        // Fund users with ETH for gas and repayments
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(liquidator, 50 ether);
    }

    function testInitialState() public {
        assertEq(vault.owner(), owner);
        assertEq(vault.collateralPrice(), INITIAL_PRICE);
        assertEq(vault.MAX_LTV(), 75);
        assertEq(vault.LIQUIDATION_THRESHOLD(), 80);
        assertEq(vault.ANNUAL_INTEREST_RATE(), 5);
    }

    function testDepositCollateral() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vm.stopPrank();

        (uint256 collateral, uint256 borrowed,, bool active) =
            vault.loans(user1);
        assertEq(collateral, depositAmount);
        assertEq(borrowed, 0);
        assertTrue(active);
    }

    function testBorrow() public {
        uint256 depositAmount = 1000e18;
        // 1000 tokens * 0.01 ETH = 10 ETH collateral value
        // 75% LTV = 7.5 ETH max borrow
        uint256 borrowAmount = 5 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);

        uint256 balanceBefore = user1.balance;
        vault.borrow(borrowAmount);
        vm.stopPrank();

        assertEq(user1.balance, balanceBefore + borrowAmount);

        (, uint256 borrowed,,) = vault.loans(user1);
        assertEq(borrowed, borrowAmount);
    }

    function testRepay() public {
        uint256 depositAmount = 1000e18;
        uint256 borrowAmount = 5 ether;
        uint256 repayAmount = 2 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);

        vault.repay{value: repayAmount}();
        vm.stopPrank();

        (, uint256 borrowed,,) = vault.loans(user1);
        assertEq(borrowed, borrowAmount - repayAmount);
    }

    function testFullRepay() public {
        uint256 depositAmount = 1000e18;
        uint256 borrowAmount = 5 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);

        // Repay more than owed, should get excess back
        uint256 balanceBefore = user1.balance;
        vault.repay{value: 6 ether}();
        vm.stopPrank();

        (, uint256 borrowed,,) = vault.loans(user1);
        assertEq(borrowed, 0);
        // Should have received 1 ether back as excess
        assertEq(user1.balance, balanceBefore - 5 ether);
    }

    function testWithdrawCollateral() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.withdrawCollateral(withdrawAmount);
        vm.stopPrank();

        (uint256 collateral,,,) = vault.loans(user1);
        assertEq(collateral, depositAmount - withdrawAmount);
        assertEq(
            collateralToken.balanceOf(user1),
            10000e18 - depositAmount + withdrawAmount
        );
    }

    function testLiquidation() public {
        uint256 depositAmount = 1000e18;
        uint256 borrowAmount = 7 ether;

        // User deposits and borrows near max
        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();

        // Price drops making position undercollateralized
        // Original: 1000 tokens * 0.01 = 10 ETH collateral, 7 ETH debt = 70% LTV
        // New price: 0.008 ETH -> 1000 * 0.008 = 8 ETH collateral, 7 ETH debt = 87.5% LTV > 80%
        vault.updatePrice(0.008 ether);

        // Liquidator liquidates the position
        vm.prank(liquidator);
        vault.liquidate{value: 7 ether}(user1);

        (uint256 collateral, uint256 borrowed,, bool active) =
            vault.loans(user1);
        assertEq(collateral, 0);
        assertEq(borrowed, 0);
        assertFalse(active);

        // Liquidator received the collateral
        assertEq(collateralToken.balanceOf(liquidator), depositAmount);
    }

    function testInterestAccrual() public {
        uint256 depositAmount = 1000e18;
        uint256 borrowAmount = 5 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();

        // Skip 1 year
        skip(365 days);

        // Sweep interest
        vault.sweepInterest();

        (, uint256 borrowed,,) = vault.loans(user1);
        // Should have 5% interest: 5 ETH * 0.05 = 0.25 ETH
        assertEq(borrowed, borrowAmount + 0.25 ether);
    }

    function test_RevertWhen_BorrowExceedsLTV() public {
        uint256 depositAmount = 1000e18;
        // Max borrow = 7.5 ETH, try to borrow 8
        uint256 borrowAmount = 8 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);

        vm.expectRevert("Exceeds max LTV");
        vault.borrow(borrowAmount);
        vm.stopPrank();
    }

    function test_RevertWhen_ZeroDeposit() public {
        vm.prank(user1);
        vm.expectRevert("Amount must be greater than zero");
        vault.depositCollateral(0);
    }

    function test_RevertWhen_NoActiveCollateral() public {
        vm.prank(user1);
        vm.expectRevert("No active collateral");
        vault.borrow(1 ether);
    }

    function test_RevertWhen_LiquidateHealthyPosition() public {
        uint256 depositAmount = 1000e18;
        uint256 borrowAmount = 5 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert("Position is healthy");
        vault.liquidate{value: 5 ether}(user1);
    }

    receive() external payable {}
}
