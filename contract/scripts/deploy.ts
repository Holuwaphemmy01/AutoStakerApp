import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  // Deploy token
  const Token = await ethers.getContractFactory("TestToken");
  const token = await Token.deploy(ethers.parseEther("1000000"));
  await token.waitForDeployment();
  console.log("TestToken deployed at:", await token.getAddress());

  // Deploy AutoStaker
  const AutoStaker = await ethers.getContractFactory("AutoStaker");
  const autoStaker = await AutoStaker.deploy(await token.getAddress(), 1n);
  await autoStaker.waitForDeployment();
  console.log("AutoStaker deployed at:", await autoStaker.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
