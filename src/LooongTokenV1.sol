// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply subject token created by a LOOONG market launch.
contract LooongTokenV1 is ERC20 {
    address public immutable creator;
    string public tagline;
    string public logoURI;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory tagline_,
        string memory logoURI_,
        address creator_,
        uint256 supply_
    ) ERC20(name_, symbol_) {
        creator = creator_;
        tagline = tagline_;
        logoURI = logoURI_;
        _mint(msg.sender, supply_);
    }
}
