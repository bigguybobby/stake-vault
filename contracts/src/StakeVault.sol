// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title StakeVault — ERC20 staking with proportional reward distribution
/// @notice Stake tokens, earn rewards per second. Uses reward-per-token-stored pattern.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract StakeVault {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    address public owner;

    // Reward state
    uint256 public rewardRate;        // tokens per second
    uint256 public rewardDuration;    // seconds
    uint256 public periodFinish;      // when current reward period ends
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    // Staking state
    uint256 public totalStaked;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // Cooldown
    uint256 public cooldownPeriod;
    mapping(address => uint256) public unstakeRequestTime;
    mapping(address => uint256) public unstakeRequestAmount;

    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount, uint256 duration);
    event CooldownUpdated(uint256 period);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(address _stakingToken, address _rewardToken, uint256 _cooldownPeriod) {
        require(_stakingToken != address(0), "zero staking token");
        require(_rewardToken != address(0), "zero reward token");
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        cooldownPeriod = _cooldownPeriod;
        owner = msg.sender;
    }

    function stake(uint256 _amount) external updateReward(msg.sender) {
        require(_amount > 0, "zero amount");
        totalStaked += _amount;
        staked[msg.sender] += _amount;
        require(stakingToken.transferFrom(msg.sender, address(this), _amount), "transfer failed");
        emit Staked(msg.sender, _amount);
    }

    function requestUnstake(uint256 _amount) external updateReward(msg.sender) {
        require(_amount > 0, "zero amount");
        require(staked[msg.sender] >= _amount, "insufficient stake");

        unstakeRequestTime[msg.sender] = block.timestamp;
        unstakeRequestAmount[msg.sender] = _amount;

        emit UnstakeRequested(msg.sender, _amount);
    }

    function withdraw() external updateReward(msg.sender) {
        uint256 amount = unstakeRequestAmount[msg.sender];
        require(amount > 0, "no request");
        require(block.timestamp >= unstakeRequestTime[msg.sender] + cooldownPeriod, "cooldown active");
        require(staked[msg.sender] >= amount, "insufficient stake");

        unstakeRequestAmount[msg.sender] = 0;
        unstakeRequestTime[msg.sender] = 0;
        totalStaked -= amount;
        staked[msg.sender] -= amount;

        require(stakingToken.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claimReward() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "no reward");
        rewards[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, reward), "transfer failed");
        emit RewardPaid(msg.sender, reward);
    }

    // ─── Reward Management ───────────────────────────────────────────

    function addReward(uint256 _amount, uint256 _duration) external onlyOwner updateReward(address(0)) {
        require(_amount > 0, "zero amount");
        require(_duration > 0, "zero duration");

        if (block.timestamp >= periodFinish) {
            rewardRate = _amount / _duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (_amount + leftover) / _duration;
        }

        require(rewardRate > 0, "rate too low");
        rewardDuration = _duration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + _duration;

        require(rewardToken.transferFrom(msg.sender, address(this), _amount), "transfer failed");
        emit RewardAdded(_amount, _duration);
    }

    function setCooldown(uint256 _period) external onlyOwner {
        cooldownPeriod = _period;
        emit CooldownUpdated(_period);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "zero address");
        emit OwnerTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // ─── View Functions ──────────────────────────────────────────────

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + 
            ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }

    function earned(address _account) public view returns (uint256) {
        return (staked[_account] * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e18 
            + rewards[_account];
    }

    function getStakeInfo(address _account) external view returns (
        uint256 stakedAmount,
        uint256 earnedAmount,
        uint256 requestAmount,
        uint256 requestTime,
        bool canWithdraw
    ) {
        stakedAmount = staked[_account];
        earnedAmount = earned(_account);
        requestAmount = unstakeRequestAmount[_account];
        requestTime = unstakeRequestTime[_account];
        canWithdraw = requestAmount > 0 && block.timestamp >= requestTime + cooldownPeriod;
    }
}
