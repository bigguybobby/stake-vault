// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StakeVault.sol";

contract MockERC20 {
    string public name;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name) { name = _name; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "no allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakeVaultTest is Test {
    StakeVault vault;
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 COOLDOWN = 1 days;

    function setUp() public {
        stakeToken = new MockERC20("STAKE");
        rewardToken = new MockERC20("REWARD");
        vault = new StakeVault(address(stakeToken), address(rewardToken), COOLDOWN);

        // Give users stake tokens
        stakeToken.mint(alice, 1000e18);
        stakeToken.mint(bob, 500e18);
        vm.prank(alice);
        stakeToken.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        stakeToken.approve(address(vault), type(uint256).max);

        // Give owner reward tokens for distribution
        rewardToken.mint(address(this), 10000e18);
        rewardToken.approve(address(vault), type(uint256).max);
    }

    // ─── Constructor ─────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(vault.stakingToken()), address(stakeToken));
        assertEq(address(vault.rewardToken()), address(rewardToken));
        assertEq(vault.cooldownPeriod(), COOLDOWN);
        assertEq(vault.owner(), address(this));
    }

    function test_constructor_zeroStaking() public {
        vm.expectRevert("zero staking token");
        new StakeVault(address(0), address(rewardToken), COOLDOWN);
    }

    function test_constructor_zeroReward() public {
        vm.expectRevert("zero reward token");
        new StakeVault(address(stakeToken), address(0), COOLDOWN);
    }

    // ─── Stake ───────────────────────────────────────────────────────

    function test_stake() public {
        vm.prank(alice);
        vault.stake(100e18);
        assertEq(vault.staked(alice), 100e18);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(stakeToken.balanceOf(address(vault)), 100e18);
    }

    function test_stake_zero() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        vault.stake(0);
    }

    function test_stake_multiple() public {
        vm.startPrank(alice);
        vault.stake(100e18);
        vault.stake(200e18);
        vm.stopPrank();
        assertEq(vault.staked(alice), 300e18);
        assertEq(vault.totalStaked(), 300e18);
    }

    function test_stake_multipleUsers() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(bob);
        vault.stake(50e18);
        assertEq(vault.totalStaked(), 150e18);
    }

    // ─── Request Unstake ─────────────────────────────────────────────

    function test_requestUnstake() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vault.requestUnstake(50e18);

        assertEq(vault.unstakeRequestAmount(alice), 50e18);
        assertTrue(vault.unstakeRequestTime(alice) > 0);
    }

    function test_requestUnstake_zero() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        vault.requestUnstake(0);
    }

    function test_requestUnstake_insufficientStake() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vm.expectRevert("insufficient stake");
        vault.requestUnstake(200e18);
    }

    // ─── Withdraw ────────────────────────────────────────────────────

    function test_withdraw() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vault.requestUnstake(100e18);

        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(alice);
        vault.withdraw();

        assertEq(vault.staked(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(stakeToken.balanceOf(alice), 1000e18); // got it all back
    }

    function test_withdraw_noRequest() public {
        vm.prank(alice);
        vm.expectRevert("no request");
        vault.withdraw();
    }

    function test_withdraw_cooldownActive() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.requestUnstake(100e18);

        vm.warp(block.timestamp + COOLDOWN - 1);

        vm.prank(alice);
        vm.expectRevert("cooldown active");
        vault.withdraw();
    }

    function test_withdraw_partial() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.requestUnstake(60e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        vault.withdraw();

        assertEq(vault.staked(alice), 40e18);
        assertEq(vault.totalStaked(), 40e18);
    }

    // ─── Rewards ─────────────────────────────────────────────────────

    function test_addReward() public {
        vault.addReward(1000e18, 10 days);
        assertEq(vault.rewardRate(), uint256(1000e18) / uint256(10 days));
        assertEq(vault.periodFinish(), block.timestamp + 10 days);
    }

    function test_addReward_zeroAmount() public {
        vm.expectRevert("zero amount");
        vault.addReward(0, 10 days);
    }

    function test_addReward_zeroDuration() public {
        vm.expectRevert("zero duration");
        vault.addReward(1000e18, 0);
    }

    function test_addReward_notOwner() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        vault.addReward(1000e18, 10 days);
    }

    function test_addReward_extend() public {
        vault.addReward(1000e18, 10 days);
        vm.warp(block.timestamp + 5 days);
        // Add more reward mid-period
        vault.addReward(500e18, 10 days);
        assertTrue(vault.rewardRate() > 0);
    }

    function test_earnRewards() public {
        vm.prank(alice);
        vault.stake(100e18);

        vault.addReward(1000e18, 10 days);

        vm.warp(block.timestamp + 5 days);

        uint256 earned = vault.earned(alice);
        // ~500e18 after 5 days of 1000e18 over 10 days
        assertGt(earned, 490e18);
        assertLt(earned, 510e18);
    }

    function test_earnRewards_proportional() public {
        vm.prank(alice);
        vault.stake(100e18); // 2/3
        vm.prank(bob);
        vault.stake(50e18);  // 1/3

        vault.addReward(1500e18, 10 days);
        vm.warp(block.timestamp + 10 days);

        uint256 aliceEarned = vault.earned(alice);
        uint256 bobEarned = vault.earned(bob);

        // Alice should get ~1000, Bob ~500
        assertGt(aliceEarned, 990e18);
        assertLt(aliceEarned, 1010e18);
        assertGt(bobEarned, 490e18);
        assertLt(bobEarned, 510e18);
    }

    function test_claimReward() public {
        vm.prank(alice);
        vault.stake(100e18);

        vault.addReward(1000e18, 10 days);
        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        vault.claimReward();

        assertGt(rewardToken.balanceOf(alice), 990e18);
        assertEq(vault.rewards(alice), 0);
    }

    function test_claimReward_noReward() public {
        vm.prank(alice);
        vm.expectRevert("no reward");
        vault.claimReward();
    }

    // ─── View: rewardPerToken, lastTimeRewardApplicable ──────────────

    function test_rewardPerToken_noStake() public {
        vault.addReward(1000e18, 10 days);
        vm.warp(block.timestamp + 5 days);
        // No one staked — should return stored value (0)
        assertEq(vault.rewardPerToken(), 0);
    }

    function test_lastTimeRewardApplicable_beforeFinish() public {
        vault.addReward(1000e18, 10 days);
        vm.warp(block.timestamp + 5 days);
        assertEq(vault.lastTimeRewardApplicable(), block.timestamp);
    }

    function test_lastTimeRewardApplicable_afterFinish() public {
        vault.addReward(1000e18, 10 days);
        uint256 finish = vault.periodFinish();
        vm.warp(finish + 100);
        assertEq(vault.lastTimeRewardApplicable(), finish);
    }

    // ─── getStakeInfo ────────────────────────────────────────────────

    function test_getStakeInfo() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.requestUnstake(50e18);

        (uint256 stakedAmt, uint256 earnedAmt, uint256 reqAmt, uint256 reqTime, bool canW) = vault.getStakeInfo(alice);
        assertEq(stakedAmt, 100e18);
        assertEq(earnedAmt, 0);
        assertEq(reqAmt, 50e18);
        assertTrue(reqTime > 0);
        assertFalse(canW);

        vm.warp(block.timestamp + COOLDOWN);
        (,,,, bool canW2) = vault.getStakeInfo(alice);
        assertTrue(canW2);
    }

    // ─── Admin ───────────────────────────────────────────────────────

    function test_setCooldown() public {
        vault.setCooldown(7 days);
        assertEq(vault.cooldownPeriod(), 7 days);
    }

    function test_setCooldown_notOwner() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        vault.setCooldown(7 days);
    }

    function test_transferOwnership() public {
        vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);
    }

    function test_transferOwnership_notOwner() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        vault.transferOwnership(bob);
    }

    function test_transferOwnership_zero() public {
        vm.expectRevert("zero address");
        vault.transferOwnership(address(0));
    }

    // ─── Edge cases ──────────────────────────────────────────────────

    function test_stakeAfterRewardStarted() public {
        vault.addReward(1000e18, 10 days);
        vm.warp(block.timestamp + 5 days);

        vm.prank(alice);
        vault.stake(100e18);

        vm.warp(block.timestamp + 5 days);

        uint256 earned = vault.earned(alice);
        // Only earns for last 5 days = ~500e18
        assertGt(earned, 490e18);
        assertLt(earned, 510e18);
    }

    function test_withdrawClearsRequest() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.requestUnstake(100e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        vault.withdraw();

        assertEq(vault.unstakeRequestAmount(alice), 0);
        assertEq(vault.unstakeRequestTime(alice), 0);
    }

    function test_zeroCooldown() public {
        StakeVault v2 = new StakeVault(address(stakeToken), address(rewardToken), 0);
        vm.prank(alice);
        stakeToken.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.stake(100e18);
        vm.prank(alice);
        v2.requestUnstake(100e18);
        // Can withdraw immediately with 0 cooldown
        vm.prank(alice);
        v2.withdraw();
        assertEq(v2.staked(alice), 0);
    }
}
