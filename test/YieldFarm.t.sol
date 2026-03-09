// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/YieldFarm.sol";

contract YieldFarmTest is Test {
    YieldFarm public farm;
    RewardToken public rewardToken;
    address public owner;
    address public user1;
    address public user2;
    address public user3;

    // 1 token per second, 7 day bonus period
    uint256 constant REWARD_PER_SECOND = 1e18;
    uint256 constant BONUS_DURATION = 7 days;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        farm = new YieldFarm(REWARD_PER_SECOND, BONUS_DURATION);
        rewardToken = farm.rewardToken();

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
    }

    function testInitialState() public {
        assertEq(farm.owner(), owner);
        assertEq(farm.rewardPerSecond(), REWARD_PER_SECOND);
        assertEq(farm.totalStaked(), 0);
        assertEq(farm.bonusMultiplier(), 2);
        assertEq(
            farm.bonusEndTime(), block.timestamp + BONUS_DURATION
        );
    }

    function testStake() public {
        uint256 stakeAmount = 10 ether;

        vm.prank(user1);
        farm.stake{value: stakeAmount}();

        (uint256 stakedAmount,,, uint256 lastStakeTime) =
            farm.userInfo(user1);
        assertEq(stakedAmount, stakeAmount);
        assertEq(lastStakeTime, block.timestamp);
        assertEq(farm.totalStaked(), stakeAmount);
        assertEq(address(farm).balance, stakeAmount);
    }

    function testMultipleStakes() public {
        vm.prank(user1);
        farm.stake{value: 5 ether}();

        vm.prank(user2);
        farm.stake{value: 10 ether}();

        assertEq(farm.totalStaked(), 15 ether);

        (uint256 user1Staked,,,) = farm.userInfo(user1);
        (uint256 user2Staked,,,) = farm.userInfo(user2);
        assertEq(user1Staked, 5 ether);
        assertEq(user2Staked, 10 ether);
    }

    function testUnstake() public {
        uint256 stakeAmount = 10 ether;

        vm.startPrank(user1);
        farm.stake{value: stakeAmount}();

        skip(100);

        uint256 balanceBefore = user1.balance;
        farm.unstake(5 ether);
        vm.stopPrank();

        assertEq(user1.balance, balanceBefore + 5 ether);
        assertEq(farm.totalStaked(), 5 ether);

        (uint256 stakedAmount,,,) = farm.userInfo(user1);
        assertEq(stakedAmount, 5 ether);
    }

    function testHarvest() public {
        vm.prank(user1);
        farm.stake{value: 10 ether}();

        // Skip 100 seconds during bonus period (2x multiplier)
        skip(100);

        vm.prank(user1);
        farm.harvest();

        // 100 seconds * 1e18 per second * 2x bonus = 200e18 rewards
        assertEq(rewardToken.balanceOf(user1), 200e18);
    }

    function testPendingReward() public {
        vm.prank(user1);
        farm.stake{value: 10 ether}();

        skip(50);

        uint256 pending = farm.pendingReward(user1);
        // 50 seconds * 1e18 * 2x bonus = 100e18
        assertEq(pending, 100e18);
    }

    function testEmergencyWithdraw() public {
        vm.startPrank(user1);
        farm.stake{value: 10 ether}();

        skip(100);

        uint256 balanceBefore = user1.balance;
        farm.emergencyWithdraw();
        vm.stopPrank();

        assertEq(user1.balance, balanceBefore + 10 ether);
        assertEq(farm.totalStaked(), 0);
        assertEq(rewardToken.balanceOf(user1), 0); // Rewards forfeited

        (uint256 stakedAmount, uint256 rewardDebt, uint256 pending,) =
            farm.userInfo(user1);
        assertEq(stakedAmount, 0);
        assertEq(rewardDebt, 0);
        assertEq(pending, 0);
    }

    function testProportionalRewards() public {
        // User1 stakes 10 ETH
        vm.prank(user1);
        farm.stake{value: 10 ether}();

        skip(50);

        // User2 stakes 10 ETH (equal share)
        vm.prank(user2);
        farm.stake{value: 10 ether}();

        skip(50);

        // User1 had 100% for 50s, then 50% for 50s
        // Bonus period: 50s * 2 * 1e18 + 50s * 2 * 1e18 / 2 = 100e18 + 50e18 = 150e18
        uint256 pendingUser1 = farm.pendingReward(user1);
        // User2 had 50% for 50s
        // Bonus period: 50s * 2 * 1e18 / 2 = 50e18
        uint256 pendingUser2 = farm.pendingReward(user2);

        assertEq(pendingUser1, 150e18);
        assertEq(pendingUser2, 50e18);
    }

    function testBonusMultiplierTransition() public {
        vm.prank(user1);
        farm.stake{value: 10 ether}();

        // Skip past the bonus period
        skip(BONUS_DURATION + 100);

        uint256 pending = farm.pendingReward(user1);
        // Bonus period: 7 days * 2 * 1e18 = 1_209_600e18
        // Post-bonus: 100s * 1 * 1e18 = 100e18
        // Total = 1_209_700e18
        assertEq(pending, 1_209_700e18);
    }

    function testSetRewardRate() public {
        vm.prank(user1);
        farm.stake{value: 10 ether}();

        skip(50);

        // Change reward rate
        farm.setRewardRate(2e18);

        skip(50);

        uint256 pending = farm.pendingReward(user1);
        // First 50s: 50 * 2 * 1e18 = 100e18 (bonus)
        // Next 50s: 50 * 2 * 2e18 = 200e18 (bonus + new rate)
        assertEq(pending, 300e18);
    }

    function testSetHarvestDelegate() public {
        vm.prank(user1);
        farm.setHarvestDelegate(user2);

        assertEq(farm.harvestDelegates(user1), user2);
    }

    function testMigrateStake() public {
        address newFarm = makeAddr("newFarm");

        vm.startPrank(user1);
        farm.stake{value: 10 ether}();

        farm.migrateStake(newFarm);
        vm.stopPrank();

        (uint256 stakedAmount,,,) = farm.userInfo(user1);
        assertEq(stakedAmount, 0);
        assertEq(farm.totalStaked(), 0);
        assertEq(newFarm.balance, 10 ether);
    }

    function test_RevertWhen_StakeZero() public {
        vm.prank(user1);
        vm.expectRevert("Cannot stake zero");
        farm.stake{value: 0}();
    }

    function test_RevertWhen_UnstakeInsufficient() public {
        vm.startPrank(user1);
        farm.stake{value: 5 ether}();

        vm.expectRevert("Insufficient stake");
        farm.unstake(10 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_EmergencyWithdrawNoStake() public {
        vm.prank(user1);
        vm.expectRevert("Nothing to withdraw");
        farm.emergencyWithdraw();
    }

    function test_RevertWhen_HarvestNoRewards() public {
        vm.prank(user1);
        vm.expectRevert("No rewards to harvest");
        farm.harvest();
    }

    receive() external payable {}
}
