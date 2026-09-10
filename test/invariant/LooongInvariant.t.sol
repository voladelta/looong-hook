// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {LooongHook} from "../../src/LooongHook.sol";
import {LooongHookFactory} from "../../src/LooongHookFactory.sol";
import {LooongMarketCoordinatorV1} from "../../src/LooongMarketCoordinatorV1.sol";
import {LooongRouter} from "../../src/LooongRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {InvariantActionAccounting} from "../utils/InvariantActionAccounting.sol";

contract LooongInvariantHandler is InvariantActionAccounting {
    bytes4 private constant BUY = bytes4(keccak256("buy"));
    bytes4 private constant SELL = bytes4(keccak256("sell"));
    bytes4 private constant WITHDRAW = bytes4(keccak256("withdraw"));
    bytes4 private constant ACTIVATE = bytes4(keccak256("activate"));
    bytes4 private constant ORDINARY = bytes4(keccak256("ordinary"));
    bytes4 private constant CLAIM_BASE = bytes4(keccak256("claimBase"));
    bytes4 private constant CLAIM_REBATE = bytes4(keccak256("claimRebate"));
    bytes4 private constant CLAIM_REWARD = bytes4(keccak256("claimReward"));

    LooongHook public immutable hook;
    LooongRouter public immutable router;
    IERC20 public immutable subject;
    MockERC20 public immutable weth;
    PoolId public immutable poolId;
    address public immutable beneficiary;

    address[3] private actors;
    uint256[] private positionIds;

    constructor(
        LooongHook hook_,
        LooongRouter router_,
        IERC20 subject_,
        MockERC20 weth_,
        PoolId poolId_,
        address beneficiary_
    ) {
        hook = hook_;
        router = router_;
        subject = subject_;
        weth = weth_;
        poolId = poolId_;
        beneficiary = beneficiary_;
        actors = [makeAddr("invariant-alice"), makeAddr("invariant-bob"), makeAddr("invariant-carol")];

        weth_.mint(address(this), 1_000 ether);
        subject_.approve(address(router_), type(uint256).max);
        weth_.approve(address(router_), type(uint256).max);
        for (uint256 i; i < actors.length; ++i) {
            weth_.mint(actors[i], 1_000 ether);
            vm.prank(actors[i]);
            weth_.approve(address(router_), type(uint256).max);
        }
    }

    function seedPositions() external {
        for (uint256 i; i < actors.length; ++i) {
            positionIds.push(_buyFor(actors[i], 1 ether));
        }
        _assertProtocol();
    }

    function actionBuy(uint256 actorSeed, uint96 amountSeed) external {
        _beginAction(BUY);
        address actor = actors[actorSeed % actors.length];
        uint128 amount = uint128(bound(uint256(amountSeed), 0.01 ether, 0.05 ether));
        vm.prank(actor);
        try router.buy(address(subject), amount, 1, _priceLimit(true), uint64(block.timestamp)) returns (
            uint256 positionId
        ) {
            positionIds.push(positionId);
            _assertProtocol();
            _recordSuccess(BUY);
        } catch {
            _recordUnexpectedFailure(BUY);
        }
    }

    function actionSell(uint256 seed) external {
        _beginAction(SELL);
        (uint256 positionId, address owner, uint128 remaining) = _livePosition(seed);
        uint128 amount = _fraction(remaining, seed);
        vm.prank(owner);
        try router.sell(address(subject), positionId, amount, 1, _priceLimit(false), uint64(block.timestamp)) {
            _assertProtocol();
            _recordSuccess(SELL);
        } catch {
            _recordUnexpectedFailure(SELL);
        }
    }

    function actionWithdraw(uint256 seed) external {
        _beginAction(WITHDRAW);
        (uint256 positionId, address owner, uint128 remaining) = _livePosition(seed);
        uint128 amount = _fraction(remaining, seed >> 8);
        vm.prank(owner);
        try hook.withdraw(positionId, amount) {
            _assertProtocol();
            _recordSuccess(WITHDRAW);
        } catch {
            _recordUnexpectedFailure(WITHDRAW);
        }
    }

    function actionActivate(uint256 seed) external {
        _beginAction(ACTIVATE);
        (uint256 positionId,,) = _livePosition(seed);
        (, uint64 openedAt,,,,,,,,,,) = hook.positions(positionId);
        uint256 maturity = uint256(openedAt) + hook.MATURITY();
        if (block.timestamp < maturity) vm.warp(maturity);
        try hook.activatePosition(positionId) {
            _assertProtocol();
            _recordSuccess(ACTIVATE);
        } catch {
            _recordUnexpectedFailure(ACTIVATE);
        }
    }

    function actionOrdinarySwap(uint96 amountSeed) external {
        _beginAction(ORDINARY);
        uint128 amount = uint128(bound(uint256(amountSeed), 0.01 ether, 0.03 ether));
        try router.swapExactInput(
            address(subject), true, amount, 1, address(this), _priceLimit(true), uint64(block.timestamp)
        ) returns (
            uint256 output
        ) {
            try router.swapExactInput(
                address(subject),
                false,
                uint128(output / 2),
                1,
                address(this),
                _priceLimit(false),
                uint64(block.timestamp)
            ) {
                _assertProtocol();
                _recordSuccess(ORDINARY);
            } catch {
                _recordUnexpectedFailure(ORDINARY);
            }
        } catch {
            _recordUnexpectedFailure(ORDINARY);
        }
    }

    function actionClaimBase() external {
        _beginAction(CLAIM_BASE);
        _ordinaryBuy(0.01 ether);
        vm.prank(beneficiary);
        try hook.claimBaseFees(poolId, beneficiary) {
            _assertProtocol();
            _recordSuccess(CLAIM_BASE);
        } catch {
            _recordUnexpectedFailure(CLAIM_BASE);
        }
    }

    function actionClaimRebate(uint256 seed) external {
        _beginAction(CLAIM_REBATE);
        (uint256 positionId, address owner, uint128 remaining) = _livePosition(seed);
        if (hook.sellerRebates(poolId, owner) == 0) {
            vm.prank(owner);
            try router.sell(
                address(subject), positionId, _fraction(remaining, seed), 1, _priceLimit(false), uint64(block.timestamp)
            ) {}
            catch {
                _recordUnexpectedFailure(CLAIM_REBATE);
                return;
            }
        }
        try hook.claimRebate(poolId, owner) {
            _assertProtocol();
            _recordSuccess(CLAIM_REBATE);
        } catch {
            _recordUnexpectedFailure(CLAIM_REBATE);
        }
    }

    function actionClaimReward(uint256 seed) external {
        _beginAction(CLAIM_REWARD);
        (uint256 positionId, address owner,) = _livePosition(seed);
        (, uint64 openedAt,,,,,,,,,,) = hook.positions(positionId);
        uint256 maturity = uint256(openedAt) + hook.MATURITY();
        if (block.timestamp < maturity) vm.warp(maturity);
        hook.activatePosition(positionId);

        uint256 output = _ordinaryBuy(0.01 ether);
        router.swapExactInput(
            address(subject), false, uint128(output / 2), 1, address(this), _priceLimit(false), uint64(block.timestamp)
        );
        vm.prank(owner);
        try hook.claimRewards(poolId, owner) {
            _assertProtocol();
            _recordSuccess(CLAIM_REWARD);
        } catch {
            _recordUnexpectedFailure(CLAIM_REWARD);
        }
    }

    function assertActionAccounting() external view {
        _assertBalanced(BUY);
        _assertBalanced(SELL);
        _assertBalanced(WITHDRAW);
        _assertBalanced(ACTIVATE);
        _assertBalanced(ORDINARY);
        _assertBalanced(CLAIM_BASE);
        _assertBalanced(CLAIM_REBATE);
        _assertBalanced(CLAIM_REWARD);
    }

    function assertAllActionsLive() external view {
        _assertActionLive(BUY);
        _assertActionLive(SELL);
        _assertActionLive(WITHDRAW);
        _assertActionLive(ACTIVATE);
        _assertActionLive(ORDINARY);
        _assertActionLive(CLAIM_BASE);
        _assertActionLive(CLAIM_REBATE);
        _assertActionLive(CLAIM_REWARD);
    }

    function trackedPositionCount() external view returns (uint256) {
        return positionIds.length;
    }

    function trackedPositionId(uint256 index) external view returns (uint256) {
        return positionIds[index];
    }

    function _buyFor(address actor, uint128 amount) private returns (uint256 positionId) {
        vm.prank(actor);
        positionId = router.buy(address(subject), amount, 1, _priceLimit(true), uint64(block.timestamp));
    }

    function _ordinaryBuy(uint128 amount) private returns (uint256 output) {
        output = router.swapExactInput(
            address(subject), true, amount, 1, address(this), _priceLimit(true), uint64(block.timestamp)
        );
    }

    function _livePosition(uint256 seed) private view returns (uint256 positionId, address owner, uint128 remaining) {
        uint256 length = positionIds.length;
        for (uint256 offset; offset < length; ++offset) {
            positionId = positionIds[(seed + offset) % length];
            (owner,,,, remaining,,,,,,,) = hook.positions(positionId);
            if (owner != address(0) && remaining > 1_000) return (positionId, owner, remaining);
        }
        revert("no live invariant position");
    }

    function _fraction(uint128 remaining, uint256 seed) private pure returns (uint128) {
        uint256 minimum = uint256(remaining) / 16;
        uint256 maximum = uint256(remaining) / 8;
        if (minimum == 0) minimum = 1;
        if (maximum < minimum) maximum = minimum;
        return uint128(minimum + seed % (maximum - minimum + 1));
    }

    function _priceLimit(bool buySubject) private view returns (uint160) {
        bool zeroForOne = buySubject ? address(weth) < address(subject) : address(subject) < address(weth);
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _assertProtocol() private view {
        assertTrue(hook.custodyIsSolvent(poolId), "custody insolvent");
        assertTrue(hook.claimsAreConserved(), "claims not conserved");
    }

    function _assertBalanced(bytes4 action) private view {
        ActionCounts storage counts = actionCounts[action];
        assertEq(
            counts.attempts,
            counts.successes + counts.expectedReverts + counts.unexpectedFailures,
            "action accounting mismatch"
        );
        assertEq(counts.unexpectedFailures, 0, "unexpected action failure");
    }
}

contract LooongInvariantTest is StdInvariant, BaseTest {
    MockERC20 private weth;
    LooongHook private hook;
    LooongInvariantHandler private alphaHandler;
    LooongInvariantHandler private betaHandler;
    PoolId private alphaPool;
    PoolId private betaPool;

    function setUp() public {
        deployArtifactsAndLabel();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        address beneficiary = makeAddr("invariant-beneficiary");

        uint64 nonce = vm.getNonce(address(this));
        address expectedCoordinator = vm.computeCreateAddress(address(this), nonce + 2);
        LooongRouter router = new LooongRouter(poolManager, expectedCoordinator, IERC20(address(weth)));
        LooongHookFactory factory =
            new LooongHookFactory(poolManager, expectedCoordinator, address(router), IERC20(address(weth)));
        LooongMarketCoordinatorV1 coordinator =
            new LooongMarketCoordinatorV1(poolManager, IERC20(address(weth)), _validSalt(factory), router, factory);
        hook = coordinator.hook();

        (address alpha, PoolId alphaPoolId) =
            _launchWithOrdering(coordinator, beneficiary, "Invariant Alpha", "IALPHA", 1, true);
        (address beta, PoolId betaPoolId) =
            _launchWithOrdering(coordinator, beneficiary, "Invariant Beta", "IBETA", 1_000, false);
        alphaPool = alphaPoolId;
        betaPool = betaPoolId;
        alphaHandler = new LooongInvariantHandler(hook, router, IERC20(alpha), weth, alphaPoolId, beneficiary);
        betaHandler = new LooongInvariantHandler(hook, router, IERC20(beta), weth, betaPoolId, beneficiary);
        _primeHandler(alphaHandler);
        _primeHandler(betaHandler);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = alphaHandler.actionBuy.selector;
        selectors[1] = alphaHandler.actionSell.selector;
        selectors[2] = alphaHandler.actionWithdraw.selector;
        selectors[3] = alphaHandler.actionActivate.selector;
        selectors[4] = alphaHandler.actionOrdinarySwap.selector;
        selectors[5] = alphaHandler.actionClaimBase.selector;
        selectors[6] = alphaHandler.actionClaimRebate.selector;
        selectors[7] = alphaHandler.actionClaimReward.selector;
        targetContract(address(alphaHandler));
        targetContract(address(betaHandler));
        targetSelector(FuzzSelector({addr: address(alphaHandler), selectors: selectors}));
        targetSelector(FuzzSelector({addr: address(betaHandler), selectors: selectors}));
    }

    function invariant_conservationAndPositionAccounting() public view {
        assertTrue(hook.custodyIsSolvent(alphaPool));
        assertTrue(hook.custodyIsSolvent(betaPool));
        assertTrue(hook.claimsAreConserved());
        alphaHandler.assertActionAccounting();
        betaHandler.assertActionAccounting();
        _assertPositions(alphaHandler);
        _assertPositions(betaHandler);
    }

    function _assertPositions(LooongInvariantHandler handler) private view {
        uint256 length = handler.trackedPositionCount();
        for (uint256 i; i < length; ++i) {
            uint256 positionId = handler.trackedPositionId(i);
            (
                address owner,,,
                uint128 initialTokens,
                uint128 remainingTokens,
                uint128 soldTokens,
                uint128 withdrawnTokens,
                uint256 initialBasis,
                uint256 remainingBasis,
                uint256 soldBasis,
                uint256 withdrawnBasis,
            ) = hook.positions(positionId);
            if (owner == address(0)) continue;
            assertEq(PoolId.unwrap(hook.positionPools(positionId)), PoolId.unwrap(handler.poolId()));
            assertEq(initialTokens, remainingTokens + soldTokens + withdrawnTokens);
            assertEq(initialBasis, remainingBasis + soldBasis + withdrawnBasis);
        }
    }

    function afterInvariant() external view {
        alphaHandler.assertAllActionsLive();
        betaHandler.assertAllActionsLive();
    }

    function _primeHandler(LooongInvariantHandler handler) private {
        handler.seedPositions();
        handler.actionBuy(0, 0.01 ether);
        handler.actionSell(0);
        handler.actionWithdraw(1);
        handler.actionActivate(2);
        handler.actionOrdinarySwap(0.01 ether);
        handler.actionClaimBase();
        handler.actionClaimRebate(0);
        handler.actionClaimReward(1);
    }

    function _launchWithOrdering(
        LooongMarketCoordinatorV1 coordinator,
        address beneficiary,
        string memory name,
        string memory symbol,
        uint256 saltStart,
        bool subjectBeforeWeth
    ) private returns (address subject, PoolId poolId) {
        for (uint256 salt = saltStart; salt < saltStart + 1_000; ++salt) {
            LooongMarketCoordinatorV1.LaunchArgs memory args = LooongMarketCoordinatorV1.LaunchArgs({
                name: name,
                symbol: symbol,
                tagline: "Stateful shared-root proof",
                logoURI: "ipfs://invariant",
                expectedCreator: address(this),
                feeBeneficiary: beneficiary,
                deploymentSalt: bytes32(salt),
                sqrtPriceX96: Constants.SQRT_PRICE_1_1
            });
            address predicted = coordinator.previewTokenAddress(args);
            if ((predicted < address(weth)) != subjectBeforeWeth) continue;
            return coordinator.openTokenMarket(args, predicted);
        }
        revert("ordered token address not found");
    }

    function _validSalt(LooongHookFactory targetFactory) private view returns (bytes32 salt) {
        uint160 flags = targetFactory.REQUIRED_FLAGS();
        uint160 mask = targetFactory.ALL_FLAGS();
        bytes32 codeHash = targetFactory.creationCodeHash();
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(targetFactory), salt, codeHash)))));
            if (uint160(predicted) & mask == flags) return salt;
        }
        revert("salt not found");
    }
}
