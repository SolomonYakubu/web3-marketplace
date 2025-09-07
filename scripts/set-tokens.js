require("dotenv").config();
const hre = require("hardhat");
const { Deployer } = require("@matterlabs/hardhat-zksync");
const { Provider, Wallet, Contract } = require("zksync-ethers");

async function main() {
  const PROXY = process.env.MARKETPLACE_PROXY;
  if (!PROXY) throw new Error("MARKETPLACE_PROXY missing");

  // Build provider and wallet
  const networkUrl = hre.network.config?.url || "http://127.0.0.1:8011";
  const provider = new Provider(networkUrl);

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

  // Load ABI
  const deployer = new Deployer(hre, wallet);
  const marketArtifact = await deployer.loadArtifact("MarketplaceUpgradeable");
  const market = new Contract(PROXY, marketArtifact.abi, wallet);

  // Resolve desired addresses
  const newDop = process.env.DOP_ADDRESS;
  if (!newDop) throw new Error("DOP_ADDRESS missing");

  let newUsdc = process.env.USDC_ADDRESS;
  if (!newUsdc) {
    // Keep existing USDC if not provided
    newUsdc = await market.usdcToken();
  }

  console.log("Network:", hre.network.name);
  console.log("Proxy:", PROXY);
  console.log("Owner (signer):", wallet.address);
  console.log("Setting DOP:", newDop);
  console.log("Setting USDC:", newUsdc);

  const tx = await market.setTokens(newDop, newUsdc);
  console.log("Submitted:", tx.hash);
  const rcpt = await tx.wait();
  console.log("✅ Tokens updated in tx:", rcpt.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
