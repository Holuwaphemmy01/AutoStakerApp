// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AutoStaker is Ownable {
    IERC20 public stakingToken;

    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        bool active;
    }

    mapping(address => StakeInfo) public stakes;
    mapping(address => uint256) public rewards;

    uint256 public rewardRate; // tokens per second per staked token
    uint256 public minStakeTime = 30; // seconds (for testing, adjust later)
    uint256 public totalStaked;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event RewardRateUpdated(uint256 newRate);

    constructor(address _token, uint256 _rewardRate) Ownable(msg.sender) {
        stakingToken = IERC20(_token);
        rewardRate = _rewardRate;
    }

    function stake(uint256 _amount) external {
        require(_amount > 0, "Cannot stake zero tokens");
        require(!stakes[msg.sender].active, "Already staking");

        stakingToken.transferFrom(msg.sender, address(this), _amount);

        stakes[msg.sender] = StakeInfo({
            amount: _amount,
            startTime: block.timestamp,
            active: true
        });

        totalStaked += _amount;
        emit Staked(msg.sender, _amount);
    }

    function calculateReward(address _user) public view returns (uint256) {
        StakeInfo memory info = stakes[_user];
        if (!info.active) return 0;
        uint256 duration = block.timestamp - info.startTime;
        return info.amount * rewardRate * duration;
    }

    function unstake() external {
        StakeInfo storage info = stakes[msg.sender];
        require(info.active, "No active stake");
        require(block.timestamp >= info.startTime + minStakeTime, "Stake time not met");

        uint256 reward = calculateReward(msg.sender);
        uint256 amount = info.amount;

        rewards[msg.sender] += reward;
        info.active = false;
        totalStaked -= amount;

        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, reward);
    }

    function updateRewardRate(uint256 _newRate) external onlyOwner {
        rewardRate = _newRate;
        emit RewardRateUpdated(_newRate);
    }

    function getStakeInfo(address _user) external view returns (StakeInfo memory) {
        return stakes[_user];
    }
}
