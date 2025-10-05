// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * AutoStaker.sol
 *
 * Minimal hackathon-ready auto-compounder:
 * - Users stake an ERC20 token
 * - Rewards accrue linearly: pending = stake * rewardRate * timeDelta
 * - Owner deposits reward tokens into contract reward pool
 * - Anyone (Kwala) can call compoundFor(address) or compoundBatch(start, count)
 *   to compound rewards into user stakes (permissionless)
 *
 * Simplifications for speed:
 * - Single-token rewards (same token as staked)
 * - rewardRate is scaled by 1e18 (tokens per token per second)
 * - Stakers list is appended on first stake; entries are not removed for speed
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AutoStaker is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;

    // rewardRate: scaled by 1e18. Example:
    // rewardRate = 1e18 * annualRate / (365*24*3600)
    // pendingReward = stake * rewardRate * delta / 1e18
    uint256 public rewardRate; // per token per second (scaled by 1e18)

    // reward pool (tokens available to pay out rewards)
    uint256 public rewardPool;

    // user state
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lastUpdate; // last timestamp we updated user accrual

    // stakers array to allow batch processing
    address[] public stakers;
    mapping(address => bool) private _isStaker;

    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 rewardPaid);
    event Compounded(address indexed user, uint256 rewardAmount);
    event AutoCompoundBatch(uint256 indexed timestamp, uint256 startIndex, uint256 count);
    event RewardPoolDeposited(address indexed from, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    constructor(address _stakingToken, uint256 _rewardRate) {
        require(_stakingToken != address(0), "zero token");
        stakingToken = IERC20(_stakingToken);
        rewardRate = _rewardRate;
    }

    // ---------- User actions ----------

    /// @notice Stake `amount` tokens
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        // update pending reward into accounting
        _updateReward(msg.sender);

        // transfer staking token
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        // increase user stake
        balanceOf[msg.sender] += amount;

        // mark staker
        if (!_isStaker[msg.sender]) {
            _isStaker[msg.sender] = true;
            stakers.push(msg.sender);
        }

        emit Staked(msg.sender, amount);
    }

    /// @notice Unstake `amount` tokens and claim pending reward (if available)
    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        require(balanceOf[msg.sender] >= amount, "insufficient stake");

        // update and compute pending
        _updateReward(msg.sender);
        uint256 pending = _pendingReward(msg.sender);

        // decrease stake
        balanceOf[msg.sender] -= amount;

        // pay out reward if available
        uint256 paidReward = 0;
        if (pending > 0) {
            // If rewardPool doesn't have enough, pay what's available
            if (rewardPool >= pending) {
                paidReward = pending;
            } else {
                paidReward = rewardPool;
            }
            if (paidReward > 0) {
                rewardPool -= paidReward;
                stakingToken.safeTransfer(msg.sender, paidReward);
            }
        }

        // transfer unstaked tokens
        stakingToken.safeTransfer(msg.sender, amount);

        // reset lastUpdate to now
        lastUpdate[msg.sender] = block.timestamp;

        emit Unstaked(msg.sender, amount, paidReward);
    }

    // ---------- Compounding (permissionless) ----------

    /// @notice Compound pending reward for a single user (permissionless)
    /// Anyone (Kwala) can call this to compound a user's pending reward into their stake.
    function compoundFor(address user) public nonReentrant {
        require(user != address(0), "zero user");
        _updateReward(user);
        uint256 pending = _pendingReward(user);
        if (pending == 0) return;

        // cap by rewardPool
        uint256 toCompound = pending;
        if (rewardPool < toCompound) {
            toCompound = rewardPool;
        }
        if (toCompound == 0) return;

        // pay reward by increasing user's stake (auto-compound)
        rewardPool -= toCompound;
        balanceOf[user] += toCompound;

        // reset lastUpdate
        lastUpdate[user] = block.timestamp;

        emit Compounded(user, toCompound);
    }

    /// @notice Compound rewards for a batch of stakers (gas-bounded). Use start index + count.
    /// Designed for Kwala to execute batch compounding when gas is favorable.
    function compoundBatch(uint256 startIndex, uint256 count) external nonReentrant {
        uint256 len = stakers.length;
        if (startIndex >= len || count == 0) {
            emit AutoCompoundBatch(block.timestamp, startIndex, 0);
            return;
        }

        uint256 end = startIndex + count;
        if (end > len) end = len;

        for (uint256 i = startIndex; i < end; ++i) {
            address user = stakers[i];
            // skip zero-balance entries (staker array may contain inactive addresses)
            if (balanceOf[user] == 0) {
                lastUpdate[user] = block.timestamp; // keep lastUpdate fresh
                continue;
            }
            // attempt to compound each user; stop early if rewardPool depleted
            if (rewardPool == 0) break;
            _updateReward(user);
            uint256 pending = _pendingReward(user);
            if (pending == 0) {
                lastUpdate[user] = block.timestamp;
                continue;
            }
            uint256 toCompound = pending;
            if (rewardPool < toCompound) toCompound = rewardPool;
            if (toCompound == 0) break;
            rewardPool -= toCompound;
            balanceOf[user] += toCompound;
            lastUpdate[user] = block.timestamp;
            emit Compounded(user, toCompound);
        }

        emit AutoCompoundBatch(block.timestamp, startIndex, end - startIndex);
    }

    // ---------- Views & internals ----------

    /// @notice Calculate pending reward for a user (not state-changing)
    function pendingReward(address user) external view returns (uint256) {
        return _pendingRewardView(user);
    }

    function _pendingRewardView(address user) internal view returns (uint256) {
        uint256 bal = balanceOf[user];
        if (bal == 0) return 0;
        uint256 last = lastUpdate[user];
        if (last == 0) last = block.timestamp; // if never staked, no accrual
        uint256 delta = block.timestamp - last;
        // reward = bal * rewardRate * delta / 1e18
        uint256 reward = (bal * rewardRate * delta) / 1e18;
        return reward;
    }

    /// @dev internal variant used after state update
    function _pendingReward(address user) internal view returns (uint256) {
        return _pendingRewardView(user);
    }

    /// @dev update user's lastUpdate to account for elapsed time (called at start of user actions)
    function _updateReward(address user) internal {
        // This function intentionally does not write the reward into a rewards mapping
        // because compounding will either convert pending -> stake or unstake will pay out.
        // We simply refresh lastUpdate so pending is computed relative to now next time.
        if (lastUpdate[user] == 0) {
            // First interaction, set lastUpdate
            lastUpdate[user] = block.timestamp;
        }
        // else: do nothing here — caller will compute pending separately and update lastUpdate after operations
    }

    // ---------- Owner functions for demo / hackathon ----------

    /// @notice Fund the contract reward pool with staking token (owner-only for demo)
    function depositRewardPool(uint256 amount) external onlyOwner {
        require(amount > 0, "zero amount");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPool += amount;
        emit RewardPoolDeposited(msg.sender, amount);
    }

    /// @notice Owner can withdraw excess tokens (for demo cleanup). Only withdraws tokens not owed to stakers.
    function ownerWithdraw(uint256 amount) external onlyOwner {
        // Compute total staked to ensure owner doesn't withdraw staked tokens
        uint256 totalStaked = _totalStaked();
        uint256 contractBal = stakingToken.balanceOf(address(this));
        // safe withdrawable = contractBal - totalStaked - rewardPool (should be zero normally)
        require(contractBal >= totalStaked + rewardPool, "insufficient free balance");
        uint256 freeBalance = contractBal - totalStaked - rewardPool;
        require(amount <= freeBalance, "amount exceeds free balance");
        stakingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Set reward rate (owner-only, for testing/demos). rate scaled by 1e18.
    function setRewardRate(uint256 newRate) external onlyOwner {
        uint256 old = rewardRate;
        rewardRate = newRate;
        emit RewardRateUpdated(old, newRate);
    }

    // ---------- Helpers ----------

    function _totalStaked() internal view returns (uint256 total) {
        // NOTE: This loops through stakers array — ok for small demo sets.
        uint256 len = stakers.length;
        for (uint256 i = 0; i < len; ++i) {
            total += balanceOf[stakers[i]];
        }
    }

    // ---------- Getter convenience ----------

    function stakersCount() external view returns (uint256) {
        return stakers.length;
    }
}
