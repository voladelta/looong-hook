// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Immutable-minter companion NFT seed. Delete it when the hook does not own an NFT.
contract StarterNft is ERC721 {
    error NotMinter();
    error ZeroMinter();

    address public immutable minter;
    uint256 public nextTokenId = 1;

    constructor(string memory name_, string memory symbol_, address minter_) ERC721(name_, symbol_) {
        if (minter_ == address(0)) revert ZeroMinter();
        minter = minter_;
    }

    function mint(address recipient) external returns (uint256 tokenId) {
        if (msg.sender != minter) revert NotMinter();
        tokenId = nextTokenId++;
        _safeMint(recipient, tokenId);
    }
}
