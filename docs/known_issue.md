# Known Issues

## Resolved Issues

### ~~Unrestricted Mint Function in StableCoin~~ (FIXED)
**Status:** Fixed in commit [current]

The contract StableCoin.sol previously allowed any address to call the `mint` function, not just the owner. This allowed any address to mint tokens to any other address, which was a critical security issue.

**Fix Applied:**
- Added `Ownable` inheritance to `StableCoin` contract
- Added `onlyOwner` modifier to the `mint` function

```solidity
function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
    emit TokensMinted(to, amount);
}
```

## Security Improvements Summary

The following security improvements have been implemented across the protocol:

### LiquidityPool.sol
1. **Reentrancy Protection**: Added `ReentrancyGuard` and `nonReentrant` modifiers to state-changing functions
2. **Checks-Effects-Interactions Pattern**: Reordered operations in `withdraw()` and `claimReward()` to update state before external calls
3. **Internal Accounting**: Added `totalPoolDeposits` to track deposits internally and prevent inflation attacks
4. **Pool-Only Burn**: Added `poolOnlyBurn()` function to `PoolShare` to allow burning without requiring user approval
5. **Signature Security**: Updated `claimReward()` to bind signatures to recipient and domain (chainId + contract address)
6. **Stray ETH Protection**: First deposit now requires an empty pool to prevent donation attacks

### StableCoin.sol & TokenStreamer
1. **Access Control**: Added `onlyOwner` to `StableCoin.mint()`
2. **Reentrancy Guards**: Added to `TokenStreamer` functions (`createStream`, `addToStream`, `withdrawFromStream`)
3. **CEI Pattern**: Applied checks-effects-interactions in all TokenStreamer functions

### GovernanceToken.sol (GroupStaking)
1. **Group Size Limit**: Added `MAX_GROUP_SIZE` constant (50 members) to prevent gas limit issues
2. **Remainder Handling**: `withdrawFromGroup()` now properly handles rounding remainders by sending to group owner

