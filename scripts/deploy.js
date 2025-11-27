const { ethers } = require("hardhat");

async function main() {
  const DexiFiBridge = await ethers.getContractFactory("DexiFiBridge");
  const dexiFiBridge = await DexiFiBridge.deploy();

  await dexiFiBridge.deployed();

  console.log("DexiFiBridge contract deployed to:", dexiFiBridge.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
