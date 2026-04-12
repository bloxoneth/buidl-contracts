// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {
    ERC1155Holder
} from "openzeppelin-contracts/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";

interface IGeometryRegistry {
    function store(uint256 tokenId, bytes32 hash, bytes calldata data) external;
    function consumeHash(bytes32 hash) external;
    function hashConsumed(bytes32 hash) external view returns (bool);
    function repaint(uint256 tokenId, bytes calldata newData) external;
    function geometryData(uint256 tokenId) external view returns (bytes memory);
}

interface IBUIDLRenderer {
    function renderSVG(bytes calldata geometryData) external view returns (string memory);
    function render3DHTML(uint256 tokenId, bytes calldata geometryData)
        external
        view
        returns (string memory);
    function rendererPointer() external view returns (address);
}

interface IDistributor {
    function accrueFromComposition(
        uint256[] calldata buildIds,
        uint256[] calldata counts,
        address payer,
        uint256 buildMass,
        uint256 buildDensity
    ) external payable;
}

interface ILicenseRegistry {
    function licenseIdForBuild(uint256 buildId) external view returns (uint256);
    function quote(uint256 buildId, uint256 qty) external view returns (uint256);
    /// @notice Mint license directly to `recipient`, paid in ETH.
    ///         Auto-registers the build if not yet registered.
    function mintLicenseOnBehalfOf(uint256 buildId, uint256 qty, address recipient)
        external
        payable
        returns (uint256 licenseId, uint256 price);
}

