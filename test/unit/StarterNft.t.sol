// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StarterNft} from "../../src/tokens/StarterNft.sol";

contract StarterNftTest is Test {
    StarterNft internal nft;

    function setUp() public {
        nft = new StarterNft("Starter NFT", "SNFT", address(this));
    }

    function test_minterMintsSequentialTokens() public {
        address recipient = makeAddr("recipient");

        assertEq(nft.mint(recipient), 1);
        assertEq(nft.mint(recipient), 2);
        assertEq(nft.ownerOf(1), recipient);
        assertEq(nft.nextTokenId(), 3);
    }

    function test_nonMinterCannotMint() public {
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(StarterNft.NotMinter.selector);
        nft.mint(makeAddr("recipient"));
    }
}
