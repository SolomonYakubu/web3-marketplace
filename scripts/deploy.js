const hre = require("hardhat");
const { ethers } = hre;
const { Deployer } = require("@matterlabs/hardhat-zksync");
const { Wallet, Provider } = require("zksync-ethers");
require("dotenv").config();

async function main() {
  // Build zkSync provider and wallet from the active network config
  const networkUrl = hre.network.config?.url || "http://127.0.0.1:8011";
  const provider = new Provider(networkUrl);

  // Prefer an explicitly provided PK, otherwise use the first configured account
  // Fall back to the known funded key on inMemoryNode
  const FUNDED_INMEMORY_PK =
    "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110";
  const accounts = hre.network.config?.accounts || [];
  const fallbackPk =
    hre.network.name === "inMemoryNode"
      ? FUNDED_INMEMORY_PK
      : Array.isArray(accounts) && accounts.length > 0
      ? accounts[0]
      : FUNDED_INMEMORY_PK;
  const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || fallbackPk;
  const wallet = new Wallet(PRIVATE_KEY, provider);

  console.log("Deployer:", wallet.address);
  console.log(
    "Balance:",
    ethers.formatEther(await provider.getBalance(wallet.address))
  );

  const deployer = new Deployer(hre, wallet);

  // Resolve token addresses or deploy mocks if not provided
  let dopAddress = process.env.DOP_ADDRESS || "";
  let usdcAddress = process.env.USDC_ADDRESS || ""; // optional
  const TREASURY = process.env.TREASURY_ADDRESS || wallet.address;
  const DEX_ROUTER = process.env.DEX_ROUTER_ADDRESS;
  const WETH = process.env.WETH_ADDRESS;

  if (!dopAddress || !usdcAddress) {
    console.log("\n=== Token addresses not provided, deploying mocks ===");
    // DOP mock (mint to deployer)
    const dopArtifact = await deployer.loadArtifact("DOPMock");
    const dop = await deployer.deploy(dopArtifact, [
      wallet.address,
      ethers.parseEther("1000000").toString(),
    ]);
    await dop.waitForDeployment();
    dopAddress = await dop.getAddress();
    console.log("DOPMock:", dopAddress);

    // USDC mock (mint to deployer)
    const usdcArtifact = await deployer.loadArtifact("ERC20Mock");
    const usdc = await deployer.deploy(usdcArtifact, [
      "USDC",
      "USDC",
      wallet.address,
      ethers.parseEther("1000000").toString(),
    ]);
    await usdc.waitForDeployment();
    usdcAddress = await usdc.getAddress();
    console.log("ERC20Mock (USDC):", usdcAddress);
  }

  console.log("\n=== Deployment Configuration ===");
  console.log("Network:", hre.network.name);
  console.log("DOP Token:", dopAddress);
  console.log("USDC Token:", usdcAddress || ethers.ZeroAddress);
  console.log("Treasury:", TREASURY);
  console.log("DEX Router:", DEX_ROUTER || "Not set (buyback disabled)");
  console.log("WETH:", WETH || "Not set");

  console.log("\n=== Deploying Marketplace (zkSync UUPS proxy) ===");
  const marketArtifact = await deployer.loadArtifact("MarketplaceUpgradeable");

  const proxy = await hre.zkUpgrades.deployProxy(
    deployer.zkWallet,
    marketArtifact,
    [dopAddress, usdcAddress || ethers.ZeroAddress, TREASURY],
    { kind: "uups", initializer: "initialize" }
  );
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();

  console.log("\n✅ Deployment successful!");
  console.log("MarketplaceUpgradeable proxy:", proxyAddress);

  // Optional: configure DEX router if provided
  if (DEX_ROUTER && WETH) {
    console.log("\n=== Configuring DEX Integration ===");
    try {
      const tx = await proxy.setDexRouter(DEX_ROUTER, WETH);
      await tx.wait();
      console.log("✅ DEX router configured for buyback functionality");
    } catch (error) {
      console.log("⚠️  Failed to set DEX router:", error.message);
    }
  } else {
    console.log(
      "\n⚠️  DEX router not configured - buyback will send to treasury"
    );
  }

  // Display contract info
  console.log("\n=== Contract Info ===");
  try {
    const feeUsdLike = await proxy.feeUsdLike();
    const feeDop = await proxy.feeDop();
    const boostPrice = await proxy.boostPriceDOP();
    const boostDuration = await proxy.boostDuration();

    console.log(
      "USD-like fee:",
      feeUsdLike.toString() + " bps (" + Number(feeUsdLike) / 100 + "%)"
    );
    console.log(
      "DOP fee:",
      feeDop.toString() + " bps (" + Number(feeDop) / 100 + "%)"
    );
    console.log("Boost price:", ethers.formatEther(boostPrice) + " DOP");
    console.log("Boost duration:", Number(boostDuration) / 86400 + " days");
  } catch (error) {
    console.log("Could not fetch contract info:", error.message);
  }

  console.log("\n=== Next Steps ===");
  console.log("1. Verify contract:");
  console.log(
    `   npx hardhat verify --network ${hre.network.name} ${proxyAddress}`
  );
  console.log("\n2. Set environment variable for upgrades:");
  console.log(`   export MARKETPLACE_PROXY=${proxyAddress}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
