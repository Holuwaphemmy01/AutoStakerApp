import { expect } from "chai";
import { ethers } from "hardhat";
import { AutoStaker, AutoStaker__factory, ERC20Mock, ERC20Mock__factory } from "../typechain-types";
import { Signer } from "ethers";

describe("AutoStaker Contract", function () {
  let owner: Signer;
  let user1: Signer;
  let user2: Signer;
  let token: ERC20Mock;
  let staker: AutoStaker;

  const initialSupply = ethers.parseEther("1000000");
  const rewardRate = ethers.parseEther("0.000001"); // reward per token per second

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy mock ERC20 token
    const TokenFactory = (await ethers.getContractFactory("ERC20Mock")) as ERC20Mock__factory;
    token = await TokenFactory.deploy("MockToken", "MTK", await owner.getAddress(), initialSupply);
    await token.waitForDeployment();

    // Deploy AutoStaker
    const StakerFactory = (await ethers.getContractFactory("AutoStaker")) as AutoStaker__factory;
    staker = await StakerFactory.deploy(await token.getAddress(), rewardRate);
    await staker.waitForDeployment();

    // Transfer tokens to users
    await token.transfer(await user1.getAddress(), ethers.parseEther("1000"));
    await token.transfer(await user2.getAddress(), ethers.parseEther("1000"));

    // Approve staking contract
    await token.connect(user1).approve(await staker.getAddress(), ethers.parseEther("1000"));
    await token.connect(user2).approve(await staker.getAddress(), ethers.parseEther("1000"));
  });

  it("should deploy with correct initial parameters", async function () {
    expect(await staker.rewardRate()).to.equal(rewardRate);
    expect(await staker.totalStaked()).to.equal(0);
  });

  it("should allow user to stake tokens", async function () {
    await expect(staker.connect(user1).stake(ethers.parseEther("100")))
      .to.emit(staker, "Staked")
      .withArgs(await user1.getAddress(), ethers.parseEther("100"));
    expect((await staker.stakes(await user1.getAddress())).active).to.be.true;
  });

  it("should revert if stake amount is zero", async function () {
    await expect(staker.connect(user1).stake(0)).to.be.revertedWith("Cannot stake zero tokens");
  });

  it("should prevent user from staking twice", async function () {
    await staker.connect(user1).stake(ethers.parseEther("100"));
    await expect(staker.connect(user1).stake(ethers.parseEther("50"))).to.be.revertedWith("Already staking");
  });

  it("should calculate reward correctly after some time", async function () {
    await staker.connect(user1).stake(ethers.parseEther("100"));
    await ethers.provider.send("evm_increaseTime", [60]); // 60 seconds
    await ethers.provider.send("evm_mine", []);
    const reward = await staker.calculateReward(await user1.getAddress());
    expect(reward).to.be.gt(0);
  });

  it("should not allow unstake before minimum time", async function () {
    await staker.connect(user1).stake(ethers.parseEther("100"));
    await expect(staker.connect(user1).unstake()).to.be.revertedWith("Stake time not met");
  });

  it("should allow unstake after minimum time", async function () {
    await staker.connect(user1).stake(ethers.parseEther("100"));
    await ethers.provider.send("evm_increaseTime", [40]);
    await ethers.provider.send("evm_mine", []);
    await expect(staker.connect(user1).unstake())
      .to.emit(staker, "Unstaked")
      .withArgs(await user1.getAddress(), ethers.parseEther("100"), anyValue);
  });

  it("should update rewardRate only by owner", async function () {
    await expect(staker.connect(user1).updateRewardRate(100)).to.be.reverted;
    await expect(staker.connect(owner).updateRewardRate(100))
      .to.emit(staker, "RewardRateUpdated")
      .withArgs(100);
  });

  it("should reduce totalStaked after unstake", async function () {
    await staker.connect(user1).stake(ethers.parseEther("100"));
    await ethers.provider.send("evm_increaseTime", [40]);
    await ethers.provider.send("evm_mine", []);
    await staker.connect(user1).unstake();
    expect(await staker.totalStaked()).to.equal(0);
  });

  it("should store user rewards after unstake", async function () {
    await staker.connect(user1).stake(ethers.parseEther("100"));
    await ethers.provider.send("evm_increaseTime", [60]);
    await ethers.provider.send("evm_mine", []);
    await staker.connect(user1).unstake();
    const userReward = await staker.rewards(await user1.getAddress());
    expect(userReward).to.be.gt(0);
  });

  it("should not allow unstake if no active stake", async function () {
    await expect(staker.connect(user1).unstake()).to.be.revertedWith("No active stake");
  });

  it("should return stake info correctly", async function () {
    await staker.connect(user1).stake(ethers.parseEther("200"));
    const info = await staker.getStakeInfo(await user1.getAddress());
    expect(info.amount).to.equal(ethers.parseEther("200"));
    expect(info.active).to.be.true;
  });

  it("should handle multiple users staking independently", async function () {
    await staker.connect(user1).stake(ethers.parseEther("100"));
    await staker.connect(user2).stake(ethers.parseEther("200"));
    const total = await staker.totalStaked();
    expect(total).to.equal(ethers.parseEther("300"));
  });

  it("should emit correct events for stake and unstake", async function () {
    await expect(staker.connect(user1).stake(ethers.parseEther("50")))
      .to.emit(staker, "Staked")
      .withArgs(await user1.getAddress(), ethers.parseEther("50"));
    await ethers.provider.send("evm_increaseTime", [40]);
    await ethers.provider.send("evm_mine", []);
    await expect(staker.connect(user1).unstake()).to.emit(staker, "Unstaked");
  });

  it("should reject unstake if stake not found", async function () {
    await expect(staker.connect(user2).unstake()).to.be.revertedWith("No active stake");
  });
});
