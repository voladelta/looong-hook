// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply companion token seed. Delete it when the hook does not own an ERC-20.
contract StarterToken is ERC20 {
    error ZeroRecipient();

    constructor(string memory name_, string memory symbol_, address recipient, uint256 supply) ERC20(name_, symbol_) {
        if (recipient == address(0)) revert ZeroRecipient();
        _mint(recipient, supply);
    }
}
