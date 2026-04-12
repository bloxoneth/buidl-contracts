// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/// @notice BUIDL access/membership pass sale.
/// Buyers pay ETH and receive an ERC721 pass + fixed BLOX reward per pass.
contract BasebloxAccessPass is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 1000;
    uint256 public constant PASS_PRICE = 0.05 ether;
    uint256 public constant BLOX_REWARD_PER_PASS = 10_000e18;
    uint256 public constant MAX_MINT_PER_TX = 20;

    IERC20 public immutable blox;
    address public treasury;
    string public baseTokenURI;
    string public contractMetadataURI;

    bool public saleActive;
    uint256 public totalMinted;
    uint256 public nextTokenId = 1;
    uint256 public claimStart;
    mapping(uint256 => bool) public bloxClaimed;

    event SaleActiveSet(bool indexed active);
    event TreasurySet(address indexed treasury);
    event BaseTokenURISet(string uri);
    event ContractURISet(string uri);
    event ClaimStartSet(uint256 indexed claimStart);
    event PassMinted(
        address indexed buyer, uint256 quantity, uint256 ethPaid, uint256 firstTokenId
    );
    event BLOXClaimed(address indexed claimer, uint256 indexed tokenId, uint256 amount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event BLOXWithdrawn(address indexed to, uint256 amount);

    constructor(address blox_, address treasury_, string memory baseTokenURI_, string memory contractURI_)
        ERC721("BUIDL Access Pass", "BBPASS")
        Ownable(msg.sender)
    {
        require(blox_ != address(0), "blox=0");
        require(treasury_ != address(0), "treasury=0");
        blox = IERC20(blox_);
        treasury = treasury_;
        baseTokenURI = baseTokenURI_;
        contractMetadataURI = contractURI_;
    }

    function mint(uint256 quantity) external payable nonReentrant {
        require(saleActive, "sale inactive");
        require(quantity > 0 && quantity <= MAX_MINT_PER_TX, "bad qty");
        require(totalMinted + quantity <= MAX_SUPPLY, "sold out");

        uint256 requiredEth = PASS_PRICE * quantity;
        require(msg.value == requiredEth, "bad eth");

        uint256 firstTokenId = nextTokenId;
        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(msg.sender, nextTokenId++);
        }
        totalMinted += quantity;
        emit PassMinted(msg.sender, quantity, msg.value, firstTokenId);
    }

    function claimBlox(uint256[] calldata tokenIds) external nonReentrant {
        require(claimStart != 0 && block.timestamp >= claimStart, "claim not open");
        require(tokenIds.length > 0, "no tokenIds");

        uint256 totalOut;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(_ownerOf(tokenId) == msg.sender, "not token owner");
            require(!bloxClaimed[tokenId], "already claimed");
            bloxClaimed[tokenId] = true;
            totalOut += BLOX_REWARD_PER_PASS;
            emit BLOXClaimed(msg.sender, tokenId, BLOX_REWARD_PER_PASS);
        }
        require(blox.balanceOf(address(this)) >= totalOut, "insufficient blox");
        blox.safeTransfer(msg.sender, totalOut);
    }

    function setSaleActive(bool active) external onlyOwner {
        saleActive = active;
        emit SaleActiveSet(active);
    }

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setBaseTokenURI(string calldata uri) external onlyOwner {
        baseTokenURI = uri;
        emit BaseTokenURISet(uri);
    }

    function setContractURI(string calldata uri) external onlyOwner {
        contractMetadataURI = uri;
        emit ContractURISet(uri);
    }

    function setClaimStart(uint256 ts) external onlyOwner {
        require(ts > block.timestamp, "claimStart in past");
        claimStart = ts;
        emit ClaimStartSet(ts);
    }

    function withdrawETH() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "no eth");
        (bool ok,) = payable(treasury).call{value: bal}("");
        require(ok, "eth transfer failed");
        emit ETHWithdrawn(treasury, bal);
    }

    function withdrawBLOX(uint256 amount) external onlyOwner {
        require(amount > 0, "amount=0");
        blox.safeTransfer(treasury, amount);
        emit BLOXWithdrawn(treasury, amount);
    }

    function contractURI() external view returns (string memory) {
        return contractMetadataURI;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(baseTokenURI).length == 0) return "";
        return string.concat(baseTokenURI, tokenId.toString(), ".json");
    }
}
