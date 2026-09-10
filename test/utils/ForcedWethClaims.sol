// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Pays real WETH to mint claims, with no cooperation from the recipient.
contract ForcedWethClaims {
    IPoolManager private immutable manager;
    IERC20 private immutable weth;

    constructor(IPoolManager manager_, IERC20 weth_) {
        manager = manager_;
        weth = weth_;
    }

    function donate(address recipient, uint256 amount, bool transferClaim) external {
        manager.unlock(abi.encode(transferClaim ? address(this) : recipient, amount));
        if (transferClaim) require(manager.transfer(recipient, uint160(address(weth)), amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(Currency.wrap(address(weth)));
        require(weth.transfer(address(manager), amount));
        require(manager.settle() == amount);
        manager.mint(recipient, uint160(address(weth)), amount);
        return "";
    }
}
