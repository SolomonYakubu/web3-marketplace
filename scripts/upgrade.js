require("dotenv").config();
const hre = require("hardhat");
const { Deployer } = require("@matterlabs/hardhat-zksync");

async function main() {
  const PROXY = process.env.MARKETPLACE_PROXY;

  if (!PROXY) throw new Error("MARKETPLACE_PROXY missing");
  // Contract name of the new implementation (NOT an address). Override via env MARKETPLACE_IMPL_NAME.
  const CONTRACT_NAME =
    process.env.MARKETPLACE_IMPL_NAME || "MarketplaceUpgradeable";
  if (CONTRACT_NAME.startsWith("0x")) {
    throw new Error(
      "MARKETPLACE_IMPL_NAME must be a contract name, not an address. Provide the Solidity contract name."
    );
  }

  // Build deployer with the active zk wallet
  const networkUrl = hre.network.config?.url || "http://127.0.0.1:8011";
  const { Provider, Wallet } = require("zksync-ethers");
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

  const deployer = new Deployer(hre, wallet);
  // Ensure artifacts are compiled
  await hre.run("compile");
  const implArtifact = await deployer.loadArtifact(CONTRACT_NAME);
  const upgraded = await hre.zkUpgrades.upgradeProxy(
    deployer.zkWallet,
    PROXY,
    implArtifact
  );
  console.log(
    `Upgraded to implementation ${CONTRACT_NAME}, proxy still at`,
    await upgraded.getAddress()
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
