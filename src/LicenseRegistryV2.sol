// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface IBuildNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function creatorOf(uint256 tokenId) external view returns (address);
    function geometryOf(uint256 tokenId) external view returns (bytes32);
    function isActive(uint256 tokenId) external view returns (bool);
    function massOf(uint256 tokenId) external view returns (uint256);
    function isBurned(uint256 tokenId) external view returns (bool);
}

interface ILicenseNFT {
    function setMaxSupply(uint256 id, uint256 max) external;
    function mint(address to, uint256 id, uint256 qty) external;
    function totalSupply(uint256 id) external view returns (uint256);
    function maxSupply(uint256 id) external view returns (uint256);
}

/// @title LicenseRegistryV2 — continuous bonding-curve license pricing
/// @notice Replaces the tiered pricing model with a continuous formula:
///
///   maxSupply  = SUPPLY_FACTOR / mass          (default 100M)
///   startPrice = START_K / maxSupply            (proportional to mass)
///   maxPrice   = MAX_RATIO × startPrice         (default 20×)
///   step       = (maxPrice − startPrice) / (maxSupply − 1)
///
///   With defaults: 1×1 brick (mass=1) → supply=100M, start=0.00005 ETH
///                  2×3 brick (mass=6) → supply=16.7M, start=0.0003 ETH (6× higher)
///
///   Pricing constants are owner-adjustable so the curve can be tuned post-deploy.
contract LicenseRegistryV2 is Ownable {
    struct Pricing {
        uint256 startPrice;
        uint256 step;
        uint256 maxSupply;
        uint256 maxPrice;
    }

    // ── Pricing constants (owner-adjustable) ──
    uint256 public supplyFactor = 100_000_000;       // maxSupply = supplyFactor / mass
    uint256 public startK = 5_000 ether;             // startPrice = startK / maxSupply
    uint256 public maxRatio = 20;                    // maxPrice = maxRatio × startPrice

    // ── Core state ──
    address public buildNFT;
    address public licenseNFT;
    address public treasury;

    // ── LP rebalance state ──
    uint256 public lpBudgetBalance;
    uint256 public minRebalanceInterval;
    uint256 public minLpBudgetAmount;
    uint256 public maxSlippageBps;
    uint256 public maxDeadlineWindow;
    uint256 public lastRebalanceAt;
    mapping(address => bool) public keepers;
    mapping(address => bool) public routerWhitelist;

    // ── License state ──
    uint256 public nextLicenseId = 1;
    mapping(uint256 => uint256) public licenseIdForBuild;
    mapping(uint256 => uint256) public buildIdForLicense;
    mapping(uint256 => Pricing) public pricingForLicense;

    // ── Events ──
    event TreasurySet(address indexed treasury);
    event KeeperSet(address indexed keeper, bool allowed);
    event RouterWhitelistSet(address indexed router, bool allowed);
    event RebalanceGuardsSet(uint256 minRebalanceInterval, uint256 minLpBudgetAmount, uint256 maxSlippageBps, uint256 maxDeadlineWindow);
    event RebalanceExecuted(address indexed keeper, address indexed router, uint256 amount, bool ok);
    event PricingParamsSet(uint256 supplyFactor, uint256 startK, uint256 maxRatio);
    event BuildRegistered(uint256 indexed buildId, uint256 indexed licenseId, uint256 maxSupply, uint256 startPrice, uint256 step);
    event LicenseMinted(uint256 indexed licenseId, address indexed buyer, uint256 qty, uint256 price);

    constructor(address buildNFT_, address licenseNFT_, address treasury_)
        Ownable(msg.sender)
    {
        require(buildNFT_ != address(0), "buildNFT=0");
        require(licenseNFT_ != address(0), "licenseNFT=0");
        require(treasury_ != address(0), "treasury=0");

        buildNFT = buildNFT_;
        licenseNFT = licenseNFT_;
        treasury = treasury_;
        keepers[msg.sender] = true;
        minRebalanceInterval = 1 hours;
        maxSlippageBps = 1_000;
        maxDeadlineWindow = 30 minutes;

        emit TreasurySet(treasury_);
        emit KeeperSet(msg.sender, true);
    }

    receive() external payable {}

    // ══════════════════════════════════
    // Owner admin
    // ══════════════════════════════════

    function setPricingParams(uint256 supplyFactor_, uint256 startK_, uint256 maxRatio_) external onlyOwner {
        require(supplyFactor_ > 0, "supplyFactor=0");
        require(startK_ > 0, "startK=0");
        require(maxRatio_ > 1, "maxRatio<=1");
        supplyFactor = supplyFactor_;
        startK = startK_;
        maxRatio = maxRatio_;
        emit PricingParamsSet(supplyFactor_, startK_, maxRatio_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        require(keeper != address(0), "keeper=0");
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setRouterWhitelist(address router, bool allowed) external onlyOwner {
        require(router != address(0), "router=0");
        routerWhitelist[router] = allowed;
        emit RouterWhitelistSet(router, allowed);
    }

    function setRebalanceGuards(
        uint256 minRebalanceInterval_,
        uint256 minLpBudgetAmount_,
        uint256 maxSlippageBps_,
        uint256 maxDeadlineWindow_
    ) external onlyOwner {
        require(maxSlippageBps_ <= 10_000, "slippage");
        require(maxDeadlineWindow_ > 0, "deadline");
        minRebalanceInterval = minRebalanceInterval_;
        minLpBudgetAmount = minLpBudgetAmount_;
        maxSlippageBps = maxSlippageBps_;
        maxDeadlineWindow = maxDeadlineWindow_;
        emit RebalanceGuardsSet(minRebalanceInterval_, minLpBudgetAmount_, maxSlippageBps_, maxDeadlineWindow_);
    }

    // ══════════════════════════════════
    // LP rebalance
    // ══════════════════════════════════

    function topUpLpBudget() external payable {
        lpBudgetBalance += msg.value;
    }

    function executeRebalance(
        address router,
        uint256 amount,
        uint256 slippageBps,
        uint256 deadline,
        bytes calldata data
    ) external returns (bool ok, bytes memory result) {
        require(keepers[msg.sender], "keeper");
        require(routerWhitelist[router], "router");
        require(block.timestamp >= lastRebalanceAt + minRebalanceInterval, "interval");
        require(amount >= minLpBudgetAmount, "threshold");
        require(amount <= lpBudgetBalance, "lp budget");
        require(slippageBps <= maxSlippageBps, "slippage");
        require(deadline >= block.timestamp && deadline <= block.timestamp + maxDeadlineWindow, "deadline");

        lpBudgetBalance -= amount;
        (ok, result) = router.call{value: amount}(data);
        if (ok) {
            lastRebalanceAt = block.timestamp;
        } else {
            lpBudgetBalance += amount;
        }
        emit RebalanceExecuted(msg.sender, router, amount, ok);
    }

    // ══════════════════════════════════
    // License minting
    // ══════════════════════════════════

    function registerBuild(uint256 buildId, bytes32 expectedGeometryHash) external {
        require(licenseIdForBuild[buildId] == 0, "already registered");
        require(IBuildNFT(buildNFT).geometryOf(buildId) == expectedGeometryHash, "geometry mismatch");
        _registerBuild(buildId);
    }

    function quote(uint256 buildId, uint256 qty) external view returns (uint256) {
        uint256 licenseId = licenseIdForBuild[buildId];
        if (licenseId != 0) {
            return _quoteForLicense(licenseId, qty);
        }
        (Pricing memory pricing,) = _pricingForBuild(buildId);
        return _quoteFromPricing(pricing, _initialSoldForBuild(buildId), qty);
    }

    function mintLicenseForBuild(uint256 buildId, uint256 qty) external payable {
        uint256 licenseId = licenseIdForBuild[buildId];
        if (licenseId == 0) {
            licenseId = _registerBuild(buildId);
        } else {
            require(!IBuildNFT(buildNFT).isBurned(buildId), "build burned");
            require(IBuildNFT(buildNFT).isActive(buildId), "inactive build");
        }

        uint256 price = _quoteForLicense(licenseId, qty);
        require(msg.value >= price, "insufficient ETH");

        _payETH(treasury, price);
        uint256 excess = msg.value - price;
        if (excess > 0) _payETH(msg.sender, excess);

        uint256 mintedSoFar = ILicenseNFT(licenseNFT).totalSupply(licenseId);
        uint256 cap = ILicenseNFT(licenseNFT).maxSupply(licenseId);
        require(cap > 0, "max=0");
        require(mintedSoFar + qty <= cap, "max exceeded");

        ILicenseNFT(licenseNFT).mint(msg.sender, licenseId, qty);
        emit LicenseMinted(licenseId, msg.sender, qty, price);
    }

    /// @notice Mint license directly to `recipient`, paid in ETH by BuildNFT.
    ///         Only callable by BuildNFT.
    function mintLicenseOnBehalfOf(uint256 buildId, uint256 qty, address recipient)
        external
        payable
        returns (uint256 licenseId, uint256 price)
    {
        require(msg.sender == buildNFT, "only buildNFT");

        licenseId = licenseIdForBuild[buildId];
        if (licenseId == 0) {
            licenseId = _registerBuild(buildId);
        } else {
            require(!IBuildNFT(buildNFT).isBurned(buildId), "build burned");
            require(IBuildNFT(buildNFT).isActive(buildId), "inactive build");
        }

        price = _quoteForLicense(licenseId, qty);
        require(msg.value >= price, "insufficient ETH");

        if (price > 0) _payETH(treasury, price);
        uint256 excess = msg.value - price;
        if (excess > 0) _payETH(msg.sender, excess);

        uint256 mintedSoFar = ILicenseNFT(licenseNFT).totalSupply(licenseId);
        uint256 cap = ILicenseNFT(licenseNFT).maxSupply(licenseId);
        require(cap > 0, "max=0");
        require(mintedSoFar + qty <= cap, "max exceeded");

        ILicenseNFT(licenseNFT).mint(recipient, licenseId, qty);
        emit LicenseMinted(licenseId, recipient, qty, price);
    }

    // ══════════════════════════════════
    // Internal — pricing
    // ══════════════════════════════════

    function _payETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function _registerBuild(uint256 buildId) internal returns (uint256 licenseId) {
        require(licenseIdForBuild[buildId] == 0, "already registered");
        (Pricing memory pricing, uint256 max) = _pricingForBuild(buildId);

        licenseId = nextLicenseId++;
        licenseIdForBuild[buildId] = licenseId;
        buildIdForLicense[licenseId] = buildId;
        pricingForLicense[licenseId] = pricing;

        ILicenseNFT(licenseNFT).setMaxSupply(licenseId, max);
        address creator = IBuildNFT(buildNFT).creatorOf(buildId);
        if (creator != address(0)) {
            ILicenseNFT(licenseNFT).mint(creator, licenseId, 1);
        }

        emit BuildRegistered(buildId, licenseId, max, pricing.startPrice, pricing.step);
    }

    function _quoteForLicense(uint256 licenseId, uint256 qty) internal view returns (uint256) {
        Pricing memory pricing = pricingForLicense[licenseId];
        require(pricing.maxSupply > 0, "pricing=0");
        uint256 sold = ILicenseNFT(licenseNFT).totalSupply(licenseId);
        return _quoteFromPricing(pricing, sold, qty);
    }

    function _quoteFromPricing(Pricing memory pricing, uint256 sold, uint256 qty)
        internal
        pure
        returns (uint256)
    {
        require(qty > 0, "qty=0");
        require(sold + qty <= pricing.maxSupply, "max exceeded");

        uint256 start = pricing.startPrice + (sold * pricing.step);
        uint256 nMinusOne = qty - 1;
        uint256 series = (start * 2 + (nMinusOne * pricing.step)) * qty;
        return series / 2;
    }

    /// @dev Continuous pricing: startPrice = startK / maxSupply, maxPrice = maxRatio × startPrice.
    ///      No tiers — price scales linearly with 1/supply (i.e. linearly with mass).
    function _pricingForBuild(uint256 buildId)
        internal
        view
        returns (Pricing memory pricing, uint256 max)
    {
        require(!IBuildNFT(buildNFT).isBurned(buildId), "build burned");
        require(IBuildNFT(buildNFT).isActive(buildId), "inactive build");
        IBuildNFT(buildNFT).ownerOf(buildId);

        uint256 mass = IBuildNFT(buildNFT).massOf(buildId);
        require(mass > 0, "mass=0");
        max = supplyFactor / mass;
        require(max > 0, "max=0");

        uint256 startPriceWei = startK / max;
        uint256 maxPriceWei = maxRatio * startPriceWei;
        uint256 stepWei = max > 1 ? (maxPriceWei - startPriceWei) / (max - 1) : 0;

        pricing = Pricing({
            startPrice: startPriceWei,
            step: stepWei,
            maxSupply: max,
            maxPrice: maxPriceWei
        });
    }

    function _initialSoldForBuild(uint256 buildId) internal view returns (uint256) {
        return IBuildNFT(buildNFT).creatorOf(buildId) == address(0) ? 0 : 1;
    }
}
