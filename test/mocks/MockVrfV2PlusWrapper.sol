// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVRFV2PlusWrapper} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFV2PlusWrapper.sol";

interface IRawVrfConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}

contract MockVrfV2PlusWrapper is IVRFV2PlusWrapper {
    uint256 public price = 0.001 ether;
    uint256 public override lastRequestId;
    uint32 public lastCallbackGasLimit;
    uint16 public lastRequestConfirmations;
    uint32 public lastNumWords;
    bytes public lastExtraArgs;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function calculateRequestPrice(uint32, uint32) external view returns (uint256) {
        return price;
    }

    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256) {
        return price;
    }

    function estimateRequestPrice(uint32, uint32, uint256) external view returns (uint256) {
        return price;
    }

    function estimateRequestPriceNative(uint32, uint32, uint256) external view returns (uint256) {
        return price;
    }

    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId) {
        require(msg.value == price, "PRICE");
        requestId = ++lastRequestId;
        lastCallbackGasLimit = callbackGasLimit;
        lastRequestConfirmations = requestConfirmations;
        lastNumWords = numWords;
        lastExtraArgs = extraArgs;
    }

    function fulfill(address consumer, uint256 requestId, uint256[] memory randomWords) external {
        IRawVrfConsumer(consumer).rawFulfillRandomWords(requestId, randomWords);
    }

    function link() external pure returns (address) {
        return address(0x1111);
    }

    function linkNativeFeed() external pure returns (address) {
        return address(0x2222);
    }
}
