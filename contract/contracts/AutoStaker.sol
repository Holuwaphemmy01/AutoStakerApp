pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// AutoStaker: Simple staking contract with auto-compounding
contract AutoStaker is ReentrancyGuard {
    IERC20 public stakingToken; // ERC20 token to stake
    uint256 public constant REWARD_RATE = 1e16; // 1% per hour (scaled for precision)
    uint256 public constant REWARD_THRESHOLD = 1e18; // 1 token threshold for compounding
    uint256 public totalStaked;
    
    struct UserInfo {
        uint256 stakedAmount;
        uint256 rewardDebt; // Tracks rewards at last compound
        uint256 lastUpdate; // Timestamp of last compound or stake
    }
    
    mapping(address => UserInfo) public userInfo;
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Compounded(address indexed user, uint256 reward);
    event RewardThresholdReached(address indexed user, uint256 reward);

    constructor(address _stakingToken) {
        stakingToken = IERC20(_stakingToken);
    }

    // Calculate pending rewards for a user
    function pendingRewards(address _user) public view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        if (user.stakedAmount == 0) return 0;
        uint256 timeElapsed = block.timestamp - user.lastUpdate;
        return (user.stakedAmount * REWARD_RATE * timeElapsed) / 1e18;
    }

    // Stake tokens
    function stake(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        UserInfo storage user = userInfo[msg.sender];
        
        // Update rewards before changing stake
        uint256 pending = pendingRewards(msg.sender);
        if (pending > 0) {
            user.rewardDebt += pending;
        }
        
        stakingToken.transferFrom(msg.sender, address(this), _amount);
        user.stakedAmount += _amount;
        user.lastUpdate = block.timestamp;
        totalStaked += _amount;
        
        emit Staked(msg.sender, _amount);
    }

    // Unstake tokens
    function unstake(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount >= _amount, "Insufficient staked amount");
        
        // Update rewards before unstaking
        uint256 pending = pendingRewards(msg.sender);
        if (pending > 0) {
            user.rewardDebt += pending;
        }
        
        user.stakedAmount -= _amount;
        totalStaked -= _amount;
        user.lastUpdate = block.timestamp;
        stakingToken.transfer(msg.sender, _amount);
        
        emit Unstaked(msg.sender, _amount);
    }

    // Compound rewards (permissionless, called by Kwala)
    function compound(address _user) external nonReentrant {
        UserInfo storage user = userInfo[_user];
        uint256 pending = pendingRewards(_user);
        require(pending > 0, "No rewards to compound");
        
        if (pending >= REWARD_THRESHOLD) {
            emit RewardThresholdReached(_user, pending);
        }
        
        user.stakedAmount += pending;
        totalStaked += pending;
        user.rewardDebt = 0;
        user.lastUpdate = block.timestamp;
        
        emit Compounded(_user, pending);
    }

    // Get user balance and rewards
    function getUserInfo(address _user) external view returns (uint256 staked, uint256 rewards) {
        return (userInfo[_user].stakedAmount, pendingRewards(_user));
    }
}