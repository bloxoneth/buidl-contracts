// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SSTORE2} from "sstore2/SSTORE2.sol";

/// @notice Stores raw geometry bytes on-chain via SSTORE2.
/// Manages the consumed geometry hash registry.
/// Only callable by the authorised BuildNFT contract.
contract GeometryRegistry is Ownable {
    address public buildNFT;

    // tokenId => SSTORE2 pointer to geometry bytes
    mapping(uint256 => address) private _geometryPointer;

    // geometryHash => consumed
    mapping(bytes32 => bool) public hashConsumed;

    event GeometryStored(uint256 indexed tokenId, bytes32 indexed hash, uint256 size);
    event GeometryRepainted(uint256 indexed tokenId, uint256 size);
    event BuildNFTSet(address indexed buildNFT);

    modifier onlyBuildNFT() {
        require(msg.sender == buildNFT, "not buildNFT");
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    function setBuildNFT(address buildNFT_) external onlyOwner {
        require(buildNFT_ != address(0), "buildNFT=0");
        buildNFT = buildNFT_;
        emit BuildNFTSet(buildNFT_);
    }

    /// @notice Mark a geometry hash as consumed without storing data.
    /// Used for backward-compat mints that don't include geometry bytes.
    function consumeHash(bytes32 hash) external onlyBuildNFT {
        require(!hashConsumed[hash], "hash consumed");
        hashConsumed[hash] = true;
    }

    /// @notice Store geometry bytes at mint. Marks hash as consumed.
    function store(
        uint256 tokenId,
        bytes32 hash,
        bytes calldata data
    ) external onlyBuildNFT {
        require(!hashConsumed[hash], "hash consumed");
        require(data.length > 0, "empty geometry");
        require(_geometryPointer[tokenId] == address(0), "already stored");

        hashConsumed[hash] = true;
        _geometryPointer[tokenId] = SSTORE2.write(data);

        emit GeometryStored(tokenId, hash, data.length);
    }

    /// @notice Update colour data for an existing token.
    /// Called by BuildNFT.repaint. Shape must not change.
    function repaint(
        uint256 tokenId,
        bytes calldata newData
    ) external onlyBuildNFT {
        require(_geometryPointer[tokenId] != address(0), "not stored");
        require(newData.length > 0, "empty");

        // Verify shape is identical (same byte count = same bounding box + voxel count)
        bytes memory existing = SSTORE2.read(_geometryPointer[tokenId]);
        require(newData.length == existing.length, "geometry changed");

        _geometryPointer[tokenId] = SSTORE2.write(newData);

        emit GeometryRepainted(tokenId, newData.length);
    }

    /// @notice Read stored geometry bytes for a token.
    function geometryData(uint256 tokenId)
        external
        view
        returns (bytes memory)
    {
        address ptr = _geometryPointer[tokenId];
        if (ptr == address(0)) return "";
        return SSTORE2.read(ptr);
    }

    /// @notice Check if geometry data exists for a token.
    function hasGeometry(uint256 tokenId) external view returns (bool) {
        return _geometryPointer[tokenId] != address(0);
    }
}
