// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers } from "hardhat";
// import hre, { ethers } from "hardhat";

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run("compile");

  const accounts = await ethers.getSigners();
  const [owner, deployer] = accounts;

  const gasLimit = 6721975;
  const UniETHFactory = await ethers.getContractFactory("RockXETH");
  const uniETHContract = await UniETHFactory.deploy({
    gasLimit,
  });
  await uniETHContract.deployed();
  console.log("UniETH address:", uniETHContract.address);

  const StakingFactory = await ethers.getContractFactory("RockXStaking");
  const stakingContract = await StakingFactory.deploy({
    gasLimit,
  });
  await stakingContract.deployed();
  console.log("Staking address:", stakingContract.address);

  const RedeemFactory = await ethers.getContractFactory("RockXRedeem");
  const redeemContract = await RedeemFactory.deploy({
    gasLimit,
  });
  await redeemContract.deployed();
  console.log("Redeem address:", redeemContract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