/// @notice Single ERC721 for both "bricks" and "builds" in MVP.
/// Locks BLOX on mint. Burn recycles 10% to Distributor, routes 5% to LP, and returns 85% to owner.
/// kind=0 is brick; kind>0 is build. Build geometry is consumed forever.
contract BuildNFT is ERC721, Ownable, ReentrancyGuard, ERC1155Holder, EIP712 {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    struct BrickSpec {
        uint8 width;
        uint8 depth;
        uint16 density;
    }

    struct PlacedComponent {
        uint256 licenseTokenId; // ERC-1155 token ID (from LicenseRegistry)
        uint8 rotation; // 0-23 valid orientations
        uint8 x; // placement coordinate
        uint8 y;
        uint8 z;
        uint8 colourIndex; // 1-7, assigned by builder
        uint8 useMode; // 0=COMPONENT (recolour), 1=COLLECTIBLE (preserve)
    }

    struct MintParams {
        bytes32 geometryHash;
        uint256 mass;
        bytes geometryData; // raw 3-bit voxel bytes
        uint8 kind;
        uint8 width;
        uint8 depth;
        uint16 density;
    }

    struct MintReservation {
        address author;
        address reservedFor;
        bytes32 geometryHash;
        uint256 mass;
        bytes32 uriHash;
        bytes32 componentBuildIdsHash;
        bytes32 componentCountsHash;
        uint8 kind;
        uint8 width;
        uint8 depth;
        uint16 density;
        uint256 nonce;
        uint256 expiry;
    }

    // ==============================
    // Events
    // ==============================

    event BuildMinted(
        uint256 indexed tokenId,
        address indexed creator,
        uint256 mass,
        bytes32 indexed geometryHash,
        string tokenURI
    );

    event BuildBurned(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 mass,
        bytes32 indexed geometryHash,
        uint256 lockedBloxAmount,
        uint256 returnedToOwner,
        uint256 recycledToDistributor
    );

    // ==============================
    // Constants
    // ==============================

    uint256 public constant FEE_PER_MINT = 0.001 ether;
    uint256 public constant BURN_FEE = FEE_PER_MINT / 2;
    uint256 public constant BLOX_PER_MASS = 1e18;
    uint256 public constant RESERVATION_MAX_TTL = 7 days;
    uint16 public constant FIXED_DENSITY = 1;
    uint256 public constant MAX_COMPONENT_TYPES = 32;
    uint8 public constant KIND_BRICK = 0;
    uint8 public constant KIND_BUILD = 1;
    uint8 public constant KIND_COLLECTOR = 2;

    // ==============================
    // External addresses
    // ==============================

    IERC20 public immutable blox;

    string public baseTokenURI;
    string public baseImageURI; // e.g. "https://buidl.app/api/builds/svg" → image = baseImageURI/tokenId
    address public displayController; // DAO multisig — can update visual/display settings after ownership is renounced

    address public distributor;
    address public liquidityReceiver;
    address public protocolTreasury;
    address public licenseRegistry;
    address public licenseNFT;
    address public geometryRegistry;
    address public renderer;

    // ==============================
    // Config / state
    // ==============================

    uint256 public maxMass;
    uint256 public nextTokenId = 1;

    mapping(uint256 => uint256) public massOf;
    mapping(uint256 => bytes32) public geometryOf;
    mapping(uint256 => uint256) public lockedBloxOf;
    mapping(uint256 => address) public creatorOf;
    mapping(uint256 => uint8) public kindOf;
    mapping(uint256 => uint16) public densityOf;
    mapping(uint256 => uint256) public bwAnchorOf;
    mapping(uint256 => BrickSpec) public brickSpecOf;
    mapping(uint256 => bytes32) public brickSpecKeyOf;
    mapping(bytes32 => bool) public brickSpecConsumed;
    // kind IDs 1000+ are reserved for ecosystem/third-party categories (policy only).
    mapping(uint16 => bool) public kindEnabled;

    event KindEnabled(uint16 indexed kind, bool enabled);
    event ReservationConsumed(bytes32 indexed reservationDigest, address indexed author, address indexed minter);
    event FeeSplitSet(uint16 ownersBps, uint16 liquidityBps, uint16 treasuryBps);
    event FeeSplitFrozen();

    mapping(uint256 => uint256[]) private escrowedLicenseIds;
    mapping(uint256 => mapping(uint256 => uint256)) public escrowedLicenseQty;
    mapping(uint256 => PlacedComponent[]) public manifestOf;
    mapping(uint256 => bool) public burned;
    mapping(bytes32 => bool) public reservationConsumed;
    uint16 public ownersBps;
    uint16 public liquidityBps;
    uint16 public treasuryBps;
    bool public feeSplitFrozen;

    bytes32 public constant MINT_RESERVATION_TYPEHASH = keccak256(
        "MintReservation(address author,address reservedFor,bytes32 geometryHash,uint256 mass,bytes32 uriHash,bytes32 componentBuildIdsHash,bytes32 componentCountsHash,uint8 kind,uint8 width,uint8 depth,uint16 density,uint256 nonce,uint256 expiry)"
    );

    // ==============================
    // Constructor
    // ==============================

    constructor(
        address blox_,
        address distributor_,
        address liquidityReceiver_,
        address protocolTreasury_,
        address licenseRegistry_,
        address licenseNFT_,
        uint256 maxMass_
    ) ERC721("BUIDL Build", "BUILD") Ownable(msg.sender) EIP712("BUIDL Build", "1") {
        require(blox_ != address(0), "BLOX=0");
        require(distributor_ != address(0), "distributor=0");
        require(liquidityReceiver_ != address(0), "liquidity=0");
        require(protocolTreasury_ != address(0), "treasury=0");
        require(licenseRegistry_ != address(0), "licenseRegistry=0");
        require(licenseNFT_ != address(0), "licenseNFT=0");
        require(maxMass_ > 0, "maxMass=0");
        blox = IERC20(blox_);
        distributor = distributor_;
        liquidityReceiver = liquidityReceiver_;
        protocolTreasury = protocolTreasury_;
        licenseRegistry = licenseRegistry_;
        licenseNFT = licenseNFT_;
        maxMass = maxMass_;
        ownersBps = 3_000;
        liquidityBps = 4_000;
        treasuryBps = 3_000;
        emit FeeSplitSet(ownersBps, liquidityBps, treasuryBps);
        // kind 0 is reserved for bricks and is always allowed.
    }

    // ==============================
    // Mint
    // ==============================

    function mint(
        bytes32 geometryHash,
        uint256 mass,
        bytes calldata geometryData,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        PlacedComponent[] calldata manifest,
        uint8 kind,
        uint8 width,
        uint8 depth,
        uint16 density
    ) external payable nonReentrant returns (uint256 tokenId) {
        MintParams memory p = MintParams({
            geometryHash: geometryHash,
            mass: mass,
            geometryData: geometryData,
            kind: kind,
            width: width,
            depth: depth,
            density: density
        });

        tokenId = _mintCore(p, componentBuildIds, componentCounts, msg.sender, msg.sender);

        // Store manifest on-chain for provenance tracing
        for (uint256 i = 0; i < manifest.length; i++) {
            manifestOf[tokenId].push(manifest[i]);
        }

        _splitFee(FEE_PER_MINT, componentBuildIds, componentCounts, msg.sender, p.mass, 1);

        emit BuildMinted(tokenId, msg.sender, p.mass, geometryOf[tokenId], "");
    }

    function mintWithReservation(
        MintReservation calldata reservation,
        string calldata uri,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        bytes calldata signature
    ) external payable nonReentrant returns (uint256 tokenId) {
        require(reservation.author != address(0), "author=0");
        require(block.timestamp <= reservation.expiry, "reservation expired");
        require(reservation.expiry - block.timestamp <= RESERVATION_MAX_TTL, "reservation ttl");
        if (reservation.reservedFor != address(0)) {
            require(reservation.reservedFor == msg.sender, "wrong minter");
        }
        require(reservation.uriHash == keccak256(bytes(uri)), "uri hash");
        require(
            reservation.componentBuildIdsHash == keccak256(abi.encode(componentBuildIds)),
            "component ids hash"
        );
        require(
            reservation.componentCountsHash == keccak256(abi.encode(componentCounts)),
            "component counts hash"
        );

        bytes32 digest = reservationDigest(reservation);
        require(!reservationConsumed[digest], "reservation used");
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == reservation.author, "bad reservation sig");
        reservationConsumed[digest] = true;

        tokenId = _mintReserved(reservation, uri, componentBuildIds, componentCounts);

        emit ReservationConsumed(digest, reservation.author, msg.sender);
        emit BuildMinted(tokenId, reservation.author, reservation.mass, geometryOf[tokenId], uri);
    }

    function _mintCore(
        MintParams memory p,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        address payer,
        address creator
    ) internal returns (uint256 tokenId) {
        require(msg.value >= FEE_PER_MINT, "bad fee");
        if (p.kind > 0) require(kindEnabled[uint16(p.kind)], "kind disabled");
        require(p.mass > 0, "mass=0");
        require(p.mass <= maxMass, "mass>max");
        require(componentBuildIds.length <= MAX_COMPONENT_TYPES, "too many components");
        require(componentBuildIds.length == componentCounts.length, "component mismatch");
        require(p.geometryHash != bytes32(0), "geometry=0");
        if (p.kind == KIND_BRICK) {
            require(p.width > 0 && p.width <= 10, "width");
            require(p.depth > 0 && p.depth <= 10, "depth");
        } else {
            require(p.width == 0 && p.depth == 0, "non-brick dims");
            if (p.kind != KIND_COLLECTOR) {
                require(
                    !IGeometryRegistry(geometryRegistry).hashConsumed(p.geometryHash),
                    "geometry consumed"
                );
            }
        }
        _validateCompositionRules(p, componentBuildIds, componentCounts);

        tokenId = nextTokenId++;
        if (p.kind == KIND_BRICK) {
            bytes32 specKey = _brickSpecKey(p.width, p.depth, p.geometryHash);
            require(!brickSpecConsumed[specKey], "brick spec used");
            brickSpecConsumed[specKey] = true;
        }

        uint256 licenseCost = _handleComponents(tokenId, componentBuildIds, componentCounts);
        require(msg.value >= FEE_PER_MINT + licenseCost, "insufficient ETH for licenses");
        _lockBlox(payer, tokenId, p.mass);

        massOf[tokenId] = p.mass;
        geometryOf[tokenId] = p.geometryHash;
        creatorOf[tokenId] = creator;
        kindOf[tokenId] = p.kind;
        densityOf[tokenId] = FIXED_DENSITY;
        bwAnchorOf[tokenId] =
            p.kind == KIND_COLLECTOR && componentBuildIds.length == 1 ? componentBuildIds[0] : tokenId;
        if (p.kind == KIND_BRICK) {
            brickSpecOf[tokenId] = BrickSpec({width: p.width, depth: p.depth, density: FIXED_DENSITY});
            brickSpecKeyOf[tokenId] = _brickSpecKey(p.width, p.depth, p.geometryHash);
        }

        _safeMint(payer, tokenId);

        // Store geometry on-chain via GeometryRegistry (not for collectors — they reuse master hash)
        if (p.kind != KIND_COLLECTOR) {
            if (p.geometryData.length > 0) {
                IGeometryRegistry(geometryRegistry).store(tokenId, p.geometryHash, p.geometryData);
            } else {
                IGeometryRegistry(geometryRegistry).consumeHash(p.geometryHash);
            }
        }
    }

    function _mintReserved(
        MintReservation calldata reservation,
        string calldata uri,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts
    ) internal returns (uint256 tokenId) {
        MintParams memory p = MintParams({
            geometryHash: reservation.geometryHash,
            mass: reservation.mass,
            geometryData: "", // reservations don't carry geometry data inline
            kind: reservation.kind,
            width: reservation.width,
            depth: reservation.depth,
            density: reservation.density
        });
        tokenId = _mintCore(p, componentBuildIds, componentCounts, msg.sender, reservation.author);
        _splitReservedFee(componentBuildIds, componentCounts, reservation);
    }

    function _splitReservedFee(
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        MintReservation calldata reservation
    ) internal {
        _splitFee(
            FEE_PER_MINT,
            componentBuildIds,
            componentCounts,
            msg.sender,
            reservation.mass,
            reservation.density
        );
    }

    // ==============================
    // Burn
    // ==============================

    function burn(uint256 tokenId) external payable nonReentrant {
        // ownerOf() reverts if token doesn't exist
        address owner = ownerOf(tokenId);
        require(kindOf[tokenId] != KIND_BRICK, "brick");
        require(msg.value == BURN_FEE, "bad burn fee");

        require(
            msg.sender == owner || getApproved(tokenId) == msg.sender
                || isApprovedForAll(owner, msg.sender),
            "not owner/approved"
        );

        uint256 mass = massOf[tokenId];
        bytes32 gh = geometryOf[tokenId];
        uint256 locked = lockedBloxOf[tokenId];

        burned[tokenId] = true;

        uint256 recycled = (locked * 10) / 100; // 10% rewards
        uint256 liquidity = (locked * 5) / 100; // 5% LP
        uint256 returned = locked - recycled - liquidity; // 85%

        // clear per-token state
        delete massOf[tokenId];
        delete geometryOf[tokenId];
        delete lockedBloxOf[tokenId];
        delete creatorOf[tokenId];
        delete kindOf[tokenId];
        delete densityOf[tokenId];
        delete bwAnchorOf[tokenId];
        delete brickSpecOf[tokenId];
        delete brickSpecKeyOf[tokenId];

        uint256[] memory escrowed = escrowedLicenseIds[tokenId];
        delete escrowedLicenseIds[tokenId];

        _burn(tokenId);

        for (uint256 i = 0; i < escrowed.length; i++) {
            uint256 qty = escrowedLicenseQty[tokenId][escrowed[i]];
            if (qty == 0) qty = 1; // backward compat for pre-v2 tokens
            IERC1155(licenseNFT).safeTransferFrom(address(this), owner, escrowed[i], qty, "");
        }

        if (returned > 0) blox.safeTransfer(owner, returned);
        if (recycled > 0) blox.safeTransfer(distributor, recycled);
        if (liquidity > 0) blox.safeTransfer(liquidityReceiver, liquidity);
        _payETH(liquidityReceiver, msg.value);

        emit BuildBurned(tokenId, owner, mass, gh, locked, returned, recycled);
    }

    // ==============================
    // Admin setters
    // ==============================

    function setMaxMass(uint256 newMaxMass) external onlyOwner {
        require(newMaxMass > 0, "maxMass=0");
        maxMass = newMaxMass;
    }

    function setLiquidityReceiver(address a) external onlyOwner {
        require(a != address(0), "0");
        liquidityReceiver = a;
    }

    function setProtocolTreasury(address a) external onlyOwner {
        require(a != address(0), "0");
        protocolTreasury = a;
    }

    function setDistributor(address a) external onlyOwner {
        require(a != address(0), "0");
        distributor = a;
    }

    function setKindEnabled(uint16 kind, bool enabled) external onlyOwner {
        require(kind != 0, "reserved");
        kindEnabled[kind] = enabled;
        emit KindEnabled(kind, enabled);
    }

    function setFeeSplitBps(uint16 ownersBps_, uint16 liquidityBps_, uint16 treasuryBps_)
        external
        onlyOwner
    {
        require(!feeSplitFrozen, "fee split frozen");
        require(uint256(ownersBps_) + uint256(liquidityBps_) + uint256(treasuryBps_) == 10_000, "bad bps");
        ownersBps = ownersBps_;
        liquidityBps = liquidityBps_;
        treasuryBps = treasuryBps_;
        emit FeeSplitSet(ownersBps_, liquidityBps_, treasuryBps_);
    }

    function freezeFeeSplit() external onlyOwner {
        require(!feeSplitFrozen, "fee split frozen");
        feeSplitFrozen = true;
        emit FeeSplitFrozen();
    }

    function setBaseTokenURI(string calldata newBase) external {
        require(msg.sender == owner() || msg.sender == displayController, "not authorized");
        baseTokenURI = newBase;
    }

    function setBaseImageURI(string calldata newBase) external {
        require(msg.sender == owner() || msg.sender == displayController, "not authorized");
        baseImageURI = newBase;
    }

    function setDisplayController(address controller) external onlyOwner {
        displayController = controller;
    }

    function setGeometryRegistry(address a) external onlyOwner {
        require(a != address(0), "0");
        geometryRegistry = a;
    }

    function setRenderer(address a) external {
        require(msg.sender == owner() || msg.sender == displayController, "not authorized");
        require(a != address(0), "0");
        renderer = a;
    }

    // ==============================
    // Internals
    // ==============================

    function _payETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function _splitFee(
        uint256 fee,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        address payer,
        uint256 buildMass,
        uint256 buildDensity
    ) internal {
        uint256 liquidityAmt = (fee * liquidityBps) / 10_000;
        uint256 treasuryAmt = (fee * treasuryBps) / 10_000;
        uint256 ownersAmt = fee - liquidityAmt - treasuryAmt;

        _payETH(liquidityReceiver, liquidityAmt);
        _payETH(protocolTreasury, treasuryAmt);

        if (componentBuildIds.length == 0) {
            _payETH(protocolTreasury, ownersAmt);
        } else {
            IDistributor(distributor).accrueFromComposition{value: ownersAmt}(
                componentBuildIds, componentCounts, payer, buildMass, buildDensity
            );
        }
    }

    function _brickSpecKey(uint8 width, uint8 depth, bytes32 /*geometryHash*/) internal pure returns (bytes32) {
        (uint8 w, uint8 d) = _canonicalDims(width, depth);
        return keccak256(abi.encodePacked(w, d));
    }

    function _canonicalDims(uint8 width, uint8 depth) internal pure returns (uint8, uint8) {
        return width <= depth ? (width, depth) : (depth, width);
    }

    function _isGenesisNoComponentMint(MintParams memory p) internal pure returns (bool) {
        return p.kind == KIND_BRICK;
    }

    function _validateCompositionRules(
        MintParams memory p,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts
    ) internal view {
        if (p.kind == KIND_COLLECTOR) {
            require(p.width == 0 && p.depth == 0, "collector dims");
            require(componentBuildIds.length == 1, "collector component");
            require(componentCounts[0] == 1, "collector count");
            require(_ownerOf(componentBuildIds[0]) != address(0), "component missing");
            require(geometryOf[componentBuildIds[0]] == p.geometryHash, "collector geometry");
        }

        if (componentBuildIds.length == 0) {
            if (p.kind == KIND_BRICK) {
                require(_isGenesisNoComponentMint(p), "components required");
            } else {
                require(p.kind == KIND_COLLECTOR, "components required");
            }
            return;
        }

        for (uint256 i = 0; i < componentBuildIds.length; i++) {
            if (i > 0) {
                require(componentBuildIds[i] > componentBuildIds[i - 1], "components not sorted");
            }
            require(componentCounts[i] > 0, "component=0");
            require(componentBuildIds[i] != 0, "component=0");
            bool componentExists = _ownerOf(componentBuildIds[i]) != address(0);
            if (!componentExists) {
                require(p.kind != KIND_BRICK, "component missing");
                continue;
            }
        }
    }

    function _handleComponents(
        uint256 tokenId,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts
    ) internal returns (uint256 totalLicenseCost) {
        if (componentBuildIds.length == 0) return 0;
        for (uint256 i = 0; i < componentBuildIds.length; i++) {
            uint256 qty = componentCounts[i];
            require(qty > 0, "qty=0");

            // Skip burned components — validated in _validateCompositionRules
            if (burned[componentBuildIds[i]]) continue;

            // Quote first so we know how much ETH to forward
            uint256 expectedPrice = ILicenseRegistry(licenseRegistry).quote(componentBuildIds[i], qty);

            // Auto-register + mint license directly to BuildNFT for escrow.
            // LicenseRegistry accepts ETH and forwards to treasury.
            (uint256 licenseId, uint256 price) = ILicenseRegistry(licenseRegistry)
                .mintLicenseOnBehalfOf{value: expectedPrice}(componentBuildIds[i], qty, address(this));

            totalLicenseCost += price;
            escrowedLicenseIds[tokenId].push(licenseId);
            escrowedLicenseQty[tokenId][licenseId] = qty;
        }
    }

    function _lockBlox(address payer, uint256 tokenId, uint256 mass) internal {
        uint256 lockAmount = mass * BLOX_PER_MASS;
        blox.safeTransferFrom(payer, address(this), lockAmount);
        lockedBloxOf[tokenId] = lockAmount;
    }

    function reservationDigest(MintReservation memory r) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                MINT_RESERVATION_TYPEHASH,
                r.author,
                r.reservedFor,
                r.geometryHash,
                r.mass,
                r.uriHash,
                r.componentBuildIdsHash,
                r.componentCountsHash,
                r.kind,
                r.width,
                r.depth,
                r.density,
                r.nonce,
                r.expiry
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function repaint(uint256 tokenId, bytes calldata newVoxelData) external {
        require(_ownerOf(tokenId) == msg.sender, "not owner");
        IGeometryRegistry(geometryRegistry).repaint(tokenId, newVoxelData);
    }

    function getManifest(uint256 tokenId)
        external
        view
        returns (PlacedComponent[] memory)
    {
        return manifestOf[tokenId];
    }

    function isActive(uint256 tokenId) external view returns (bool) {
        return _isActive(tokenId);
    }

    function isBurned(uint256 tokenId) external view returns (bool) {
        return burned[tokenId];
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function ownerOfSafe(uint256 tokenId) external view returns (address) {
        return _ownerOf(tokenId);
    }

    function isKindUnlocked() external view returns (bool) {
        return true;
    }

    function _isActive(uint256 tokenId) internal view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) return false;
        return !burned[tokenId];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721)
        returns (string memory)
    {
        require(_ownerOf(tokenId) != address(0), "ERC721: invalid token ID");

        // If renderer is set, generate fully on-chain data URI
        if (renderer != address(0) && geometryRegistry != address(0)) {
            bytes memory geo = IGeometryRegistry(geometryRegistry).geometryData(tokenId);
            if (geo.length > 0) {
                string memory kindName = kindOf[tokenId] == KIND_BRICK
                    ? "Brick"
                    : kindOf[tokenId] == KIND_BUILD ? "Build" : "Collector";

                // Build brick spec string for bricks (e.g. "2x3")
                string memory specStr = "";
                if (kindOf[tokenId] == KIND_BRICK) {
                    BrickSpec memory bs = brickSpecOf[tokenId];
                    specStr = string.concat(
                        ',{"trait_type":"Width","value":', uint256(bs.width).toString(),
                        ',"display_type":"number"},',
                        '{"trait_type":"Depth","value":', uint256(bs.depth).toString(),
                        ',"display_type":"number"}'
                    );
                }

                // Build animation_url if renderer HTML is stored
                string memory animStr = "";
                if (IBUIDLRenderer(renderer).rendererPointer() != address(0)) {
                    string memory htmlB64 = Base64.encode(
                        bytes(IBUIDLRenderer(renderer).render3DHTML(tokenId, geo))
                    );
                    animStr = string.concat(
                        '"animation_url":"data:text/html;base64,', htmlB64, '",'
                    );
                }

                // Image field: use external URI if set, otherwise fall back to on-chain SVG
                string memory imageStr;
                if (bytes(baseImageURI).length > 0) {
                    // External image (server-rendered SVG or IPFS)
                    imageStr = string.concat(
                        '"image":"', baseImageURI, '/', tokenId.toString(), '",'
                    );
                } else {
                    // Fully on-chain SVG (works for small models, may hit gas limit on large ones)
                    string memory svgB64 = Base64.encode(
                        bytes(IBUIDLRenderer(renderer).renderSVG(geo))
                    );
                    imageStr = string.concat(
                        '"image":"data:image/svg+xml;base64,', svgB64, '",'
                    );
                }

                string memory json = string.concat(
                    '{"name":"', kindName, ' #', tokenId.toString(), '",',
                    '"description":"BUIDL on-chain voxel ', kindName,
                    '. Geometry and renderer stored fully on-chain via SSTORE2.",'
                );
                json = string.concat(
                    json,
                    imageStr,
                    animStr,
                    '"external_url":"https://buidl.art/onchain/', tokenId.toString(), '",'
                );
                json = string.concat(
                    json,
                    '"attributes":[',
                    '{"trait_type":"Kind","value":"', kindName, '"},',
                    '{"trait_type":"Mass","value":', massOf[tokenId].toString(),
                    ',"display_type":"number"},'
                );
                json = string.concat(
                    json,
                    '{"trait_type":"Geometry Hash","value":"',
                    _bytes32ToHex(geometryOf[tokenId]), '"}',
                    specStr,
                    ']}'
                );

                return string.concat(
                    "data:application/json;base64,",
                    Base64.encode(bytes(json))
                );
            }
        }

        // Fallback to baseTokenURI for legacy tokens
        string memory base = baseTokenURI;
        if (bytes(base).length == 0) return "";
        return string.concat(base, "/", tokenId.toString(), ".json");
    }

    function _bytes32ToHex(bytes32 b) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = hexChars[uint8(b[i]) >> 4];
            str[3 + i * 2] = hexChars[uint8(b[i]) & 0x0f];
        }
        return string(str);
    }
}
