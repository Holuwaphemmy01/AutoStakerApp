import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, Signer } from "ethers";

describe("AutoStaker", function () {
  let token: Contract;
  let staker: Contract;
  let owner: Signer;
  let user: Signer;

  beforeEach(async function () {
    [owner, user] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("TestToken");
    token = await Token.deploy(ethers.parseEther("1000000"));
    await token.waitForDeployment();

    const Staker = await ethers.getContractFactory("AutoStaker");
    staker = await Staker.deploy(await token.getAddress(), 1n);
    await staker.waitForDeployment();

    // Send tokens to user
    await token.transfer(await user.getAddress(), ethers.parseEther("1000"));
  });

  it("should allow staking", async function () {
    const userAddr = await user.getAddress();

    await token.connect(user).approve(await staker.getAddress(), ethers.parseEther("100"));
    await staker.connect(user).stake(ethers.parseEther("100"));

    const stakeInfo = await staker.stakes(userAddr);
    expect(stakeInfo.amount).to.equal(ethers.parseEther("100"));
  });

  it("should calculate rewards correctly", async function () {
    await token.connect(user).approve(await staker.getAddress(), ethers.parseEther("100"));
    await staker.connect(user).stake(ethers.parseEther("100"));

    // simulate time
    await ethers.provider.send("evm_increaseTime", [60]);
    await ethers.provider.send("evm_mine", []);

    const reward = await staker.calculateReward(await user.getAddress());
    expect(reward).to.be.gt(0);
  });
});
