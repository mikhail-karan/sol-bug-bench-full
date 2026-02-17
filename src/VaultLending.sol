// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CollateralToken
 * @dev ERC20 token used as collateral in the VaultLending protocol
 *
 * This token represents a synthetic asset that users can deposit
 * as collateral to borrow ETH from the lending vault.
 */
contract CollateralToken is ERC20, Ownable {
    constructor() ERC20("DeFiHub Collateral", "DHC") Ownable(msg.sender) {}

    /**
     * @dev Mints new collateral tokens
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title VaultLending
 * @dev Lending vault where users deposit collateral to borrow ETH
 *
 * The protocol allows users to deposit CollateralToken as collateral,
 * then borrow ETH up to a percentage of their collateral value.
 * Interest accrues over time and must be repaid to avoid liquidation.
 */
contract VaultLending is Ownable {
    CollateralToken public immutable collateralToken;

    // Price of collateral token in ETH (scaled by 1e18)
    uint256 public collateralPrice;

    // Maximum loan-to-value ratio (75%)
    uint256 public constant MAX_LTV = 75;
    // Liquidation threshold (80%)
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    // Annual interest rate (5%)
    uint256 public constant ANNUAL_INTEREST_RATE = 5;

    struct Loan {
        uint256 collateralAmount;
        uint256 borrowedAmount;
        uint256 lastInterestUpdate;
        bool active;
    }

    // Active loans per user
    mapping(address => Loan) public loans;
    // Approved liquidators
    mapping(address => bool) public approvedLiquidators;
    // Protocol fee accumulator
    uint256 public accumulatedFees;
    // All borrowers for interest sweep
    address[] public borrowers;

    // Event declarations for tracking
    event CollateralDeposited(
        address indexed user, uint256 amount
    );
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 collateralSeized
    );
    event PriceUpdated(uint256 newPrice);

    /**
     * @dev Initializes the lending vault and deploys the collateral token
     * @param _initialPrice Initial price of collateral in ETH (1e18 scale)
     */
    constructor(uint256 _initialPrice) Ownable(msg.sender) {
        collateralToken = new CollateralToken();
        collateralPrice = _initialPrice;
    }

    /**
     * @dev Deposits collateral tokens into the vault
     * Users must approve this contract to transfer their tokens first
     * @param amount The amount of collateral tokens to deposit
     */
    function depositCollateral(uint256 amount) external {
        require(amount > 0, "Amount must be greater than zero");

        collateralToken.transferFrom(msg.sender, address(this), amount);

        if (!loans[msg.sender].active) {
            loans[msg.sender] = Loan({
                collateralAmount: amount,
                borrowedAmount: 0,
                lastInterestUpdate: block.timestamp,
                active: true
            });
            borrowers.push(msg.sender);
        } else {
            loans[msg.sender].collateralAmount += amount;
        }

        emit CollateralDeposited(msg.sender, amount);
    }

    /**
     * @dev Borrows ETH against deposited collateral
     * Enforces maximum loan-to-value ratio to maintain solvency
     * @param amount The amount of ETH to borrow
     */
    function borrow(uint256 amount) external {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active collateral");
        require(amount > 0, "Invalid borrow amount");

        // Calculate maximum borrowable amount based on collateral value
        uint256 collateralValue =
            (loan.collateralAmount * collateralPrice) / 1e18;
        uint256 maxBorrow = (collateralValue * MAX_LTV) / 100;
        require(
            loan.borrowedAmount + amount <= maxBorrow,
            "Exceeds max LTV"
        );

        // Transfer ETH to borrower
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");

        // Update loan state after transfer
        loan.borrowedAmount += amount;

        emit Borrowed(msg.sender, amount);
    }

    /**
     * @dev Repays borrowed ETH to reduce loan balance
     * Accepts partial or full repayment
     */
    function repay() external payable {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active loan");
        require(msg.value > 0, "Must repay something");

        // Apply accrued interest before repayment
        _accrueInterest(msg.sender);

        if (msg.value >= loan.borrowedAmount) {
            // Full repayment - return excess ETH
            uint256 excess = msg.value - loan.borrowedAmount;
            loan.borrowedAmount = 0;

            if (excess > 0) {
                payable(msg.sender).transfer(excess);
            }
        } else {
            loan.borrowedAmount -= msg.value;
        }

        emit Repaid(msg.sender, msg.value);
    }

    /**
     * @dev Withdraws collateral after loan is fully repaid
     * Only allows withdrawal when no outstanding debt remains
     * @param amount The amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) external {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active position");

        // Ensure sufficient collateral remains to cover any existing debt
        uint256 remainingCollateral = loan.collateralAmount - amount;
        if (loan.borrowedAmount > 0) {
            uint256 remainingValue =
                (remainingCollateral * collateralPrice) / 1e18;
            uint256 maxBorrow = (remainingValue * MAX_LTV) / 100;
            require(
                loan.borrowedAmount <= maxBorrow,
                "Would exceed max LTV"
            );
        }

        loan.collateralAmount -= amount;
        collateralToken.transfer(msg.sender, amount);

        // Close position if fully withdrawn
        if (loan.collateralAmount == 0 && loan.borrowedAmount == 0) {
            loan.active = false;
        }
    }

    /**
     * @dev Liquidates an undercollateralized position
     * The liquidator repays the borrower's debt and receives their collateral
     * at a discount as an incentive for maintaining protocol solvency
     * @param borrower The address of the undercollateralized borrower
     */
    function liquidate(address borrower) external payable {
        Loan storage loan = loans[borrower];
        require(loan.active, "No active loan");

        // Check if position is undercollateralized
        uint256 collateralValue =
            (loan.collateralAmount * collateralPrice) / 1e18;
        uint256 ltvRatio =
            (loan.borrowedAmount * 100) / collateralValue;
        require(
            ltvRatio > LIQUIDATION_THRESHOLD,
            "Position is healthy"
        );

        // Liquidator must repay the full debt
        require(
            msg.value >= loan.borrowedAmount,
            "Insufficient repayment"
        );

        uint256 debt = loan.borrowedAmount;
        uint256 collateralSeized = loan.collateralAmount;

        // Clear the loan
        loan.borrowedAmount = 0;
        loan.collateralAmount = 0;
        loan.active = false;

        // Transfer seized collateral to liquidator
        collateralToken.transfer(msg.sender, collateralSeized);

        // Return excess ETH to liquidator
        uint256 excess = msg.value - debt;
        if (excess > 0) {
            payable(msg.sender).transfer(excess);
        }

        emit Liquidated(borrower, msg.sender, collateralSeized);
    }

    /**
     * @dev Updates the collateral price feed
     * Used by the oracle system to keep prices current
     * @param newPrice The updated price of collateral in ETH
     */
    function updatePrice(uint256 newPrice) external {
        require(newPrice > 0, "Price must be positive");
        collateralPrice = newPrice;
        emit PriceUpdated(newPrice);
    }

    /**
     * @dev Sweeps accrued interest across all borrowers
     * Called periodically to ensure interest is up to date
     * This helps maintain accurate protocol accounting
     */
    function sweepInterest() external {
        for (uint256 i = 0; i < borrowers.length; i++) {
            _accrueInterest(borrowers[i]);
        }
    }

    /**
     * @dev Allows the owner to withdraw accumulated protocol fees
     * Sends all accumulated fees to the contract owner
     */
    function withdrawFees() external {
        require(
            tx.origin == owner(),
            "Only owner can withdraw fees"
        );

        uint256 fees = accumulatedFees;
        accumulatedFees = 0;

        (bool success,) = owner().call{value: fees}("");
        require(success, "Fee withdrawal failed");
    }

    /**
     * @dev Emergency function to rescue stuck tokens
     * Allows owner to recover any ERC20 tokens accidentally sent to the vault
     * @param token The address of the ERC20 token to rescue
     * @param to The address to send the rescued tokens to
     */
    function rescueTokens(address token, address to) external onlyOwner {
        uint256 balance = ERC20(token).balanceOf(address(this));
        ERC20(token).transfer(to, balance);
    }

    /**
     * @dev Internal function to accrue interest on a borrower's loan
     * Uses simple interest calculation based on time elapsed
     * @param borrower The address of the borrower
     */
    function _accrueInterest(address borrower) internal {
        Loan storage loan = loans[borrower];
        if (!loan.active || loan.borrowedAmount == 0) return;

        uint256 timeElapsed =
            block.timestamp - loan.lastInterestUpdate;
        uint256 interest = (loan.borrowedAmount
            * ANNUAL_INTEREST_RATE * timeElapsed)
            / (365 days) / 100;

        loan.borrowedAmount += interest;
        accumulatedFees += interest;
        loan.lastInterestUpdate = block.timestamp;
    }

    /**
     * @dev Allows the contract to receive ETH deposits for liquidity
     */
    receive() external payable {}
}
