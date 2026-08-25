// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {DirectFundingVrfConsumer} from "../../src/vrf/DirectFundingVrfConsumer.sol";
import {MockVrfV2PlusWrapper} from "../mocks/MockVrfV2PlusWrapper.sol";

contract DirectFundingVrfConsumerTest is Test {
    MockVrfV2PlusWrapper internal wrapper;
    DirectFundingVrfConsumer internal consumer;

    function setUp() public {
        wrapper = new MockVrfV2PlusWrapper();
        consumer = new DirectFundingVrfConsumer(address(wrapper), 3);
    }

    function test_nativeRequestBindsPriceAndWrapperArguments() public {
        bytes32 commitment = keccak256("round-1");
        uint256 requestId = consumer.requestRandomness{value: wrapper.price()}(commitment);

        (bytes32 storedCommitment,, DirectFundingVrfConsumer.RequestState state, uint256 paid,) =
            consumer.requests(requestId);
        assertEq(storedCommitment, commitment);
        assertEq(uint256(state), uint256(DirectFundingVrfConsumer.RequestState.Pending));
        assertEq(paid, wrapper.price());
        assertEq(wrapper.lastCallbackGasLimit(), 150_000);
        assertEq(wrapper.lastRequestConfirmations(), 3);
        assertEq(wrapper.lastNumWords(), 1);
    }

    function test_wrapperFulfillsThroughAuthenticatedCallback() public {
        uint256 requestId = consumer.requestRandomness{value: wrapper.price()}(keccak256("round-1"));
        uint256[] memory words = new uint256[](1);
        words[0] = 42;

        wrapper.fulfill(address(consumer), requestId, words);

        (,, DirectFundingVrfConsumer.RequestState state,, uint256 randomWord) = consumer.requests(requestId);
        assertEq(uint256(state), uint256(DirectFundingVrfConsumer.RequestState.Fulfilled));
        assertEq(randomWord, 42);
    }

    function test_nonWrapperCannotFulfill() public {
        uint256[] memory words = new uint256[](1);
        vm.expectRevert(
            abi.encodeWithSelector(
                VRFV2PlusWrapperConsumerBase.OnlyVRFWrapperCanFulfill.selector, address(this), address(wrapper)
            )
        );
        consumer.rawFulfillRandomWords(1, words);
    }

    function test_priceAboveCapRevertsWithoutConsumingCommitment() public {
        bytes32 commitment = keccak256("round-1");
        wrapper.setPrice(0.01 ether + 1);
        uint256 price = wrapper.price();

        vm.expectRevert(abi.encodeWithSelector(DirectFundingVrfConsumer.PriceAboveLimit.selector, price));
        consumer.requestRandomness{value: price}(commitment);

        assertFalse(consumer.commitmentUsed(commitment));
        assertEq(wrapper.lastRequestId(), 0);
    }

    function test_recoveryIsTerminalAtSevenDays() public {
        uint256 requestId = consumer.requestRandomness{value: wrapper.price()}(keccak256("round-1"));
        vm.warp(block.timestamp + 7 days);
        consumer.recover(requestId);

        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        wrapper.fulfill(address(consumer), requestId, words);

        (,, DirectFundingVrfConsumer.RequestState state,, uint256 randomWord) = consumer.requests(requestId);
        assertEq(uint256(state), uint256(DirectFundingVrfConsumer.RequestState.Recovered));
        assertEq(randomWord, 0);
    }
}
