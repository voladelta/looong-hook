// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LooongHook} from "./LooongHook.sol";

/// @dev The first STOP byte makes the stored creation blob inert if called.
contract LooongHookBytecodeStore {
    constructor(bytes memory creationBlob) {
        bytes memory runtime = abi.encodePacked(hex"00", creationBlob);
        assembly ("memory-safe") {
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

/// @notice CREATE2 boundary that accepts only the five required hook permission bits.
contract LooongHookFactory {
    uint160 public constant REQUIRED_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 public constant ALL_FLAGS = (1 << 14) - 1;

    error InvalidHookAddress(address predicted);
    error HookDeploymentFailed();
    error InvalidAddress();
    error OnlyRegistrar();

    IPoolManager public immutable manager;
    address public immutable registrar;
    address public immutable router;
    IERC20 public immutable looong;
    IERC20 public immutable weth;
    address public immutable feeBeneficiary;
    address public immutable bytecodeStore;
    bytes32 public immutable bytecodeHash;

    constructor(
        IPoolManager manager_,
        address registrar_,
        address router_,
        IERC20 looong_,
        IERC20 weth_,
        address feeBeneficiary_
    ) {
        if (
            address(manager_) == address(0) || registrar_ == address(0) || router_ == address(0)
                || address(looong_) == address(0) || address(weth_) == address(0) || feeBeneficiary_ == address(0)
                || address(looong_) == address(weth_)
        ) revert InvalidAddress();
        manager = manager_;
        registrar = registrar_;
        router = router_;
        looong = looong_;
        weth = weth_;
        feeBeneficiary = feeBeneficiary_;
        bytes memory creationBlob = abi.encodePacked(
            type(LooongHook).creationCode, abi.encode(manager_, registrar_, router_, looong_, weth_, feeBeneficiary_)
        );
        bytecodeHash = keccak256(creationBlob);
        bytecodeStore = address(new LooongHookBytecodeStore(creationBlob));
    }

    function deploy(bytes32 salt) external returns (LooongHook hook) {
        if (msg.sender != registrar) revert OnlyRegistrar();
        address predicted = computeAddress(salt);
        if (uint160(predicted) & ALL_FLAGS != REQUIRED_FLAGS) revert InvalidHookAddress(predicted);
        address store = bytecodeStore;
        address deployed;
        assembly ("memory-safe") {
            let size := sub(extcodesize(store), 1)
            let code := mload(0x40)
            extcodecopy(store, code, 1, size)
            deployed := create2(0, code, size, salt)
            mstore(0x40, add(code, and(add(size, 0x1f), not(0x1f))))
        }
        if (deployed == address(0)) revert HookDeploymentFailed();
        hook = LooongHook(deployed);
    }

    function computeAddress(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, bytecodeHash)))));
    }

    function creationCodeHash() external view returns (bytes32) {
        return bytecodeHash;
    }
}
