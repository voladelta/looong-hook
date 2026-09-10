// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {LooongHook} from "../../src/LooongHook.sol";
import {LooongHookFactory} from "../../src/LooongHookFactory.sol";
import {LooongMarketCoordinatorV1} from "../../src/LooongMarketCoordinatorV1.sol";
import {LooongRouter} from "../../src/LooongRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {ForcedWethClaims} from "../utils/ForcedWethClaims.sol";
import {InvariantActionAccounting} from "../utils/InvariantActionAccounting.sol";

contract LooongMarketsHandler is InvariantActionAccounting {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Position and swap matrix, three claims, wrong pool, and both unsolicited-claim entry paths.
    uint256 private constant MODES = 14;

    struct OutputBalance {
        IERC20 token;
        uint256 beforeSwap;
    }

    LooongHook public immutable hook;
    LooongRouter public immutable router;
    MockERC20 public immutable weth;
    address public immutable beneficiary;
    address[2] public subjects;
    PoolId[2] public pools;
    ForcedWethClaims private immutable donor;
    uint256 public forcedClaims;
    uint256[][2] private positions;
    uint256[2] private baseFeesByMarket;

    constructor(LooongMarketCoordinatorV1 coordinator, MockERC20 weth_, address[2] memory subjects_) {
        hook = coordinator.hook();
        router = coordinator.router();
        weth = weth_;
        beneficiary = msg.sender;
        subjects = subjects_;
        donor = new ForcedWethClaims(hook.manager(), IERC20(address(weth_)));
        weth_.mint(address(this), 1_000 ether);
        weth_.approve(address(router), type(uint256).max);
        for (uint256 market; market < 2; ++market) {
            pools[market] = router.poolKey(subjects_[market]).toId();
            IERC20(subjects_[market]).approve(address(router), type(uint256).max);
        }
    }

    // Each ordering must execute each mode successfully before randomized interleaving starts.
    function seed() external {
        for (uint256 market; market < 2; ++market) {
            for (uint256 mode; mode < MODES; ++mode) {
                action(market, mode, 0);
            }
        }
    }

    function action(uint256 marketSeed, uint256 modeSeed, uint256 amountSeed) public {
        uint256 market = marketSeed % 2;
        uint256 mode = modeSeed % MODES;
        bytes4 actionId = bytes4(uint32(1 + market * MODES + mode));
        bytes32 otherBefore = _poolFingerprint(1 - market);
        uint256 baseFeesBefore = hook.totalBaseFeeLiability();
        _beginAction(actionId);

        try this.perform(market, mode, amountSeed) {
            if (mode == 11) _recordUnexpectedFailure(actionId);
            else _recordSuccess(actionId);
        } catch (bytes memory reason) {
            if (mode >= 8 && mode <= 10) {
                _classifyRevert(actionId, reason, LooongHook.ClaimUnavailable.selector);
            } else if (mode == 11) {
                _classifyRevert(actionId, reason, LooongHook.InvalidPool.selector);
            } else {
                _recordUnexpectedFailure(actionId);
            }
        }

        // Attribute the observed global fee change to the market that executed the action.
        // A later pool-scoped claim must pay exactly this independent running entitlement.
        uint256 baseFeesAfter = hook.totalBaseFeeLiability();
        if (baseFeesAfter >= baseFeesBefore) baseFeesByMarket[market] += baseFeesAfter - baseFeesBefore;
        else baseFeesByMarket[market] -= baseFeesBefore - baseFeesAfter;

        assertEq(_poolFingerprint(1 - market), otherBefore, "other market changed");
        assertConservation();
    }

    /// @dev The self-call catches one complete production action, including its assertions.
    function perform(uint256 market, uint256 mode, uint256 amountSeed) external {
        require(msg.sender == address(this), "handler only");
        if (mode == 0) {
            uint128 amount = uint128(bound(amountSeed, 0.01 ether, 0.02 ether));
            uint256 id = router.buy(subjects[market], amount, 1, _limit(market, true), uint64(block.timestamp));
            positions[market].push(id);
            (,,,,,,, uint256 basis,,,,) = hook.positions(id);
            assertEq(basis, amount, "buy basis differs from payment");
        } else if (mode <= 3 || mode == 11) {
            _positionAction(market, mode, amountSeed);
        } else if (mode <= 7) {
            _swapAction(market, mode, amountSeed);
        } else if (mode <= 10) {
            _claimAction(market, mode);
        } else {
            _donateClaims(mode == 12, amountSeed);
        }
    }

    function _positionAction(uint256 market, uint256 mode, uint256 amountSeed) private {
        address subject = subjects[market];
        uint256 id = positions[market][amountSeed % positions[market].length];
        (, uint64 openedAt,,, uint128 remaining,,,,,,,) = hook.positions(id);
        uint128 amount = remaining / 32;
        if (mode == 1) {
            router.sell(subject, id, amount, 1, _limit(market, false), uint64(block.timestamp));
        } else if (mode == 2) {
            uint256 beforeBalance = IERC20(subject).balanceOf(address(this));
            hook.withdraw(id, amount);
            assertEq(IERC20(subject).balanceOf(address(this)) - beforeBalance, amount);
        } else if (mode == 3) {
            uint256 maturity = uint256(openedAt) + hook.MATURITY();
            if (block.timestamp < maturity) vm.warp(maturity);
            hook.activatePosition(id);
        } else {
            router.sell(subjects[1 - market], id, amount, 1, _limit(1 - market, false), uint64(block.timestamp));
        }
    }

    function _swapAction(uint256 market, uint256 mode, uint256 amountSeed) private {
        address subject = subjects[market];
        bool buy = mode == 4 || mode == 6;
        if (mode <= 5) {
            uint128 input = buy
                ? uint128(bound(amountSeed, 0.01 ether, 0.02 ether))
                : uint128(IERC20(subject).balanceOf(address(this)) / 32);
            uint256 output = router.swapExactInput(
                subject, buy, input, 1, address(this), _limit(market, buy), uint64(block.timestamp)
            );
            assertGt(output, 0);
        } else {
            _exactOutput(market, buy, uint128(bound(amountSeed, 1e10, 1e11)));
        }
    }

    function _exactOutput(uint256 market, bool buy, uint128 output) private {
        bytes memory witness = buy
            ? bytes("")
            : abi.encode(hook.WITNESS_DOMAIN(), hook.quoteExactOutputGross(pools[market], output, true));
        OutputBalance memory balance;
        balance.token = buy ? IERC20(subjects[market]) : IERC20(address(weth));
        balance.beforeSwap = balance.token.balanceOf(address(this));
        uint256 input = router.swapExactOutput(
            subjects[market], buy, output, 1 ether, address(this), _limit(market, buy), uint64(block.timestamp), witness
        );
        assertGt(input, 0);
        assertEq(balance.token.balanceOf(address(this)) - balance.beforeSwap, output, "inexact output");
    }

    function _claimAction(uint256 market, uint256 mode) private {
        PoolId pool = pools[market];
        address recipient = mode == 8 ? beneficiary : address(this);
        uint256 beforeBalance = weth.balanceOf(recipient);
        uint256 beforeClaims = hook.manager().balanceOf(address(hook), uint160(address(weth)));
        uint256 claimed;
        if (mode == 8) {
            vm.prank(beneficiary);
            claimed = hook.claimBaseFees(pool, recipient);
            assertEq(claimed, baseFeesByMarket[market], "base fees paid from wrong market");
        } else if (mode == 9) {
            claimed = hook.claimRebate(pool, recipient);
        } else {
            claimed = hook.claimRewards(pool, recipient);
        }
        assertGt(claimed, 0);
        assertEq(weth.balanceOf(recipient) - beforeBalance, claimed, "claim payment");
        assertEq(beforeClaims - hook.manager().balanceOf(address(hook), uint160(address(weth))), claimed);
    }

    function _donateClaims(bool transferClaim, uint256 amountSeed) private {
        uint256 amount = bound(amountSeed, 1, 1 ether);
        weth.mint(address(donor), amount);
        donor.donate(address(hook), amount, transferClaim);
        forcedClaims += amount;
    }

    function assertConservation() public view {
        uint256 actualClaims = hook.manager().balanceOf(address(hook), uint160(address(weth)));
        assertEq(actualClaims, hook.accountedWethClaims() + forcedClaims, "forced claim surplus changed");
        assertEq(
            hook.accountedWethClaims() * hook.REWARD_PRECISION(), hook.accountingLiabilityScaled(), "claims liabilities"
        );
        assertTrue(hook.claimsAreConserved(), "claims not conserved");
        assertEq(baseFeesByMarket[0] + baseFeesByMarket[1], hook.totalBaseFeeLiability());

        for (uint256 market; market < 2; ++market) {
            assertTrue(hook.poolIsLive(pools[market]));
            assertEq(PoolId.unwrap(router.poolKey(subjects[market]).toId()), PoolId.unwrap(pools[market]));
            uint256 custody;
            uint256 shares;
            for (uint256 i; i < positions[market].length; ++i) {
                uint256 id = positions[market][i];
                LooongHook.Position memory position = _position(id);
                assertEq(position.owner, address(this));
                assertEq(PoolId.unwrap(hook.positionPools(id)), PoolId.unwrap(pools[market]), "position pool");
                assertEq(
                    position.initialTokens,
                    uint256(position.remainingTokens) + position.soldTokens + position.withdrawnTokens
                );
                assertEq(position.initialBasis, position.remainingBasis + position.soldBasis + position.withdrawnBasis);
                custody += position.remainingTokens;
                if (position.rewardActive) shares += position.remainingTokens;
            }
            assertEq(hook.ownerShares(pools[market], address(this)), shares);
            assertEq(hook.totalCustodiedTokens(pools[market]), custody);
            assertEq(hook.totalCustodiedByToken(subjects[market]), custody);
            IERC20 token = IERC20(subjects[market]);
            assertEq(token.balanceOf(address(hook)), custody);
            assertEq(
                token.balanceOf(address(hook)) + token.balanceOf(address(hook.manager()))
                    + token.balanceOf(address(this)) + token.balanceOf(address(0xdead)),
                token.totalSupply(),
                "token conservation"
            );
        }
    }

    function assertActionCoverage() external view {
        for (uint256 market; market < 2; ++market) {
            for (uint256 mode; mode < MODES; ++mode) {
                bytes4 id = bytes4(uint32(1 + market * MODES + mode));
                if (mode != 11) {
                    _assertActionLive(id);
                } else {
                    ActionCounts storage counts = actionCounts[id];
                    assertGt(counts.expectedReverts, 0, "cross-pool rejection absent");
                    assertEq(counts.attempts, counts.expectedReverts);
                    assertEq(counts.unexpectedFailures, 0);
                }
            }
        }
    }

    function _position(uint256 id) private view returns (LooongHook.Position memory position) {
        (bool ok, bytes memory result) = address(hook).staticcall(abi.encodeWithSignature("positions(uint256)", id));
        require(ok, "position read");
        return abi.decode(result, (LooongHook.Position));
    }

    function _poolFingerprint(uint256 market) private view returns (bytes32 fingerprint) {
        PoolId pool = pools[market];
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = hook.manager().getSlot0(pool);
        fingerprint = keccak256(abi.encode(price, tick, protocolFee, lpFee, hook.manager().getLiquidity(pool)));
        fingerprint = keccak256(
            abi.encode(
                fingerprint,
                hook.totalCustodiedTokens(pool),
                hook.ownerNonces(pool, address(this)),
                hook.ownerShares(pool, address(this))
            )
        );
        fingerprint = keccak256(
            abi.encode(
                fingerprint,
                hook.ownerScaledRewardCredit(pool, address(this)),
                hook.sellerRebates(pool, address(this)),
                hook.quoteExactOutputGross(pool, 1, true),
                hook.quoteExactOutputGross(pool, 999, true),
                IERC20(subjects[market]).balanceOf(address(this))
            )
        );
        for (uint256 i; i < positions[market].length; ++i) {
            uint256 id = positions[market][i];
            fingerprint = keccak256(abi.encode(fingerprint, hook.positionPools(id), _position(id)));
        }
    }

    function _limit(uint256 market, bool buy) private view returns (uint160) {
        bool zeroForOne = buy ? address(weth) < subjects[market] : subjects[market] < address(weth);
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}

contract LooongMarketsInvariantTest is StdInvariant, BaseTest {
    LooongMarketsHandler private handler;

    function setUp() public {
        deployArtifactsAndLabel();
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        LooongRouter router = new LooongRouter(poolManager, expected, IERC20(address(weth)));
        LooongHookFactory factory = new LooongHookFactory(poolManager, expected, address(router), IERC20(address(weth)));
        LooongMarketCoordinatorV1 coordinator =
            new LooongMarketCoordinatorV1(poolManager, IERC20(address(weth)), _hookSalt(factory), router, factory);
        address[2] memory subjects;
        subjects[0] = _launch(coordinator, true);
        subjects[1] = _launch(coordinator, false);
        assertLt(uint160(subjects[0]), uint160(address(weth)));
        assertGt(uint160(subjects[1]), uint160(address(weth)));

        handler = new LooongMarketsHandler(coordinator, weth, subjects);
        handler.seed();
        handler.assertActionCoverage();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.action.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_twoMarketsConserveAndRemainIsolated() public view {
        handler.assertConservation();
        handler.assertActionCoverage();
    }

    function afterInvariant() external view {
        handler.assertActionCoverage();
    }

    function _launch(LooongMarketCoordinatorV1 coordinator, bool subjectFirst) private returns (address subject) {
        LooongMarketCoordinatorV1.LaunchArgs memory args = LooongMarketCoordinatorV1.LaunchArgs({
            name: "Invariant market",
            symbol: "INV",
            tagline: "Two markets",
            logoURI: "ipfs://invariant",
            expectedCreator: address(this),
            feeBeneficiary: address(this),
            deploymentSalt: bytes32(0),
            sqrtPriceX96: uint160(1 << 96)
        });
        for (uint256 i; i < 2_000; ++i) {
            args.deploymentSalt = bytes32(i);
            subject = coordinator.previewTokenAddress(args);
            if ((subject < address(coordinator.weth())) == subjectFirst) {
                (subject,) = coordinator.openTokenMarket(args, subject);
                return subject;
            }
        }
        revert("token ordering salt not found");
    }

    function _hookSalt(LooongHookFactory factory) private view returns (bytes32 salt) {
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            if (uint160(factory.computeAddress(salt)) & factory.ALL_FLAGS() == factory.REQUIRED_FLAGS()) return salt;
        }
        revert("hook salt not found");
    }
}
