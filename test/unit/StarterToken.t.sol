// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StarterToken} from "../../src/tokens/StarterToken.sol";

contract StarterTokenTest is Test {
    function test_constructorMintsFixedSupplyToRecipient() public {
        address recipient = makeAddr("recipient");
        StarterToken token = new StarterToken("Starter", "START", recipient, 1_000_000 ether);

        assertEq(token.totalSupply(), 1_000_000 ether);
        assertEq(token.balanceOf(recipient), token.totalSupply());
    }

    function test_constructorRejectsZeroRecipient() public {
        vm.expectRevert(StarterToken.ZeroRecipient.selector);
        new StarterToken("Starter", "START", address(0), 1 ether);
    }
}
