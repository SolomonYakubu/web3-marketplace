const { expect } = require("chai");
const { ethers } = require("hardhat");
const { Deployer } = require("@matterlabs/hardhat-zksync");
const { Wallet, Provider } = require("zksync-ethers");
const hre = require("hardhat");

// Consolidated test file focusing only on MarketplaceUpgradeable

const toEth = (n) => ethers.parseEther(n.toString());
const toEthStr = (n) => ethers.parseEther(n.toString()).toString();

const FUNDED_INMEMORY_PK =
  "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110";

describe("MarketplaceUpgradeable", function () {
  let owner, alice, bob, carol, dan;
  let dop, usdc, proxy;
  let deployer;
  let provider;
  let treasury; // address used as treasury during deployment

  // Increase timeout for zkSync deployment
  this.timeout(120000);

  // Snapshot helpers to avoid redeploying between tests
  let snapshotId;
  const takeSnapshot = async () =>
    await hre.network.provider.send("evm_snapshot", []);
  const revertSnapshot = async (id) =>
    await hre.network.provider.send("evm_revert", [id]);

  // Deploy once, snapshot state
  before(async function () {
    // Build zkSync provider and wallets from network config
    const networkUrl = hre.network.config?.url || "http://127.0.0.1:8011";
    provider = new Provider(networkUrl);

    // Prefer the known funded key on local inMemoryNode
    let pk = FUNDED_INMEMORY_PK;
    if (hre.network.name !== "inMemoryNode") {
      const accounts = hre.network.config?.accounts || [];
      pk =
        Array.isArray(accounts) && accounts.length > 0
          ? accounts[0]
          : process.env.DEPLOYER_PRIVATE_KEY || FUNDED_INMEMORY_PK;
    }

    const ownerWallet = new Wallet(pk, provider);

    const aliceWallet = new Wallet("0x" + "12".repeat(32), provider);
    const bobWallet = new Wallet("0x" + "13".repeat(32), provider);
    const carolWallet = new Wallet("0x" + "14".repeat(32), provider);
    const danWallet = new Wallet("0x" + "15".repeat(32), provider);

    [owner, alice, bob, carol, dan] = [
      ownerWallet,
      aliceWallet,
      bobWallet,
      carolWallet,
      danWallet,
    ];

    treasury = owner.address;

    // Ensure accounts are funded on local zkSync by setting balances directly
    const setBalance = async (addr, amount) => {
      const hex = ethers.toBeHex(amount);
      try {
        await hre.network.provider.send("anvil_setBalance", [addr, hex]);
      } catch (_) {
        try {
          await hre.network.provider.send("hardhat_setBalance", [addr, hex]);
        } catch (_) {
          await hre.network.provider.send("evm_setBalance", [addr, hex]);
        }
      }
    };
    const fundAmount = toEth(1_000_000); // ample
    for (const w of [owner, alice, bob, carol, dan]) {
      await setBalance(w.address, fundAmount);
    }

    // Initialize deployer for zkSync-specific deployments
    deployer = new Deployer(hre, owner);

    // Deploy tokens using zkSync Deployer
    const dopArtifact = await deployer.loadArtifact("DOPMock");
    dop = await deployer.deploy(dopArtifact, [
      owner.address,
      toEthStr(1_000_000),
    ]);
    await dop.waitForDeployment();

    const usdcArtifact = await deployer.loadArtifact("ERC20Mock");
    usdc = await deployer.deploy(usdcArtifact, [
      "USDC",
      "USDC",
      owner.address,
      toEthStr(1_000_000),
    ]);
    await usdc.waitForDeployment();

    // Deploy proxy using zkSync Upgrades
    const marketArtifact = await deployer.loadArtifact(
      "MarketplaceUpgradeable"
    );
    proxy = await hre.zkUpgrades.deployProxy(
      deployer.zkWallet,
      marketArtifact,
      [await dop.getAddress(), await usdc.getAddress(), treasury],
      { kind: "uups", initializer: "initialize" }
    );
    await proxy.waitForDeployment();

    // Transfer tokens to test wallets
    for (const u of [alice, bob, carol, dan]) {
      await dop.connect(owner).transfer(u.address, toEth(10_000));
      await usdc.connect(owner).transfer(u.address, toEth(10_000));
    }

    // Take initial snapshot after full setup
    snapshotId = await takeSnapshot();
  });

  // Revert to clean snapshot before each test and create a fresh snapshot for the next one
  beforeEach(async function () {
    await revertSnapshot(snapshotId);
    snapshotId = await takeSnapshot();
  });

  it("initialization params", async () => {
    expect(await proxy.treasury()).to.equal(treasury);
    expect(await proxy.feeUsdLike()).to.equal(2000);
    expect(await proxy.feeDop()).to.equal(1000);
  });

  it("listing creation, boost, and isBoosted lifecycle", async () => {
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    const price = await proxy.boostPriceDOP();
    await dop.connect(alice).approve(await proxy.getAddress(), price);
    await expect(proxy.connect(alice).buyBoost(1, price)).to.emit(
      proxy,
      "BoostPurchased"
    );
    expect(await proxy.isBoosted(1)).to.equal(true);
  });

  it("brief native escrow full flow", async () => {
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    await proxy.connect(bob).makeOffer(1, toEth(5), ethers.ZeroAddress);
    await proxy.connect(alice).acceptOffer(1, { value: toEth(5) });
    await proxy.connect(bob).validateWork(1);
    await expect(proxy.connect(alice).validateWork(1)).to.emit(
      proxy,
      "EscrowCompleted"
    );
    const esc = await proxy.getEscrow(1);
    expect(esc.status).to.equal(2); // COMPLETED
  });

  it("gig USDC escrow flow with fee", async () => {
    await proxy.connect(bob).createListing(1, 2, "ipfs://gig");
    await proxy.connect(alice).makeOffer(1, toEth(10), await usdc.getAddress());
    await usdc.connect(alice).approve(await proxy.getAddress(), toEth(10));
    await proxy.connect(bob).acceptOffer(1);
    await proxy.connect(bob).validateWork(1);
    await proxy.connect(alice).validateWork(1);
    const esc = await proxy.getEscrow(1);
    expect(esc.status).to.equal(2);
  });

  it("dop escrow fee burn split", async () => {
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    await proxy.connect(bob).makeOffer(1, toEth(100), await dop.getAddress());
    await dop.connect(alice).approve(await proxy.getAddress(), toEth(100));
    const supplyBefore = await dop.totalSupply();
    await proxy.connect(alice).acceptOffer(1);
    await proxy.connect(bob).validateWork(1);
    await proxy.connect(alice).validateWork(1);
    const fee = (toEth(100) * 1000n) / 10000n;
    const burnExpected = fee / 2n;
    const supplyAfter = await dop.totalSupply();
    expect(supplyBefore - supplyAfter).to.equal(burnExpected);
  });

  it("dispute flows outcomes", async () => {
    // REFUND_CLIENT
    await proxy.connect(alice).createListing(0, 1, "x");
    await proxy.connect(bob).makeOffer(1, toEth(20), ethers.ZeroAddress);
    await proxy.connect(alice).acceptOffer(1, { value: toEth(20) });
    await proxy.connect(alice).openDispute(1);
    await expect(proxy.resolveDispute(1, 1)).to.emit(proxy, "DisputeResolved");
    // SPLIT
    await proxy.connect(alice).createListing(0, 1, "y");
    await proxy.connect(bob).makeOffer(2, toEth(20), ethers.ZeroAddress);
    await proxy.connect(alice).acceptOffer(2, { value: toEth(20) });
    await proxy.connect(bob).openDispute(2);
    await expect(proxy.resolveDispute(2, 2)).to.emit(proxy, "DisputeResolved");
    // PAY_PROVIDER
    await proxy.connect(alice).createListing(0, 1, "z");
    await proxy.connect(bob).makeOffer(3, toEth(20), ethers.ZeroAddress);
    await proxy.connect(alice).acceptOffer(3, { value: toEth(20) });
    await proxy.connect(bob).openDispute(3);
    await expect(proxy.resolveDispute(3, 3)).to.emit(proxy, "DisputeResolved");
  });

  it("admin setters and pause", async () => {
    await expect(proxy.connect(owner).setFees(4000, 1000)).to.be.revertedWith(
      "caps"
    );
    await proxy.connect(owner).setFees(1500, 900);
    expect(await proxy.feeUsdLike()).to.equal(1500);
    await expect(
      proxy.connect(owner).setBoostParams(1, 3600)
    ).to.be.revertedWith("dur");
    await proxy.connect(owner).setBoostParams(123, 86400);
    expect(await proxy.boostPriceDOP()).to.equal(123);
    await proxy.connect(owner).pause();
    await expect(proxy.connect(alice).createListing(0, 1, "x")).to.be.reverted; // paused
    await proxy.connect(owner).unpause();
    await proxy.connect(alice).createListing(0, 1, "ok");
  });

  const RUN_UPGRADE = process.env.RUN_UPGRADE === "1";
  const itMaybeUpgrade = RUN_UPGRADE ? it : it.skip;

  itMaybeUpgrade("[upgrade] preserves state", async () => {
    await proxy.connect(alice).createListing(0, 1, "brief");
    const v2Artifact = await deployer.loadArtifact("MarketplaceUpgradeableV2");
    const upgraded = await hre.zkUpgrades.upgradeProxy(
      deployer.zkWallet,
      await proxy.getAddress(),
      v2Artifact
    );
    await upgraded.initializeV2();
    expect(await upgraded.version()).to.equal("v2");
  });

  it("profile creation and management", async () => {
    // Create profile for Alice (Artist)
    await proxy.connect(alice).createProfile(
      "Digital artist specializing in NFTs",
      ["Digital Art", "3D Modeling", "Animation"],
      ["ipfs://portfolio1", "ipfs://portfolio2"],
      2 // ARTIST
    );

    const profile = await proxy.profiles(alice.address);
    expect(profile.bio).to.equal("Digital artist specializing in NFTs");
    expect(profile.userType).to.equal(2);
    expect(profile.isVerified).to.equal(false);

    // Verify profile as owner
    await proxy.connect(owner).verifyProfile(alice.address);
    const verifiedProfile = await proxy.profiles(alice.address);
    expect(verifiedProfile.isVerified).to.equal(true);

    // Update profile
    await proxy
      .connect(alice)
      .updateProfile(
        "Updated bio",
        ["Updated Skills"],
        ["ipfs://newportfolio"]
      );

    const updatedProfile = await proxy.profiles(alice.address);
    expect(updatedProfile.bio).to.equal("Updated bio");
  });

  it("badge system and mission history", async () => {
    // Create profiles
    await proxy.connect(alice).createProfile("Client", [], [], 0); // PROJECT_OWNER
    await proxy.connect(bob).createProfile("Developer", [], [], 1); // DEVELOPER

    // Complete first mission to earn ROOKIE badge
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    await proxy.connect(bob).makeOffer(1, toEth(5), ethers.ZeroAddress);
    await proxy.connect(alice).acceptOffer(1, { value: toEth(5) });
    await proxy.connect(bob).validateWork(1);
    await proxy.connect(alice).validateWork(1);

    // Check badges
    const aliceBadges = await proxy.getUserBadges(alice.address);
    const bobBadges = await proxy.getUserBadges(bob.address);
    expect(aliceBadges.length).to.equal(1);
    expect(aliceBadges[0]).to.equal(0); // ROOKIE
    expect(bobBadges.length).to.equal(1);
    expect(bobBadges[0]).to.equal(0); // ROOKIE

    // Check mission history
    const aliceMissions = await proxy.getMissionHistory(alice.address);
    const bobMissions = await proxy.getMissionHistory(bob.address);
    expect(aliceMissions.length).to.equal(1);
    expect(bobMissions.length).to.equal(1);
    expect(aliceMissions[0].wasDisputed).to.equal(false);
    expect(bobMissions[0].wasDisputed).to.equal(false);
  });

  it("disputed mission affects badge system", async () => {
    // Create profiles
    await proxy.connect(alice).createProfile("Client", [], [], 0);
    await proxy.connect(bob).createProfile("Provider", [], [], 1);

    // Create mission and dispute it
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    await proxy.connect(bob).makeOffer(1, toEth(10), ethers.ZeroAddress);
    await proxy.connect(alice).acceptOffer(1, { value: toEth(10) });
    await proxy.connect(alice).openDispute(1);
    await proxy.resolveDispute(1, 1); // REFUND_CLIENT

    // Check mission history includes dispute flag
    const aliceMissions = await proxy.getMissionHistory(alice.address);
    const bobMissions = await proxy.getMissionHistory(bob.address);
    expect(aliceMissions[0].wasDisputed).to.equal(true);
    expect(bobMissions[0].wasDisputed).to.equal(true);

    // Check reputation includes disputed missions
    const aliceRep = await proxy.reputations(alice.address);
    const bobRep = await proxy.reputations(bob.address);
    expect(aliceRep.disputedMissions).to.equal(1);
    expect(bobRep.disputedMissions).to.equal(1);
  });

  it("enhanced fee processing with USD tokens", async () => {
    // Create profiles and listing
    await proxy.connect(alice).createProfile("Client", [], [], 0);
    await proxy.connect(bob).createProfile("Provider", [], [], 1);
    await proxy.connect(bob).createListing(1, 2, "ipfs://gig");

    // Make offer with USDC
    await proxy
      .connect(alice)
      .makeOffer(1, toEth(100), await usdc.getAddress());
    await usdc.connect(alice).approve(await proxy.getAddress(), toEth(100));

    // Treasury balance before
    const treasuryBalanceBefore = await usdc.balanceOf(treasury);

    await proxy.connect(bob).acceptOffer(1);
    await proxy.connect(bob).validateWork(1);
    await proxy.connect(alice).validateWork(1);

    // With router unset, burn portion falls back to treasury too
    const treasuryBalanceAfter = await usdc.balanceOf(treasury);
    const feeAmount = (toEth(100) * 2000n) / 10000n; // 20% fee
    expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(feeAmount);
  });

  it("reviews flow and average rating", async () => {
    // Complete a GIG with USDC
    await proxy.connect(bob).createListing(1, 2, "ipfs://gig");
    await proxy.connect(alice).makeOffer(1, toEth(10), await usdc.getAddress());
    await usdc.connect(alice).approve(await proxy.getAddress(), toEth(10));
    await proxy.connect(bob).acceptOffer(1);
    await proxy.connect(bob).validateWork(1);
    await proxy.connect(alice).validateWork(1);

    // Both participants leave reviews
    await expect(proxy.connect(alice).leaveReview(1, 5, "ipfs://r1")).to.emit(
      proxy,
      "ReviewSubmitted"
    );
    await expect(proxy.connect(bob).leaveReview(1, 4, "ipfs://r2")).to.emit(
      proxy,
      "ReviewSubmitted"
    );

    // Reputation aggregates
    const bobRep = await proxy.reputations(bob.address);
    expect(bobRep.ratingsCount).to.equal(1);
    expect(bobRep.ratingsSum).to.equal(5);

    const aliceRep = await proxy.reputations(alice.address);
    expect(aliceRep.ratingsCount).to.equal(1);
    expect(aliceRep.ratingsSum).to.equal(4);

    // Has reviewed flags
    expect(await proxy.hasReviewed(1, alice.address)).to.equal(true);
    expect(await proxy.hasReviewed(1, bob.address)).to.equal(true);

    // Average ratings (*100)
    expect(await proxy.getAverageRating(bob.address)).to.equal(500n);
    expect(await proxy.getAverageRating(alice.address)).to.equal(400n);

    // No double reviews
    await expect(proxy.connect(alice).leaveReview(1, 5, "")).to.be.revertedWith(
      "done"
    );
  });

  it("review rating bounds enforced", async () => {
    await proxy.connect(bob).createListing(1, 2, "ipfs://gig");
    await proxy.connect(alice).makeOffer(1, toEth(1), await usdc.getAddress());
    await usdc.connect(alice).approve(await proxy.getAddress(), toEth(1));
    await proxy.connect(bob).acceptOffer(1);
    await proxy.connect(bob).validateWork(1);
    await proxy.connect(alice).validateWork(1);

    await expect(
      proxy.connect(alice).leaveReview(1, 0, "bad")
    ).to.be.revertedWith("rating");
    await expect(
      proxy.connect(bob).leaveReview(1, 6, "bad")
    ).to.be.revertedWith("rating");
  });

  it("profile boosting lifecycle and params", async () => {
    // Buying without profile should fail
    await expect(proxy.connect(bob).buyProfileBoost(1)).to.be.revertedWith(
      "No profile"
    );

    // Create profile and buy
    await proxy.connect(alice).createProfile("Artist", [], [], 2);
    const price = await proxy.profileBoostPriceDOP();
    await dop.connect(alice).approve(await proxy.getAddress(), price);
    await expect(proxy.connect(alice).buyProfileBoost(price)).to.emit(
      proxy,
      "ProfileBoostPurchased"
    );
    expect(await proxy.isProfileBoosted(alice.address)).to.equal(true);

    // Params setter
    await expect(
      proxy.connect(owner).setProfileBoostParams(123, 3600)
    ).to.be.revertedWith("dur");
    await proxy.connect(owner).setProfileBoostParams(456, 86400);
    expect(await proxy.profileBoostPriceDOP()).to.equal(456);
  });

  it("offer cancellation before accept", async () => {
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    await proxy.connect(bob).makeOffer(1, toEth(10), ethers.ZeroAddress);
    await expect(proxy.connect(bob).cancelOffer(1)).to.emit(
      proxy,
      "OfferCancelled"
    );
    await expect(
      proxy.connect(alice).acceptOffer(1, { value: toEth(10) })
    ).to.be.revertedWith("offer");
  });

  // New: Router integration tests
  it("buyback-and-burn via router on ERC20 fee", async () => {
    // Deploy mock router with rate 1000 DOP per 1 USDC
    const routerArtifact = await deployer.loadArtifact("MockUniswapV2Router");
    const router = await deployer.deploy(routerArtifact, [toEthStr(1000)]);
    await router.waitForDeployment();

    // Fund router with DOP so it can dispense on swaps
    await dop
      .connect(owner)
      .transfer(await router.getAddress(), toEth(100_000));

    // Configure router + mock WETH (unused for token->token path here)
    await proxy
      .connect(owner)
      .setDexRouter(await router.getAddress(), ethers.ZeroAddress);

    // Create GIG listing and offer with USDC
    await proxy.connect(bob).createListing(1, 2, "ipfs://gig");
    await proxy
      .connect(alice)
      .makeOffer(1, toEth(100), await usdc.getAddress());
    await usdc.connect(alice).approve(await proxy.getAddress(), toEth(100));

    // Expect BuybackAndBurn during completion and supply reduced by 10,000 DOP (10 USDC * 1000)
    await proxy.connect(bob).acceptOffer(1);
    await proxy.connect(bob).validateWork(1);
    const supplyBefore = await dop.totalSupply();
    const tx = await proxy.connect(alice).validateWork(1);
    await expect(tx).to.emit(proxy, "BuybackAndBurn");
    const supplyAfter = await dop.totalSupply();
    expect(supplyBefore - supplyAfter).to.equal(toEth(10_000));
  });

  it("ETH escrow fee split and buyback via router", async () => {
    // Deploy router & fund with DOP
    const routerArtifact = await deployer.loadArtifact("MockUniswapV2Router");
    const router = await deployer.deploy(routerArtifact, [toEthStr(1000)]);
    await router.waitForDeployment();
    await dop
      .connect(owner)
      .transfer(await router.getAddress(), toEth(100_000));

    // Set router + mock WETH (use USDC address as dummy WETH for path building)
    await proxy
      .connect(owner)
      .setDexRouter(await router.getAddress(), await usdc.getAddress());

    // Brief with native ETH
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    await proxy.connect(bob).makeOffer(1, toEth(10), ethers.ZeroAddress);

    await proxy.connect(alice).acceptOffer(1, { value: toEth(10) });
    await proxy.connect(bob).validateWork(1);
    const supplyBefore = await dop.totalSupply();
    const tx = await proxy.connect(alice).validateWork(1);
    await expect(tx).to.emit(proxy, "BuybackAndBurn");
    const supplyAfter = await dop.totalSupply();
    expect(supplyBefore - supplyAfter).to.equal(toEth(1000));
  });

  it("ETH escrow fee split falls back to treasury when router/weth unset", async () => {
    // Ensure router is unset (fresh snapshot ensures this)
    await proxy.connect(alice).createListing(0, 1, "ipfs://brief");
    await proxy.connect(bob).makeOffer(1, toEth(10), ethers.ZeroAddress);

    const before = await provider.getBalance(treasury);

    await proxy.connect(alice).acceptOffer(1, { value: toEth(10) });
    await proxy.connect(bob).validateWork(1);
    const tx = await proxy.connect(alice).validateWork(1);
    await expect(tx).to.emit(proxy, "BuybackAndBurn"); // emitted with dopBurned=0 in fallback

    const after = await provider.getBalance(treasury);
    const feeAmount = (toEth(10) * 2000n) / 10000n; // 20% of 10 ETH
    expect(after - before).to.equal(feeAmount);
  });
});
