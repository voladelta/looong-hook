// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Reusable accounting floor for production-path stateful handlers.
abstract contract InvariantActionAccounting is Test {
    error InvalidExpectedSelector();

    struct ActionCounts {
        uint256 attempts;
        uint256 successes;
        uint256 expectedReverts;
        uint256 unexpectedFailures;
    }

    mapping(bytes4 action => ActionCounts counts) internal actionCounts;

    function _beginAction(bytes4 action) internal {
        ++actionCounts[action].attempts;
    }

    function _recordSuccess(bytes4 action) internal {
        ++actionCounts[action].successes;
    }

    function _classifyRevert(bytes4 action, bytes memory reason, bytes4 expectedSelector) internal {
        if (expectedSelector == bytes4(0)) revert InvalidExpectedSelector();

        bytes4 actualSelector;
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                actualSelector := mload(add(reason, 0x20))
            }
        }
        if (actualSelector == expectedSelector) {
            ++actionCounts[action].expectedReverts;
        } else {
            ++actionCounts[action].unexpectedFailures;
        }
    }

    function _recordUnexpectedFailure(bytes4 action) internal {
        ++actionCounts[action].unexpectedFailures;
    }

    function _assertActionLive(bytes4 action) internal view {
        ActionCounts storage counts = actionCounts[action];
        assertGt(counts.attempts, 0, "action never attempted");
        assertGt(counts.successes, 0, "action never succeeded");
        assertEq(
            counts.attempts,
            counts.successes + counts.expectedReverts + counts.unexpectedFailures,
            "action accounting mismatch"
        );
        assertEq(counts.unexpectedFailures, 0, "unexpected action failure");
    }
}
