// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";
import {RedemptionQueue} from "../../src/exercises/RedemptionQueue.sol";

/// @title Ex6 — the two bridge invariants
/// @notice Invariant testing flips the usual test around: let the machine call operations
///         randomly and repeatedly, then ask "no matter how it thrashes, does this property
///         still hold?" That is how a bridge should be tested — you will never guess the order
///         an attacker does things in.
///
///         Acceptance: make exercise
///
/// @dev The handler exercises Ex5 through bounded valid actions. A separate lifecycle test
///      verifies that enqueue, settle and claim reach meaningful state changes.
///
///      How it works: Foundry picks a function from the handler at random, picks random
///      arguments, calls it, and repeats N times; after each round it runs every invariant_*
///      function. The first failed assertion is a counterexample.
contract BridgeHandler is Test {
    MockUSDC internal usdc;
    TBillToken internal tBill;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address[3] public users;

    /// @dev Bookkeeping: proves the fuzzer really reached the handler instead of idling
    uint256 public ghost_enqueues;
    uint256 public ghost_settles;
    uint256 public ghost_claims;

    constructor(MockUSDC usdc_, TBillToken tBill_, TBillVault vault_, RedemptionQueue queue_) {
        usdc = usdc_;
        tBill = tBill_;
        vault = vault_;
        queue = queue_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 100_000e6);
        }
    }

    /// @dev Given — pay USDC, receive shares at today's NAV
    function subscribe(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.subscribe(amount);
        vm.stopPrank();
    }

    /// @dev Given — the reporter moves the NAV. Kept inside a sane band so the fuzzer spends
    ///      its budget on the queue rather than on absurd prices.
    function attest(uint256 navSeed) external {
        vault.attest(int256(bound(navSeed, 0.5e8, 2e8)));
    }

    /// @dev Given — the SPV wires cash back into the vault, the way T+1 proceeds would arrive
    function fundVault(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        usdc.approve(address(vault), amount);
        vault.depositReserves(amount);
    }

    /// @dev Escrow a bounded position owned by one of the KYC'd users.
    function enqueue(uint256 userSeed, uint256 shares) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        uint256 balance = tBill.balanceOf(user);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);

        vm.startPrank(user);
        tBill.approve(address(queue), shares);
        queue.enqueue(shares);
        vm.stopPrank();
        ++ghost_enqueues;
    }

    /// @dev A successful call with an insufficient budget need not settle any tickets.
    function settle(uint256 assets) external {
        uint256 reserves = vault.reserveBalance();
        if (reserves == 0) return;
        assets = bound(assets, 1, reserves);

        uint256 previousHead = queue.head();
        queue.settle(assets);
        // A dust ticket can advance the head even though its rounded payout is zero.
        if (queue.head() > previousHead) ++ghost_settles;
    }

    /// @dev Only call claim when this user has a settled payout to collect.
    function claim(uint256 userSeed) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        if (queue.claimable(user) == 0) return;

        vm.prank(user);
        queue.claim();
        ++ghost_claims;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;
    BridgeHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        MockPriceFeed feed = new MockPriceFeed(1e8);
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        compliance.setWhitelisted(address(queue), true);

        handler = new BridgeHandler(usdc, tBill, vault, queue);
        // Give fundVault a real balance so the invariant campaign explores reserve top-ups.
        usdc.faucet(address(handler), 300_000e6);

        for (uint256 i; i < 3; ++i) {
            compliance.setWhitelisted(handler.users(i), true);
        }
        compliance.setWhitelisted(address(handler), true);

        vault.grantRole(vault.REPORTER_ROLE(), address(handler));
        vault.grantRole(vault.OPERATOR_ROLE(), address(handler));
        queue.grantRole(queue.SETTLER_ROLE(), address(handler));

        // Let the fuzzer call only the handler's own actions, not its inherited helpers
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BridgeHandler.subscribe.selector;
        selectors[1] = BridgeHandler.attest.selector;
        selectors[2] = BridgeHandler.fundVault.selector;
        selectors[3] = BridgeHandler.enqueue.selector;
        selectors[4] = BridgeHandler.settle.selector;
        selectors[5] = BridgeHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Compare escrow with the actual ticket ledger, as well as its cached totals.
    ///      Scope: the six handler actions never transfer shares directly to the queue.
    ///      Unsolicited share donations would make escrow exceed pending shares instead.
    function invariant_EscrowConservation() public view {
        uint256 outstandingShares;
        uint256 outstandingAssets;
        uint256 length = queue.queueLength();
        uint256 head = queue.head();
        assertLe(head, length, "head must remain inside the ticket ledger");

        for (uint256 i; i < length; ++i) {
            RedemptionQueue.Request memory request = queue.requestAt(i);
            if (i < head) {
                assertTrue(request.settled, "every ticket before head must be settled");
            } else {
                assertFalse(request.settled, "FIFO forbids settling tickets after head");
                outstandingShares += request.shares;
                outstandingAssets += request.assetsLocked;
            }
        }

        assertEq(queue.pendingShares(), outstandingShares, "pending shares must match tickets");
        assertEq(queue.pendingAssets(), outstandingAssets, "pending assets must match tickets");
        assertEq(
            tBill.balanceOf(address(queue)), outstandingShares, "escrow must back unsettled tickets"
        );
    }

    /// @dev Settled obligations are fully backed by cash already held by the queue.
    ///      Only the handler's three users can enqueue in this campaign, so this sum
    ///      includes every possible claimant. It says nothing about off-chain backing.
    function invariant_SettlementSolvency() public view {
        uint256 claimableAssets;
        for (uint256 i; i < 3; ++i) {
            claimableAssets += queue.claimable(handler.users(i));
        }

        assertEq(
            queue.totalClaimable(), claimableAssets, "claimable total must match user balances"
        );
        assertGe(
            usdc.balanceOf(address(queue)), queue.totalClaimable(), "settled payouts must be funded"
        );
    }

    /// @dev Explicitly exercise each handler action so idle guards cannot make Ex6 pass alone.
    function test_Ex6_HandlerExecutesTheRedemptionLifecycle() public {
        handler.enqueue(0, 1e18);
        handler.settle(1e6);
        handler.claim(0);
        assertEq(handler.ghost_enqueues(), 0);
        assertEq(handler.ghost_settles(), 0);
        assertEq(handler.ghost_claims(), 0);

        handler.subscribe(0, 1000e6);
        handler.subscribe(1, 1000e6);
        handler.attest(2e8);
        handler.enqueue(0, 300e18);
        handler.enqueue(1, 500e18);
        assertEq(handler.ghost_enqueues(), 2);
        assertEq(queue.pendingShares(), 800e18);
        assertEq(queue.pendingAssets(), 1600e6);

        // Later NAV changes cannot alter either ticket's locked payout.
        handler.attest(0.5e8);
        handler.settle(599e6);
        assertEq(queue.head(), 0);
        assertEq(handler.ghost_settles(), 0);
        invariant_EscrowConservation();
        invariant_SettlementSolvency();

        handler.settle(600e6);
        assertEq(queue.head(), 1);
        assertEq(queue.claimable(handler.users(0)), 600e6);
        handler.claim(0);
        assertEq(usdc.balanceOf(handler.users(0)), 99_600e6);
        assertEq(queue.totalClaimable(), 0);

        uint256 reservesBefore = vault.reserveBalance();
        handler.fundVault(123e6);
        assertEq(vault.reserveBalance(), reservesBefore + 123e6);
        handler.settle(1000e6);
        assertEq(queue.claimable(handler.users(1)), 1000e6);
        invariant_EscrowConservation();
        invariant_SettlementSolvency();
        handler.claim(1);

        // An empty claim or queue does not inflate the successful action counters.
        handler.claim(0);
        handler.settle(1e6);
        assertEq(handler.ghost_settles(), 2);
        assertEq(handler.ghost_claims(), 2);
        assertEq(usdc.balanceOf(handler.users(1)), 100_000e6);
        assertEq(queue.head(), queue.queueLength());
        assertEq(queue.pendingShares(), 0);
        assertEq(queue.pendingAssets(), 0);
        assertEq(queue.totalClaimable(), 0);
        invariant_EscrowConservation();
        invariant_SettlementSolvency();
    }
}
