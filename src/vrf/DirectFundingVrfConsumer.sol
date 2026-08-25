// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice Native-payment VRF v2.5 direct-funding reference for infrequent application requests.
/// @dev Keep request creation outside PoolManager callbacks. Perform outcome settlement separately.
contract DirectFundingVrfConsumer is VRFV2PlusWrapperConsumerBase {
    uint32 public constant CALLBACK_GAS_LIMIT = 150_000;
    uint32 public constant NUM_WORDS = 1;
    uint256 public constant MAX_REQUEST_PRICE = 0.01 ether;
    uint256 public constant RECOVERY_DELAY = 7 days;

    enum RequestState {
        None,
        Pending,
        Fulfilled,
        Recovered
    }

    struct Request {
        bytes32 commitment;
        uint64 requestedAt;
        RequestState state;
        uint256 paid;
        uint256 randomWord;
    }

    error CommitmentAlreadyUsed(bytes32 commitment);
    error InvalidConfirmations();
    error InvalidPayment(uint256 supplied, uint256 required);
    error PriceAboveLimit(uint256 price);
    error RequestNotRecoverable(uint256 requestId);

    event RandomnessRequested(uint256 indexed requestId, bytes32 indexed commitment, uint256 paid);
    event RandomnessFulfilled(uint256 indexed requestId, uint256 randomWord);
    event FulfillmentIgnored(uint256 indexed requestId);
    event RequestRecovered(uint256 indexed requestId);

    uint16 public immutable requestConfirmations;
    mapping(bytes32 commitment => bool used) public commitmentUsed;
    mapping(uint256 requestId => Request request) public requests;

    constructor(address wrapper, uint16 confirmations) VRFV2PlusWrapperConsumerBase(wrapper) {
        if (confirmations == 0) revert InvalidConfirmations();
        requestConfirmations = confirmations;
    }

    function requestRandomness(bytes32 commitment) external payable returns (uint256 requestId) {
        if (commitmentUsed[commitment]) revert CommitmentAlreadyUsed(commitment);

        uint256 quote = i_vrfV2PlusWrapper.calculateRequestPriceNative(CALLBACK_GAS_LIMIT, NUM_WORDS);
        if (quote > MAX_REQUEST_PRICE) revert PriceAboveLimit(quote);
        if (msg.value != quote) revert InvalidPayment(msg.value, quote);

        commitmentUsed[commitment] = true;
        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}));
        uint256 paid;
        (requestId, paid) = requestRandomnessPayInNative(CALLBACK_GAS_LIMIT, requestConfirmations, NUM_WORDS, extraArgs);

        requests[requestId] = Request({
            commitment: commitment,
            requestedAt: uint64(block.timestamp),
            state: RequestState.Pending,
            paid: paid,
            randomWord: 0
        });
        emit RandomnessRequested(requestId, commitment, paid);
    }

    function recover(uint256 requestId) external {
        Request storage request = requests[requestId];
        if (request.state != RequestState.Pending || block.timestamp < uint256(request.requestedAt) + RECOVERY_DELAY) {
            revert RequestNotRecoverable(requestId);
        }

        request.state = RequestState.Recovered;
        emit RequestRecovered(requestId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        Request storage request = requests[requestId];
        if (request.state != RequestState.Pending || randomWords.length != NUM_WORDS) {
            emit FulfillmentIgnored(requestId);
            return;
        }

        request.randomWord = randomWords[0];
        request.state = RequestState.Fulfilled;
        emit RandomnessFulfilled(requestId, randomWords[0]);
    }
}
