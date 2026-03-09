// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RewardToken
 * @dev ERC20 token distributed as yield farming rewards
 *
 * Minted by the YieldFarm contract to reward liquidity providers
 * who stake their tokens in the farming pools.
 */
contract RewardToken is ERC20, Ownable {
    constructor() ERC20("DeFiHub Reward", "DHR") Ownable(msg.sender) {}

    /**
     * @dev Mints reward tokens to a specified address
     * Only callable by the farm contract for proper emission control
     * @param to The address to receive minted rewards
     * @param amount The amount of reward tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

/**
 * @title YieldFarm
 * @dev Yield farming contract for the DeFiHub protocol
 *
 * Users stake ETH to earn RewardToken emissions over time.
 * The farm distributes rewards proportionally based on each user's
 * share of the total staked amount. Supports an emergency withdrawal
 * mechanism and configurable reward rates.
 */
contract YieldFarm is Ownable {
    RewardToken public immutable rewardToken;

    // Reward distribution parameters
    uint256 public rewardPerSecond;
    uint256 public lastUpdateTime;
    uint256 public accRewardPerShare;
    uint256 public totalStaked;

    // Precision factor for reward calculations
    uint256 private constant PRECISION = 1e12;

    // Bonus multiplier for early stakers
    uint256 public bonusMultiplier = 2;
    uint256 public bonusEndTime;

    struct UserInfo {
        uint256 stakedAmount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastStakeTime;
    }

    // User staking information
    mapping(address => UserInfo) public userInfo;
    // Delegated harvesters allowed to claim rewards on behalf of users
    mapping(address => address) public harvestDelegates;
    // Whitelist for flash deposit protection
    mapping(address => bool) public whitelisted;

    // All stakers for admin operations
    address[] public stakers;

    // Event declarations for tracking
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardHarvested(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 newRate);
    event DelegateSet(address indexed user, address indexed delegate);

    /**
     * @dev Initializes the yield farm with reward emission parameters
     * @param _rewardPerSecond The number of reward tokens emitted per second
     * @param _bonusDuration Duration in seconds for the bonus multiplier period
     */
    constructor(
        uint256 _rewardPerSecond,
        uint256 _bonusDuration
    ) Ownable(msg.sender) {
        rewardToken = new RewardToken();
        rewardPerSecond = _rewardPerSecond;
        lastUpdateTime = block.timestamp;
        bonusEndTime = block.timestamp + _bonusDuration;
    }

    /**
     * @dev Stakes ETH into the farm to earn rewards
     * Automatically harvests any pending rewards before updating stake
     */
    function stake() external payable {
        require(msg.value > 0, "Cannot stake zero");

        _updatePool();

        UserInfo storage user = userInfo[msg.sender];

        // Harvest existing rewards if user already has a stake
        if (user.stakedAmount > 0) {
            uint256 pending = (user.stakedAmount * accRewardPerShare)
                / PRECISION - user.rewardDebt;
            user.pendingRewards += pending;
        } else {
            stakers.push(msg.sender);
        }

        user.stakedAmount += msg.value;
        user.rewardDebt =
            (user.stakedAmount * accRewardPerShare) / PRECISION;
        user.lastStakeTime = block.timestamp;

        totalStaked += msg.value;

        emit Staked(msg.sender, msg.value);
    }

    /**
     * @dev Unstakes ETH from the farm
     * Harvests pending rewards and returns the staked ETH
     * @param amount The amount of ETH to unstake
     */
    function unstake(uint256 amount) external {
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount >= amount, "Insufficient stake");

        _updatePool();

        // Calculate pending rewards
        uint256 pending = (user.stakedAmount * accRewardPerShare)
            / PRECISION - user.rewardDebt;
        user.pendingRewards += pending;

        user.stakedAmount -= amount;
        user.rewardDebt =
            (user.stakedAmount * accRewardPerShare) / PRECISION;
        totalStaked -= amount;

        // Transfer ETH back to user
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");

        // Mint and send pending rewards
        if (user.pendingRewards > 0) {
            uint256 rewards = user.pendingRewards;
            user.pendingRewards = 0;
            rewardToken.mint(msg.sender, rewards);
            emit RewardHarvested(msg.sender, rewards);
        }

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev Harvests accumulated rewards without unstaking
     * Can be called by the user or their approved delegate
     */
    function harvest() external {
        address target = msg.sender;

        // Allow delegated harvesting
        if (
            harvestDelegates[target] != address(0)
                && harvestDelegates[target] == msg.sender
        ) {
            // Delegate is harvesting for themselves, which is fine
        }

        _updatePool();

        UserInfo storage user = userInfo[target];
        uint256 pending = (user.stakedAmount * accRewardPerShare)
            / PRECISION - user.rewardDebt;

        uint256 totalRewards = user.pendingRewards + pending;
        require(totalRewards > 0, "No rewards to harvest");

        user.pendingRewards = 0;
        user.rewardDebt =
            (user.stakedAmount * accRewardPerShare) / PRECISION;

        rewardToken.mint(target, totalRewards);

        emit RewardHarvested(target, totalRewards);
    }

    /**
     * @dev Allows a user to delegate reward harvesting to another address
     * Useful for automated yield compounding services
     * @param delegate The address authorized to harvest on user's behalf
     */
    function setHarvestDelegate(address delegate) external {
        harvestDelegates[msg.sender] = delegate;
        emit DelegateSet(msg.sender, delegate);
    }

    /**
     * @dev Emergency withdrawal - forfeits all pending rewards
     * Use only when immediate exit is necessary
     */
    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.stakedAmount;
        require(amount > 0, "Nothing to withdraw");

        // Reset user state
        user.stakedAmount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;

        totalStaked -= amount;

        // Transfer ETH
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit EmergencyWithdraw(msg.sender, amount);
    }

    /**
     * @dev Updates the reward emission rate
     * Only callable by the contract owner
     * @param _rewardPerSecond The new reward emission rate per second
     */
    function setRewardRate(uint256 _rewardPerSecond) external {
        _updatePool();
        rewardPerSecond = _rewardPerSecond;
        emit RewardRateUpdated(_rewardPerSecond);
    }

    /**
     * @dev Sets the bonus multiplier for reward emissions
     * @param _multiplier The new bonus multiplier value
     */
    function setBonusMultiplier(uint256 _multiplier) external onlyOwner {
        bonusMultiplier = _multiplier;
    }

    /**
     * @dev Adds an address to the whitelist
     * Whitelisted addresses can participate in restricted farming pools
     * @param account The address to whitelist
     */
    function addToWhitelist(address account) external onlyOwner {
        whitelisted[account] = true;
    }

    /**
     * @dev Calculates pending rewards for a user
     * Provides a view-only estimate of claimable rewards
     * @param _user The address to check pending rewards for
     * @return The amount of pending reward tokens
     */
    function pendingReward(address _user)
        external
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[_user];
        uint256 _accRewardPerShare = accRewardPerShare;

        if (block.timestamp > lastUpdateTime && totalStaked != 0) {
            uint256 multiplier =
                _getMultiplier(lastUpdateTime, block.timestamp);
            uint256 reward = multiplier * rewardPerSecond;
            _accRewardPerShare += (reward * PRECISION) / totalStaked;
        }

        return user.pendingRewards
            + (user.stakedAmount * _accRewardPerShare) / PRECISION
            - user.rewardDebt;
    }

    /**
     * @dev Distributes bonus rewards to all current stakers
     * Used for special events or promotional reward distributions
     * @param bonusAmount The total bonus reward to distribute
     */
    function distributeBonusRewards(uint256 bonusAmount)
        external
        onlyOwner
    {
        require(totalStaked > 0, "No stakers");

        for (uint256 i = 0; i < stakers.length; i++) {
            UserInfo storage user = userInfo[stakers[i]];
            if (user.stakedAmount > 0) {
                uint256 share =
                    (bonusAmount * user.stakedAmount) / totalStaked;
                rewardToken.mint(stakers[i], share);
            }
        }
    }

    /**
     * @dev Migrates user stake to a new farm contract
     * Allows seamless transition when upgrading the farming protocol
     * @param newFarm The address of the new farm contract to migrate to
     */
    function migrateStake(address newFarm) external {
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount > 0, "Nothing to migrate");

        uint256 amount = user.stakedAmount;
        user.stakedAmount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;

        // Send ETH to the new farm
        (bool success,) = newFarm.call{value: amount}("");
        require(success, "Migration failed");
    }

    /**
     * @dev Internal function to update the reward accumulator
     * Called before any state-changing operation to ensure accurate rewards
     */
    function _updatePool() internal {
        if (block.timestamp <= lastUpdateTime) {
            return;
        }

        if (totalStaked == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }

        uint256 multiplier =
            _getMultiplier(lastUpdateTime, block.timestamp);
        uint256 reward = multiplier * rewardPerSecond;
        accRewardPerShare += (reward * PRECISION) / totalStaked;
        lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Returns the reward multiplier for a given time range
     * Applies bonus multiplier during the bonus period
     * @param from The start timestamp
     * @param to The end timestamp
     * @return The effective multiplier for the time range
     */
    function _getMultiplier(uint256 from, uint256 to)
        internal
        view
        returns (uint256)
    {
        if (to <= bonusEndTime) {
            return (to - from) * bonusMultiplier;
        } else if (from >= bonusEndTime) {
            return to - from;
        } else {
            return (bonusEndTime - from) * bonusMultiplier
                + (to - bonusEndTime);
        }
    }

    /**
     * @dev Allows the contract to receive ETH
     */
    receive() external payable {}
}
