// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./StableCoin.sol";

/**
 * @title PoolShare
 * @dev ERC20 token representing ownership shares in the liquidity pool
 *
 * These tokens are minted when users deposit ETH and burned when they withdraw.
 * The supply directly correlates to the total liquidity provided to the protocol.
 */
contract PoolShare is ERC20Burnable, Ownable {
    constructor() ERC20("Liquidity Pool Share", "LPS") Ownable(msg.sender) {}

    /**
     * @dev Mints new pool share tokens
     * Only callable by the pool contract to maintain proper accounting
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Burns pool share tokens from a specific address without requiring allowance
     * Only callable by the pool contract to allow burning during withdrawal
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function poolOnlyBurn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

/**
 * @title LiquidityPool
 * @dev Core liquidity pool contract for the DeFiHub protocol
 *
 * Users can deposit ETH to earn rewards and receive proportional pool shares.
 * The pool implements a time-delay mechanism for withdrawals to ensure stability
 * and prevent flash loan attacks.
 */
contract LiquidityPool is Ownable, ReentrancyGuard {
    PoolShare public immutable shareToken;

    // User reward balances tracked separately for efficiency
    mapping(address => uint256) public rewards;
    // Nonces for signature verification to prevent replay attacks
    mapping(address => uint256) public nonces;
    // Timestamp tracking for withdrawal delay enforcement
    mapping(address => uint256) public lastDepositTime;

    // Internal accounting of total deposits to prevent inflation attacks
    uint256 public totalPoolDeposits;

    // Security delay for withdrawals (24 hours)
    uint256 public constant WITHDRAWAL_DELAY = 1 days;
    // Reward rate as percentage of deposit (10%)
    uint256 public constant REWARD_RATE = 10;

    // EIP-712 type hash for claim authorization
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(address user,address recipient,uint256 amount,uint256 nonce,uint256 chainId,address contractAddress)"
    );

    // Event declarations for comprehensive tracking
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdrawal(address indexed user, uint256 amount, uint256 shares);
    event RewardClaimed(address indexed user, uint256 amount);

    /**
     * @dev Initializes the liquidity pool and deploys the share token
     */
    constructor() Ownable(msg.sender) {
        shareToken = new PoolShare();
    }

    /**
     * @dev Allows users to deposit ETH and receive pool shares
     * Automatically calculates and allocates rewards based on deposit amount
     */
    function deposit() external payable {
        require(msg.value > 0, "Invalid deposit");
        _processDeposit(msg.sender, msg.value);
    }

    /**
     * @dev Allows deposits on behalf of other users
     * Useful for institutional integrations and third-party services
     * @param user The address that will receive the shares and rewards
     */
    function depositFor(address user) external payable {
        require(msg.value > 0, "Invalid deposit");
        _processDeposit(user, msg.value);
    }

    /**
     * @dev Withdraws ETH by burning pool shares
     * Enforces withdrawal delay for security against flash loan attacks
     * @param shares The number of pool shares to burn for withdrawal
     */
    function withdraw(uint256 shares) external nonReentrant {
        require(shares > 0, "Shares must be greater than 0");
        require(shareToken.balanceOf(msg.sender) >= shares, "Insufficient shares");

        // Enforce withdrawal delay for security
        require(
            block.timestamp >= lastDepositTime[msg.sender] + WITHDRAWAL_DELAY,
            "Withdrawal delay not met"
        );

        // Calculate ETH amount based on proportional share of pool using internal accounting
        // This prevents donation attacks that inflate the balance without minting shares
        uint256 amount = shares * totalPoolDeposits / shareToken.totalSupply();

        // Effects: Burn shares first (checks-effects-interactions pattern)
        shareToken.poolOnlyBurn(msg.sender, shares);

        // Update internal accounting
        totalPoolDeposits -= amount;

        // Interactions: Transfer ETH last
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        emit Withdrawal(msg.sender, amount, shares);
    }

    /**
     * @dev Claims accumulated rewards using cryptographic signature verification
     * This secure method prevents unauthorized claims while allowing flexibility
     * @param user The user claiming rewards (must match signature)
     * @param recipient The recipient address for the reward payout (bound to signature)
     * @param amount The amount of rewards to claim
     * @param nonce The current nonce for replay protection
     * @param signature Cryptographic signature proving authorization
     */
    function claimReward(
        address user,
        address recipient,
        uint256 amount,
        uint256 nonce,
        bytes memory signature
    ) external nonReentrant {
        require(rewards[user] >= amount, "Insufficient rewards");
        require(nonces[user] == nonce, "Invalid nonce");
        require(recipient != address(0), "Invalid recipient");

        // Verify cryptographic signature with domain binding to prevent replay attacks
        // Signature includes: user, recipient, amount, nonce, chainId, and contract address
        bytes32 messageHash = keccak256(
            abi.encode(
                CLAIM_TYPEHASH,
                user,
                recipient,
                amount,
                nonce,
                block.chainid,
                address(this)
            )
        );
        address signer = ECDSA.recover(messageHash, signature);
        require(signer == user, "Invalid signature");

        // Calculate protocol fee and user amount
        uint256 fee = amount / 10; // 10% protocol fee
        uint256 userAmount = amount - fee;

        // Effects: Update state before any external transfers (checks-effects-interactions)
        rewards[user] -= amount;
        nonces[user]++;

        // Emit event before external calls
        emit RewardClaimed(user, userAmount);

        // Interactions: Transfer protocol fee to treasury (must succeed)
        (bool feeSuccess,) = owner().call{value: fee}("");
        require(feeSuccess, "Fee transfer failed");

        // Interactions: Transfer remaining amount to the specified recipient (must succeed)
        (bool success,) = recipient.call{value: userAmount}("");
        require(success, "Reward transfer failed");
    }

    /**
     * @dev Internal function to handle deposit logic for any user
     * Calculates shares, mints tokens, and allocates rewards
     * Uses internal accounting to prevent donation/inflation attacks
     * @param user The address receiving shares and rewards
     * @param amount The ETH amount being deposited
     */
    function _processDeposit(address user, uint256 amount) internal {
        // Calculate shares based on internal accounting (not address(this).balance)
        uint256 shares;
        if (shareToken.totalSupply() == 0) {
            // First deposit: reject if there's already ETH in the pool (donation attack protection)
            require(
                totalPoolDeposits == 0,
                "Stray ETH detected: first deposit must be to empty pool"
            );
            // First deposit gets 1:1 share ratio
            shares = amount;
        } else {
            // Subsequent deposits get proportional shares based on internal accounting
            // Using totalPoolDeposits instead of address(this).balance prevents inflation attacks
            shares = (amount * shareToken.totalSupply()) / totalPoolDeposits;
        }

        // Update internal accounting before external calls
        totalPoolDeposits += amount;

        // Mint shares to the user
        shareToken.mint(user, shares);

        // Calculate and allocate rewards based on deposit amount
        uint256 rewardAmount = (amount * REWARD_RATE) / 100;
        rewards[user] += rewardAmount;

        // Update last deposit time for withdrawal delay calculation
        lastDepositTime[user] = block.timestamp;

        // Emit event for tracking deposits
        emit Deposit(user, amount, shares);
    }
}
