// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDOPToken} from "./IDOPToken.sol";

// Minimal UniswapV2-like router interface for buyback
interface IUniRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

/**
 * @title Upgradeable Death of Pengu Marketplace
 * @notice UUPS upgradeable version with improved role separation and simplified GIG acceptance logic.
 */
contract MarketplaceUpgradeable is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    enum ListingType {
        BRIEF,
        GIG
    }
    enum EscrowStatus {
        NONE,
        IN_PROGRESS,
        COMPLETED,
        DISPUTED,
        RESOLVED,
        CANCELLED
    }
    enum DisputeOutcome {
        NONE,
        REFUND_CLIENT,
        SPLIT,
        PAY_PROVIDER
    }

    struct Listing {
        uint256 id;
        ListingType listingType;
        address creator;
        string metadataURI;
        uint256 createdAt;
        bool active;
        uint256 boostExpiry;
        uint256 category;
    }
    struct Offer {
        uint256 id;
        uint256 listingId;
        address proposer;
        uint256 amount;
        address paymentToken;
        uint256 createdAt;
        bool accepted;
        bool cancelled;
    }
    struct Escrow {
        uint256 offerId;
        address client;
        address provider;
        address paymentToken;
        uint256 amount;
        uint256 feeAmount;
        EscrowStatus status;
        bool clientValidated;
        bool providerValidated;
        DisputeOutcome disputeOutcome;
    }
    struct Reputation {
        uint64 completedMissions;
        uint64 disputedMissions;
        uint128 score;
        // New: ratings aggregation
        uint64 ratingsCount;
        uint64 ratingsSum; // sum of ratings (e.g., 1-5)
    }

    struct UserProfile {
        string bio;
        string[] skills;
        string[] portfolioURIs; // IPFS links to portfolio items
        uint256 joinedAt;
        UserType userType; // KOL, Developer, Artist, Project Owner
        bool isVerified;
    }

    struct Mission {
        uint256 escrowId;
        address client;
        address provider;
        uint256 amount;
        address token;
        uint256 completedAt;
        bool wasDisputed;
    }

    // New: Reviews
    struct Review {
        uint256 offerId;
        address reviewer;
        address reviewee;
        uint8 rating; // 1-5
        string reviewURI; // optional IPFS/Arweave URI
        uint256 timestamp;
    }

    // New: Disputes metadata
    struct Appeal {
        address by;
        string cid; // IPFS CID for the appeal payload (JSON)
        uint256 timestamp;
    }

    struct DisputeData {
        string metadataCID; // initial dispute reason CID (JSON)
        address openedBy;
        uint256 openedAt;
        Appeal[] appeals; // chronological list of appeals
    }

    enum UserType {
        PROJECT_OWNER,
        DEVELOPER,
        ARTIST,
        KOL
    }

    enum Badge {
        ROOKIE, // 1-5 missions
        EXPERIENCED, // 6-20 missions
        EXPERT, // 21-50 missions
        MASTER, // 51+ missions
        RELIABLE, // 95%+ completion rate
        MEDIATOR // Resolved disputes fairly
    }

    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public feeUsdLike; // 20% default
    uint256 public feeDop; // 10% default
    uint256 public constant BURN_SPLIT_BPS = 5_000; // 50%
    uint256 public boostPriceDOP; // 1000 DOP default
    uint256 public boostDuration; // 7 days default
    // New: Profile boosting params
    uint256 public profileBoostPriceDOP; // default mirrors listing boost
    uint256 public profileBoostDuration; // default mirrors listing boost

    address public treasury;
    IDOPToken public dopToken;
    IERC20 public usdcToken; // optional

    // DEX integration for buyback functionality
    address public dexRouter;
    address public weth;

    uint256 private _listingIdCounter;
    uint256 private _offerIdCounter;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Offer) public offers;
    mapping(uint256 => Escrow) public escrows;
    mapping(address => Reputation) public reputations;
    mapping(address => UserProfile) public profiles;
    mapping(address => Mission[]) public userMissions;
    mapping(address => Badge[]) public userBadges;
    // New: Reviews storage
    mapping(address => Review[]) public reviewsReceived;
    mapping(uint256 => mapping(address => bool)) public hasReviewed; // offerId => reviewer => done
    // New: Profile boosting state
    mapping(address => uint256) public profileBoostExpiry;
    // Query indices
    mapping(uint256 => uint256[]) private _offersByListing; // listingId => offerIds
    mapping(address => uint256[]) private _listingsByCreator; // creator => listingIds
    // New: Disputes storage (non-breaking, appended)
    mapping(uint256 => DisputeData) private _disputes; // offerId => dispute data
    uint256[] private _disputeLog; // append-only log of offerIds when disputes are opened

    event ListingCreated(
        uint256 indexed id,
        ListingType listingType,
        address indexed creator,
        uint256 category,
        string metadataURI
    );
    event ListingStatus(uint256 indexed id, bool active);
    event BoostPurchased(
        uint256 indexed id,
        address indexed buyer,
        uint256 expiry,
        uint256 amountBurned,
        uint256 amountTreasury
    );
    event OfferMade(
        uint256 indexed id,
        uint256 indexed listingId,
        address indexed proposer,
        uint256 amount,
        address paymentToken
    );
    event OfferAccepted(uint256 indexed id, address client, address provider);
    event EscrowStarted(
        uint256 indexed offerId,
        address client,
        address provider,
        uint256 amount,
        address paymentToken,
        uint256 feeAmount
    );
    event MissionValidated(
        uint256 indexed offerId,
        address indexed by,
        bool clientValidated,
        bool providerValidated
    );
    event EscrowCompleted(
        uint256 indexed offerId,
        uint256 providerPayout,
        uint256 feeAmount
    );
    event DisputeOpened(uint256 indexed offerId);
    event DisputeResolved(
        uint256 indexed offerId,
        DisputeOutcome outcome,
        uint256 providerAmount,
        uint256 clientAmount
    );
    // New: Dispute metadata events
    event DisputeOpenedWithCID(
        uint256 indexed offerId,
        string cid,
        address indexed openedBy
    );
    event DisputeAppealed(
        uint256 indexed offerId,
        string cid,
        address indexed appealedBy
    );
    event ProfileCreated(address indexed user, UserType userType);
    event ProfileUpdated(address indexed user);
    event BadgeEarned(address indexed user, Badge badge);
    event BuybackAndBurn(
        address indexed token,
        uint256 usdAmount,
        uint256 dopBurned
    );
    // New: Offer cancellation
    event OfferCancelled(
        uint256 indexed id,
        uint256 indexed listingId,
        address indexed proposer
    );
    // New: Review submitted
    event ReviewSubmitted(
        uint256 indexed offerId,
        address indexed reviewer,
        address indexed reviewee,
        uint8 rating,
        string reviewURI
    );
    // New: Profile boost purchased
    event ProfileBoostPurchased(
        address indexed user,
        uint256 expiry,
        uint256 amountBurned,
        uint256 amountTreasury
    );
    // Admin: token config updates
    event TokensUpdated(address indexed dopToken, address indexed usdcToken);

    modifier onlyParticipant(uint256 offerId) {
        Escrow storage e = escrows[offerId];
        require(msg.sender == e.client || msg.sender == e.provider, "auth");
        _;
    }

    function initialize(
        address _dop,
        address _usdc,
        address _treasury
    ) external initializer {
        require(_dop != address(0) && _treasury != address(0), "zero");
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        dopToken = IDOPToken(_dop);
        usdcToken = IERC20(_usdc);
        treasury = _treasury;
        feeUsdLike = 2_000; // 20%
        feeDop = 1_000; // 10%
        boostPriceDOP = 1_000 ether;
        boostDuration = 7 days;
        // Defaults for profile boosting
        profileBoostPriceDOP = boostPriceDOP;
        profileBoostDuration = boostDuration;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- Internal helpers ---
    function _computeSplit(
        uint256 amount
    ) internal pure returns (uint256 burnAmt, uint256 treasAmt) {
        burnAmt = (amount * BURN_SPLIT_BPS) / FEE_DENOMINATOR;
        treasAmt = amount - burnAmt;
    }

    function _processDopFee(uint256 feeAmount) internal {
        if (feeAmount == 0) return;
        (uint256 burnAmt, uint256 treasAmt) = _computeSplit(feeAmount);
        dopToken.burn(burnAmt);
        IERC20(address(dopToken)).safeTransfer(treasury, treasAmt);
    }

    // New: Buyback helpers
    function _buyDopAndBurnFromETH(
        uint256 ethAmount
    ) internal returns (uint256 dopBurned) {
        if (ethAmount == 0) return 0;
        if (dexRouter == address(0) || weth == address(0)) {
            // Fallback: remit to treasury
            (bool ok, ) = payable(treasury).call{value: ethAmount}("");
            require(ok, "treasury");
            emit BuybackAndBurn(address(0), ethAmount, 0);
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(dopToken);
        uint256 beforeBal = IERC20(address(dopToken)).balanceOf(address(this));

        try
            IUniRouter(dexRouter)
                .swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: ethAmount
            }(0, path, address(this), block.timestamp)
        {
            uint256 afterBal = IERC20(address(dopToken)).balanceOf(
                address(this)
            );
            dopBurned = afterBal - beforeBal;
            if (dopBurned > 0) {
                dopToken.burn(dopBurned);
            }
            emit BuybackAndBurn(address(0), ethAmount, dopBurned);
        } catch {
            // Swap failed (likely no liquidity), fallback to treasury
            (bool ok, ) = payable(treasury).call{value: ethAmount}("");
            require(ok, "treasury");
            emit BuybackAndBurn(address(0), ethAmount, 0);
            return 0;
        }
    }

    function _buyDopAndBurnFromToken(
        address token,
        uint256 amount
    ) internal returns (uint256 dopBurned) {
        if (amount == 0) return 0;
        if (dexRouter == address(0)) {
            // Fallback: remit to treasury
            IERC20(token).safeTransfer(treasury, amount);
            emit BuybackAndBurn(token, amount, 0);
            return 0;
        }

        // Approve router
        IERC20(token).approve(dexRouter, 0);
        IERC20(token).approve(dexRouter, amount);
        address[] memory path;
        if (weth != address(0) && token != weth) {
            path = new address[](3);
            path[0] = token;
            path[1] = weth;
            path[2] = address(dopToken);
        } else {
            path = new address[](2);
            path[0] = token;
            path[1] = address(dopToken);
        }

        uint256 beforeBal = IERC20(address(dopToken)).balanceOf(address(this));

        try
            IUniRouter(dexRouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    amount,
                    0,
                    path,
                    address(this),
                    block.timestamp
                )
        {
            uint256 afterBal = IERC20(address(dopToken)).balanceOf(
                address(this)
            );
            dopBurned = afterBal - beforeBal;
            if (dopBurned > 0) {
                dopToken.burn(dopBurned);
            }
            emit BuybackAndBurn(token, amount, dopBurned);
        } catch {
            // Swap failed (likely no liquidity), fallback to treasury
            IERC20(token).safeTransfer(treasury, amount);
            emit BuybackAndBurn(token, amount, 0);
            return 0;
        }
    }

    // Profile Management
    function createProfile(
        string calldata bio,
        string[] calldata skills,
        string[] calldata portfolioURIs,
        UserType userType
    ) external {
        require(profiles[msg.sender].joinedAt == 0, "Profile exists");

        UserProfile storage profile = profiles[msg.sender];
        profile.bio = bio;
        profile.joinedAt = block.timestamp;
        profile.userType = userType;
        profile.isVerified = false;

        // Handle dynamic arrays separately
        delete profile.skills;
        delete profile.portfolioURIs;

        for (uint i = 0; i < skills.length; i++) {
            profile.skills.push(skills[i]);
        }

        for (uint i = 0; i < portfolioURIs.length; i++) {
            profile.portfolioURIs.push(portfolioURIs[i]);
        }

        emit ProfileCreated(msg.sender, userType);
    }

    function updateProfile(
        string calldata bio,
        string[] calldata skills,
        string[] calldata portfolioURIs
    ) external {
        require(profiles[msg.sender].joinedAt != 0, "No profile");
        UserProfile storage profile = profiles[msg.sender];
        profile.bio = bio;

        // Clear and rebuild arrays
        delete profile.skills;
        delete profile.portfolioURIs;

        for (uint i = 0; i < skills.length; i++) {
            profile.skills.push(skills[i]);
        }

        for (uint i = 0; i < portfolioURIs.length; i++) {
            profile.portfolioURIs.push(portfolioURIs[i]);
        }

        emit ProfileUpdated(msg.sender);
    }

    function verifyProfile(address user) external onlyOwner {
        require(profiles[user].joinedAt != 0, "No profile");
        profiles[user].isVerified = true;
    }

    // Mission History & Badge System
    function getMissionHistory(
        address user
    ) external view returns (Mission[] memory) {
        return userMissions[user];
    }

    function getUserBadges(
        address user
    ) external view returns (Badge[] memory) {
        return userBadges[user];
    }

    function _hasBadge(address user, Badge badge) internal view returns (bool) {
        Badge[] memory badges = userBadges[user];
        for (uint i = 0; i < badges.length; i++) {
            if (badges[i] == badge) return true;
        }
        return false;
    }

    function _updateBadges(address user) internal {
        uint256 missionCount = userMissions[user].length;
        Badge[] storage badges = userBadges[user];

        // Award mission count badges
        if (missionCount >= 51 && !_hasBadge(user, Badge.MASTER)) {
            badges.push(Badge.MASTER);
            emit BadgeEarned(user, Badge.MASTER);
        } else if (missionCount >= 21 && !_hasBadge(user, Badge.EXPERT)) {
            badges.push(Badge.EXPERT);
            emit BadgeEarned(user, Badge.EXPERT);
        } else if (missionCount >= 6 && !_hasBadge(user, Badge.EXPERIENCED)) {
            badges.push(Badge.EXPERIENCED);
            emit BadgeEarned(user, Badge.EXPERIENCED);
        } else if (missionCount >= 1 && !_hasBadge(user, Badge.ROOKIE)) {
            badges.push(Badge.ROOKIE);
            emit BadgeEarned(user, Badge.ROOKIE);
        }

        // Award reliability badge (95%+ completion rate)
        if (missionCount >= 10) {
            uint256 disputed = 0;
            for (uint i = 0; i < userMissions[user].length; i++) {
                if (userMissions[user][i].wasDisputed) disputed++;
            }
            uint256 reliabilityRate = ((missionCount - disputed) * 100) /
                missionCount;
            if (reliabilityRate >= 95 && !_hasBadge(user, Badge.RELIABLE)) {
                badges.push(Badge.RELIABLE);
                emit BadgeEarned(user, Badge.RELIABLE);
            }
        }
    }

    // Enhanced fee processing with buyback mechanism
    function _processUsdFee(uint256 feeAmount, address token) internal {
        if (feeAmount == 0) return;
        (uint256 burnAmount, uint256 treasuryAmount) = _computeSplit(feeAmount);

        // Send treasury portion
        IERC20(token).safeTransfer(treasury, treasuryAmount);

        // Buy DOP and burn from remaining tokens
        if (burnAmount > 0) {
            _buyDopAndBurnFromToken(token, burnAmount);
        }
    }

    // Listings
    function createListing(
        ListingType listingType,
        uint256 category,
        string calldata metadataURI
    ) external whenNotPaused returns (uint256 id) {
        require(category <= 3, "cat");
        id = ++_listingIdCounter;
        listings[id] = Listing(
            id,
            listingType,
            msg.sender,
            metadataURI,
            block.timestamp,
            true,
            0,
            category
        );
        // index creator -> listings
        _listingsByCreator[msg.sender].push(id);
        emit ListingCreated(id, listingType, msg.sender, category, metadataURI);
    }

    function setListingActive(uint256 listingId, bool active) external {
        Listing storage l = listings[listingId];
        require(l.creator == msg.sender || msg.sender == owner(), "auth");
        l.active = active;
        emit ListingStatus(listingId, active);
    }

    // Boost
    function buyBoost(
        uint256 listingId,
        uint256 dopAmount
    ) external nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        require(l.id != 0 && l.active, "listing");
        require(l.creator == msg.sender, "owner");
        require(dopAmount >= boostPriceDOP, "price");
        dopToken.transferFrom(msg.sender, address(this), dopAmount);
        (uint256 burnAmt, uint256 treasAmt) = _computeSplit(dopAmount);
        dopToken.burn(burnAmt);
        dopToken.transfer(treasury, treasAmt);
        uint256 base = l.boostExpiry > block.timestamp
            ? l.boostExpiry
            : block.timestamp;
        l.boostExpiry = base + boostDuration;
        emit BoostPurchased(
            listingId,
            msg.sender,
            l.boostExpiry,
            burnAmt,
            treasAmt
        );
    }

    // New: Profile Boost
    function buyProfileBoost(
        uint256 dopAmount
    ) external nonReentrant whenNotPaused {
        require(profiles[msg.sender].joinedAt != 0, "No profile");
        require(dopAmount >= profileBoostPriceDOP, "price");
        dopToken.transferFrom(msg.sender, address(this), dopAmount);
        (uint256 burnAmt, uint256 treasAmt) = _computeSplit(dopAmount);
        dopToken.burn(burnAmt);
        dopToken.transfer(treasury, treasAmt);
        uint256 base = profileBoostExpiry[msg.sender] > block.timestamp
            ? profileBoostExpiry[msg.sender]
            : block.timestamp;
        profileBoostExpiry[msg.sender] = base + profileBoostDuration;
        emit ProfileBoostPurchased(
            msg.sender,
            profileBoostExpiry[msg.sender],
            burnAmt,
            treasAmt
        );
    }

    // Offers
    function makeOffer(
        uint256 listingId,
        uint256 amount,
        address paymentToken
    ) external whenNotPaused returns (uint256 id) {
        Listing storage l = listings[listingId];
        require(l.id != 0 && l.active, "listing");
        require(amount > 0, "amt");
        id = ++_offerIdCounter;
        offers[id] = Offer(
            id,
            listingId,
            msg.sender,
            amount,
            paymentToken,
            block.timestamp,
            false,
            false
        );
        emit OfferMade(id, listingId, msg.sender, amount, paymentToken);
        // index listing -> offers
        _offersByListing[listingId].push(id);
    }

    function acceptOffer(
        uint256 offerId
    ) external payable nonReentrant whenNotPaused {
        Offer storage ofr = offers[offerId];
        Listing storage l = listings[ofr.listingId];
        require(ofr.id != 0 && !ofr.cancelled && !ofr.accepted, "offer");
        require(l.id != 0 && l.active, "listing");
        address client;
        address provider;
        if (l.listingType == ListingType.BRIEF) {
            require(msg.sender == l.creator, "client");
            // Prevent client accepting their own offer to self-escrow
            require(ofr.proposer != l.creator, "self");
            client = l.creator;
            provider = ofr.proposer;
        } else {
            require(msg.sender == l.creator, "prov");
            provider = l.creator;
            require(ofr.proposer != provider, "self");
            client = ofr.proposer;
        }
        ofr.accepted = true;
        emit OfferAccepted(offerId, client, provider);
        _startEscrow(ofr, client, provider);
    }

    // New: Cancel an offer before it is accepted
    function cancelOffer(uint256 offerId) external whenNotPaused {
        Offer storage ofr = offers[offerId];
        require(ofr.id != 0, "offer");
        require(msg.sender == ofr.proposer, "auth");
        require(!ofr.cancelled && !ofr.accepted, "state");
        ofr.cancelled = true;
        emit OfferCancelled(offerId, ofr.listingId, ofr.proposer);
    }

    function _startEscrow(
        Offer storage ofr,
        address client,
        address provider
    ) internal {
        require(escrows[ofr.id].status == EscrowStatus.NONE, "escrow");
        bool isDop = ofr.paymentToken == address(dopToken);
        uint256 feeBps = isDop ? feeDop : feeUsdLike;
        uint256 feeAmount = (ofr.amount * feeBps) / FEE_DENOMINATOR;
        require(feeAmount < ofr.amount, "fee");
        if (ofr.paymentToken == address(0))
            require(msg.value == ofr.amount, "value");
        else
            IERC20(ofr.paymentToken).safeTransferFrom(
                client,
                address(this),
                ofr.amount
            );
        escrows[ofr.id] = Escrow(
            ofr.id,
            client,
            provider,
            ofr.paymentToken,
            ofr.amount,
            feeAmount,
            EscrowStatus.IN_PROGRESS,
            false,
            false,
            DisputeOutcome.NONE
        );
        emit EscrowStarted(
            ofr.id,
            client,
            provider,
            ofr.amount,
            ofr.paymentToken,
            feeAmount
        );
    }

    // Validation
    function validateWork(
        uint256 offerId
    ) external nonReentrant onlyParticipant(offerId) {
        Escrow storage e = escrows[offerId];
        require(e.status == EscrowStatus.IN_PROGRESS, "status");
        if (msg.sender == e.client) e.clientValidated = true;
        else e.providerValidated = true;
        emit MissionValidated(
            offerId,
            msg.sender,
            e.clientValidated,
            e.providerValidated
        );
        if (e.clientValidated && e.providerValidated) _completeEscrow(e);
    }

    function _completeEscrow(Escrow storage e) internal {
        e.status = EscrowStatus.COMPLETED;
        uint256 providerPayout = e.amount - e.feeAmount;
        uint256 feeAmount = e.feeAmount;
        if (e.paymentToken == address(0)) {
            (bool ok, ) = e.provider.call{value: providerPayout}("");
            require(ok, "prov");
            if (feeAmount > 0) {
                (uint256 burnAmt, uint256 treasAmt) = _computeSplit(feeAmount);
                if (treasAmt > 0) {
                    (bool okT, ) = treasury.call{value: treasAmt}("");
                    require(okT, "treasury");
                }
                if (burnAmt > 0) {
                    _buyDopAndBurnFromETH(burnAmt);
                }
            }
        } else {
            IERC20 token = IERC20(e.paymentToken);
            token.safeTransfer(e.provider, providerPayout);
            if (e.paymentToken == address(dopToken)) _processDopFee(feeAmount);
            else if (feeAmount > 0) _processUsdFee(feeAmount, e.paymentToken);
        }

        // Record mission and update badges
        userMissions[e.client].push(
            Mission({
                escrowId: e.offerId,
                client: e.client,
                provider: e.provider,
                amount: e.amount,
                token: e.paymentToken,
                completedAt: block.timestamp,
                wasDisputed: false
            })
        );

        userMissions[e.provider].push(
            Mission({
                escrowId: e.offerId,
                client: e.client,
                provider: e.provider,
                amount: e.amount,
                token: e.paymentToken,
                completedAt: block.timestamp,
                wasDisputed: false
            })
        );

        _updateBadges(e.client);
        _updateBadges(e.provider);

        reputations[e.client].completedMissions += 1;
        reputations[e.client].score += uint128(e.amount);
        reputations[e.provider].completedMissions += 1;
        reputations[e.provider].score += uint128(e.amount);
        emit EscrowCompleted(e.offerId, providerPayout, feeAmount);
    }

    // Disputes
    function _openDisputeInternal(
        uint256 offerId,
        string memory cid,
        bool recordCID
    ) internal {
        Escrow storage e = escrows[offerId];
        require(e.status == EscrowStatus.IN_PROGRESS, "status");
        e.status = EscrowStatus.DISPUTED;
        // Log for pagination (append-only)
        _disputeLog.push(offerId);
        emit DisputeOpened(offerId);
        if (recordCID) {
            DisputeData storage d = _disputes[offerId];
            d.metadataCID = cid;
            d.openedBy = msg.sender;
            d.openedAt = block.timestamp;
            emit DisputeOpenedWithCID(offerId, cid, msg.sender);
        }
    }

    function openDispute(uint256 offerId) external onlyParticipant(offerId) {
        _openDisputeInternal(offerId, "", false);
    }

    function openDisputeWithCID(
        uint256 offerId,
        string calldata cid
    ) external onlyParticipant(offerId) {
        require(bytes(cid).length > 0, "cid");
        _openDisputeInternal(offerId, cid, true);
    }

    function appealDispute(
        uint256 offerId,
        string calldata cid
    ) external onlyParticipant(offerId) {
        Escrow storage e = escrows[offerId];
        require(e.status == EscrowStatus.DISPUTED, "status");
        require(bytes(cid).length > 0, "cid");
        // Only counterparty can appeal (not the party who opened)
        address opener = _disputes[offerId].openedBy;
        require(opener != address(0), "no-dispute");
        require(msg.sender != opener, "counterparty");
        _disputes[offerId].appeals.push(
            Appeal({by: msg.sender, cid: cid, timestamp: block.timestamp})
        );
        emit DisputeAppealed(offerId, cid, msg.sender);
    }

    function resolveDispute(
        uint256 offerId,
        DisputeOutcome outcome
    ) external onlyOwner nonReentrant {
        Escrow storage e = escrows[offerId];
        require(e.status == EscrowStatus.DISPUTED, "status");
        require(outcome != DisputeOutcome.NONE, "outcome");
        e.status = EscrowStatus.RESOLVED;
        e.disputeOutcome = outcome;
        uint256 providerAmount;
        uint256 clientAmount;
        uint256 feeAmount = e.feeAmount;
        uint256 workAmount = e.amount - feeAmount;
        if (outcome == DisputeOutcome.REFUND_CLIENT) {
            clientAmount = e.amount;
            feeAmount = 0;
        } else if (outcome == DisputeOutcome.SPLIT) {
            providerAmount = workAmount / 2;
            clientAmount = e.amount - providerAmount - feeAmount;
        } else {
            providerAmount = workAmount;
        }
        if (e.paymentToken == address(0)) {
            if (providerAmount > 0) {
                (bool ok, ) = e.provider.call{value: providerAmount}("");
                require(ok, "prov");
            }
            if (clientAmount > 0) {
                (bool ok2, ) = e.client.call{value: clientAmount}("");
                require(ok2, "client");
            }
            if (feeAmount > 0) {
                (uint256 burnAmt, uint256 treasAmt) = _computeSplit(feeAmount);
                if (treasAmt > 0) {
                    (bool ok3, ) = treasury.call{value: treasAmt}("");
                    require(ok3, "treasury");
                }
                if (burnAmt > 0) {
                    _buyDopAndBurnFromETH(burnAmt);
                }
            }
        } else {
            IERC20 token = IERC20(e.paymentToken);
            if (providerAmount > 0)
                token.safeTransfer(e.provider, providerAmount);
            if (clientAmount > 0) token.safeTransfer(e.client, clientAmount);
            if (feeAmount > 0) {
                if (e.paymentToken == address(dopToken))
                    _processDopFee(feeAmount);
                else _processUsdFee(feeAmount, e.paymentToken);
            }
        }

        // Record disputed mission
        userMissions[e.client].push(
            Mission({
                escrowId: offerId,
                client: e.client,
                provider: e.provider,
                amount: e.amount,
                token: e.paymentToken,
                completedAt: block.timestamp,
                wasDisputed: true
            })
        );

        userMissions[e.provider].push(
            Mission({
                escrowId: offerId,
                client: e.client,
                provider: e.provider,
                amount: e.amount,
                token: e.paymentToken,
                completedAt: block.timestamp,
                wasDisputed: true
            })
        );

        _updateBadges(e.client);
        _updateBadges(e.provider);

        reputations[e.client].disputedMissions += 1;
        reputations[e.provider].disputedMissions += 1;
        emit DisputeResolved(offerId, outcome, providerAmount, clientAmount);
    }

    // New: Reviews API
    function leaveReview(
        uint256 offerId,
        uint8 rating,
        string calldata reviewURI
    ) external onlyParticipant(offerId) whenNotPaused {
        require(rating >= 1 && rating <= 5, "rating");
        Escrow storage e = escrows[offerId];
        require(
            e.status == EscrowStatus.COMPLETED ||
                e.status == EscrowStatus.RESOLVED,
            "status"
        );
        require(!hasReviewed[offerId][msg.sender], "done");
        address reviewee = msg.sender == e.client ? e.provider : e.client;
        hasReviewed[offerId][msg.sender] = true;
        reviewsReceived[reviewee].push(
            Review({
                offerId: offerId,
                reviewer: msg.sender,
                reviewee: reviewee,
                rating: rating,
                reviewURI: reviewURI,
                timestamp: block.timestamp
            })
        );
        reputations[reviewee].ratingsCount += 1;
        reputations[reviewee].ratingsSum += rating;
        emit ReviewSubmitted(offerId, msg.sender, reviewee, rating, reviewURI);
    }

    function getReviews(address user) external view returns (Review[] memory) {
        return reviewsReceived[user];
    }

    function getAverageRating(
        address user
    ) external view returns (uint256 avgTimes100) {
        Reputation memory rep = reputations[user];
        if (rep.ratingsCount == 0) return 0;
        // average * 100 for two-decimal precision
        avgTimes100 =
            (uint256(rep.ratingsSum) * 100) /
            uint256(rep.ratingsCount);
    }

    // Admin
    function setFees(uint256 _feeUsdLike, uint256 _feeDop) external onlyOwner {
        require(_feeUsdLike <= 3_000 && _feeDop <= 2_000, "caps");
        feeUsdLike = _feeUsdLike;
        feeDop = _feeDop;
    }

    function setBoostParams(
        uint256 _price,
        uint256 _duration
    ) external onlyOwner {
        require(_duration >= 1 days && _duration <= 30 days, "dur");
        boostPriceDOP = _price;
        boostDuration = _duration;
    }

    // New: Profile boost params
    function setProfileBoostParams(
        uint256 _price,
        uint256 _duration
    ) external onlyOwner {
        require(_duration >= 1 days && _duration <= 30 days, "dur");
        profileBoostPriceDOP = _price;
        profileBoostDuration = _duration;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero");
        treasury = _treasury;
    }

    // Update both DOP (burn token) and optional USDC token
    function setTokens(address _dop, address _usdc) external onlyOwner {
        require(_dop != address(0), "zero");
        dopToken = IDOPToken(_dop);
        usdcToken = IERC20(_usdc);
        emit TokensUpdated(_dop, _usdc);
    }

    function setDexRouter(
        address _dexRouter,
        address _weth
    ) external onlyOwner {
        dexRouter = _dexRouter;
        weth = _weth;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // New: Full profile getter
    function getProfile(
        address user
    )
        external
        view
        returns (
            string memory bio,
            string[] memory skills,
            string[] memory portfolioURIs,
            uint256 joinedAt,
            UserType userType,
            bool isVerified
        )
    {
        UserProfile storage p = profiles[user];
        return (
            p.bio,
            p.skills,
            p.portfolioURIs,
            p.joinedAt,
            p.userType,
            p.isVerified
        );
    }

    // Views
    function isBoosted(uint256 listingId) external view returns (bool) {
        return listings[listingId].boostExpiry >= block.timestamp;
    }

    // New: profile boost view
    function isProfileBoosted(address user) external view returns (bool) {
        return profileBoostExpiry[user] >= block.timestamp;
    }

    function getEscrow(uint256 offerId) external view returns (Escrow memory) {
        return escrows[offerId];
    }

    // New: Frontend helpers
    function lastListingId() external view returns (uint256) {
        return _listingIdCounter;
    }

    function lastOfferId() external view returns (uint256) {
        return _offerIdCounter;
    }

    function getListingsBatch(
        uint256[] calldata ids
    ) external view returns (Listing[] memory out) {
        out = new Listing[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            out[i] = listings[ids[i]];
        }
    }

    function getListingsDescending(
        uint256 startId,
        uint256 limit,
        bool onlyActive,
        bool onlyBoosted,
        bool filterByType,
        ListingType listingType
    )
        external
        view
        returns (Listing[] memory page, uint256 nextCursor, uint256 count)
    {
        if (limit == 0) return (new Listing[](0), 0, 0);
        uint256 cursor = startId == 0 || startId > _listingIdCounter
            ? _listingIdCounter
            : startId;
        Listing[] memory tmp = new Listing[](limit);
        uint256 collected = 0;
        while (cursor > 0 && collected < limit) {
            Listing memory l = listings[cursor];
            if (
                l.id != 0 &&
                (!onlyActive || l.active) &&
                (!onlyBoosted || l.boostExpiry >= block.timestamp) &&
                (!filterByType || l.listingType == listingType)
            ) {
                tmp[collected] = l;
                collected++;
            }
            cursor--;
        }
        // shrink to actual size
        page = new Listing[](collected);
        for (uint256 i = 0; i < collected; i++) {
            page[i] = tmp[i];
        }
        nextCursor = cursor; // 0 if we reached the beginning
        count = collected;
    }

    function getListingsByCreator(
        address creator,
        uint256 offset,
        uint256 limit
    ) external view returns (Listing[] memory page, uint256 returned) {
        if (limit == 0) return (new Listing[](0), 0);
        uint256 cursor = _listingIdCounter;
        Listing[] memory tmp = new Listing[](limit);
        uint256 skipped = 0;
        uint256 collected = 0;
        while (cursor > 0 && collected < limit) {
            Listing memory l = listings[cursor];
            if (l.id != 0 && l.creator == creator) {
                if (skipped < offset) {
                    skipped++;
                } else {
                    tmp[collected] = l;
                    collected++;
                }
            }
            cursor--;
        }
        page = new Listing[](collected);
        for (uint256 i = 0; i < collected; i++) {
            page[i] = tmp[i];
        }
        returned = collected;
    }

    function getOffersForListing(
        uint256 listingId,
        uint256 offset,
        uint256 limit
    ) external view returns (Offer[] memory page, uint256 returned) {
        if (limit == 0) return (new Offer[](0), 0);
        uint256 cursor = _offerIdCounter;
        Offer[] memory tmp = new Offer[](limit);
        uint256 skipped = 0;
        uint256 collected = 0;
        while (cursor > 0 && collected < limit) {
            Offer memory ofr = offers[cursor];
            if (ofr.id != 0 && ofr.listingId == listingId) {
                if (skipped < offset) {
                    skipped++;
                } else {
                    tmp[collected] = ofr;
                    collected++;
                }
            }
            cursor--;
        }
        page = new Offer[](collected);
        for (uint256 i = 0; i < collected; i++) {
            page[i] = tmp[i];
        }
        returned = collected;
    }

    // New: Dispute views
    function getDisputeHeader(
        uint256 offerId
    )
        external
        view
        returns (
            string memory cid,
            address openedBy,
            uint256 openedAt,
            uint256 appealsCount
        )
    {
        DisputeData storage d = _disputes[offerId];
        return (d.metadataCID, d.openedBy, d.openedAt, d.appeals.length);
    }

    function getDisputeAppeal(
        uint256 offerId,
        uint256 index
    ) external view returns (address by, string memory cid, uint256 timestamp) {
        Appeal storage a = _disputes[offerId].appeals[index];
        return (a.by, a.cid, a.timestamp);
    }

    // Returns a descending page of offerIds that had disputes opened (may include resolved ones)
    function getDisputedOffers(
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory page, uint256 returned) {
        uint256 n = _disputeLog.length;
        if (offset >= n || limit == 0) {
            return (new uint256[](0), 0);
        }
        // We page from the end (most recent first)
        uint256 endExclusive = n - offset; // exclusive
        uint256 start = endExclusive > limit ? endExclusive - limit : 0;
        uint256 count = endExclusive - start;
        page = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = _disputeLog[start + i];
        }
        returned = count;
    }

    receive() external payable {}
}
