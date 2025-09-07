const { ethers } = require("hardhat");

async function main() {
  // Generate a random wallet
  const wallet = ethers.Wallet.createRandom();

  console.log("🔑 New Wallet Generated for Testing:");
  console.log("Address:", wallet.address);
  console.log("Private Key:", wallet.privateKey);
  console.log("Mnemonic:", wallet.mnemonic.phrase);
  console.log("\n⚠️  KEEP THIS PRIVATE KEY SECURE!");
  console.log("💡 Add funds to this address before deploying");
  console.log("\n📋 Next steps:");
  console.log("1. Copy the private key above");
  console.log("2. Run: npx hardhat vars set DEPLOYER_PRIVATE_KEY");
  console.log("3. Paste the private key when prompted");
  console.log("4. Get testnet ETH for this address");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
