// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {InvariantActionAccounting} from "../utils/InvariantActionAccounting.sol";

contract InvariantActionAccountingHarness is InvariantActionAccounting {
    function classify(bytes4 action, bytes memory reason, bytes4 expectedSelector) external {
        _beginAction(action);
        _classifyRevert(action, reason, expectedSelector);
    }

    function succeed(bytes4 action) external {
        _beginAction(action);
        _recordSuccess(action);
    }

    function counts(bytes4 action) external view returns (ActionCounts memory) {
        return actionCounts[action];
    }

    function assertLive(bytes4 action) external view {
        _assertActionLive(action);
    }
}

contract InvariantActionAccountingTest is Test {
    bytes4 private constant ACTION = bytes4(keccak256("action"));
    bytes4 private constant EXPECTED = bytes4(keccak256("Expected()"));
    bytes4 private constant OTHER = bytes4(keccak256("Other()"));

    InvariantActionAccountingHarness private harness;

    function setUp() public {
        harness = new InvariantActionAccountingHarness();
    }

    function test_exactSelectorIsTheOnlyExpectedRevert() public {
        harness.succeed(ACTION);
        harness.classify(ACTION, abi.encodeWithSelector(EXPECTED), EXPECTED);

        InvariantActionAccounting.ActionCounts memory counts = harness.counts(ACTION);
        assertEq(counts.attempts, 2);
        assertEq(counts.successes, 1);
        assertEq(counts.expectedReverts, 1);
        assertEq(counts.unexpectedFailures, 0);
        harness.assertLive(ACTION);
    }

    function test_emptyAndMismatchedReasonsAreUnexpected() public {
        harness.classify(ACTION, "", EXPECTED);
        harness.classify(ACTION, abi.encodeWithSelector(OTHER), EXPECTED);

        InvariantActionAccounting.ActionCounts memory counts = harness.counts(ACTION);
        assertEq(counts.attempts, 2);
        assertEq(counts.expectedReverts, 0);
        assertEq(counts.unexpectedFailures, 2);
    }

    function test_zeroExpectedSelectorIsRejected() public {
        vm.expectRevert(InvariantActionAccounting.InvalidExpectedSelector.selector);
        harness.classify(ACTION, "", bytes4(0));
    }
}
