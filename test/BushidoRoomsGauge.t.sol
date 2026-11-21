// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../BushidoGovernanceV1_1.sol";
import "../BushidoRoomsGauge.sol";
import "../script/DeployGovernanceV1_1.s.sol";
import "./MockRunes.sol";
import "./WrappedRunesVotesTest.sol";

contract BushidoRoomsGaugeTest is Test {
    MockRunes runes;
    WrappedRunesVotesTest wrunes;
    BushidoRoomsGauge gauge;
    address owner = makeAddr("timelock");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address funder = makeAddr("funder");
    address roomA = makeAddr("roomA");
    address roomB = makeAddr("roomB");
    address roomC = makeAddr("roomC");

    function setUp() public {
        vm.warp(1_700_000_000);
        runes = new MockRunes();
        wrunes = new WrappedRunesVotesTest(runes);
        _wrap(alice, 300 ether);
        _wrap(bob, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1); // delegations are now before epoch 0's snapshot
        gauge = new BushidoRoomsGauge(wrunes, runes, owner);
        vm.startPrank(owner);
        gauge.addRoom(roomA, "Room A");
        gauge.addRoom(roomB, "Room B");
        gauge.addRoom(roomC, "Room C");
        vm.stopPrank();
        runes.mint(funder, 1_000_000 ether);
        vm.prank(funder);
        runes.approve(address(gauge), type(uint256).max);
    }

    function _wrap(address who, uint256 amount) internal {
        runes.mint(who, amount);
        vm.startPrank(who);
        runes.approve(address(wrunes), amount);
        wrunes.depositFor(who, amount);
        wrunes.delegate(who);
        vm.stopPrank();
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _vote(address who, uint256[] memory ids, uint256[] memory bps) internal {
        vm.prank(who);
        gauge.vote(ids, bps);
    }

    function _nextEpoch() internal {
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    // --- construction and rooms ---

    function test_Config() public view {
        assertEq(gauge.owner(), owner);
        assertEq(address(gauge.votesToken()), address(wrunes));
        assertEq(address(gauge.rewardToken()), address(runes));
        assertEq(gauge.currentEpoch(), 0);
        assertEq(gauge.roomCount(), 3);
        BushidoRoomsGauge.Room memory r = gauge.room(1);
        assertEq(r.recipient, roomB);
        assertTrue(r.active);
        assertEq(r.name, "Room B");
    }

    function test_RevertWhen_ConstructorAddressNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.InvalidContractAddress.selector, eoa));
        new BushidoRoomsGauge(IVotes(eoa), runes, owner);
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.InvalidContractAddress.selector, address(0)));
        new BushidoRoomsGauge(wrunes, IERC20(address(0)), owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BushidoRoomsGauge(wrunes, runes, address(0));
    }

    function test_OnlyOwnerManagesRooms() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gauge.addRoom(alice, "x");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gauge.setRoomActive(0, false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gauge.setRoomRecipient(0, alice);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(BushidoRoomsGauge.ZeroAddress.selector);
        gauge.addRoom(address(0), "x");
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.UnknownRoom.selector, 9));
        gauge.setRoomActive(9, false);
        vm.stopPrank();
    }

    // --- voting ---

    function test_VoteSplitsPower() public {
        _vote(alice, _ids(0, 1), _ids(7_500, 2_500));
        assertEq(gauge.roomWeight(0, 0), 225 ether);
        assertEq(gauge.roomWeight(0, 1), 75 ether);
        assertEq(gauge.totalWeight(0), 300 ether);
    }

    function test_PartialVoteLeavesRestUnused() public {
        _vote(bob, _ids(2), _ids(4_000));
        assertEq(gauge.totalWeight(0), 40 ether);
    }

    function test_ReVoteReplacesPrevious() public {
        _vote(alice, _ids(0, 1), _ids(5_000, 5_000));
        _vote(alice, _ids(2), _ids(10_000));
        assertEq(gauge.roomWeight(0, 0), 0);
        assertEq(gauge.roomWeight(0, 1), 0);
        assertEq(gauge.roomWeight(0, 2), 300 ether);
        assertEq(gauge.totalWeight(0), 300 ether);
        (uint256[] memory ids, uint256[] memory ws) = gauge.ballotOf(0, alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], 2);
        assertEq(ws[0], 300 ether);
    }

    function test_PowerIsSnapshotBeforeEpoch() public {
        // Alice moves all her WRunes to a fresh wallet mid-epoch: no new power this epoch.
        address fresh = makeAddr("fresh");
        vm.prank(fresh);
        wrunes.delegate(fresh);
        vm.prank(alice);
        wrunes.transfer(fresh, 300 ether);
        assertEq(gauge.powerOf(alice), 300 ether);
        assertEq(gauge.powerOf(fresh), 0);
        vm.prank(fresh);
        vm.expectRevert(BushidoRoomsGauge.NoVotingPower.selector);
        gauge.vote(_ids(0), _ids(10_000));
        // Next epoch the snapshot sees the move.
        _nextEpoch();
        assertEq(gauge.powerOf(alice), 0);
        assertEq(gauge.powerOf(fresh), 300 ether);
    }

    function test_RevertWhen_BadBallot() public {
        vm.startPrank(alice);
        vm.expectRevert(BushidoRoomsGauge.LengthMismatch.selector);
        gauge.vote(_ids(0), _ids(1, 2));
        vm.expectRevert(BushidoRoomsGauge.RoomsNotAscending.selector);
        gauge.vote(_ids(1, 1), _ids(1, 1));
        vm.expectRevert(BushidoRoomsGauge.RoomsNotAscending.selector);
        gauge.vote(_ids(1, 0), _ids(1, 1));
        vm.expectRevert(BushidoRoomsGauge.ZeroWeight.selector);
        gauge.vote(_ids(0), _ids(0));
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.WeightsOverMax.selector, 10_001));
        gauge.vote(_ids(0, 1), _ids(5_000, 5_001));
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.UnknownRoom.selector, 7));
        gauge.vote(_ids(7), _ids(1));
        vm.stopPrank();

        vm.prank(owner);
        gauge.setRoomActive(1, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.RoomInactive.selector, 1));
        gauge.vote(_ids(1), _ids(1));

        uint256[] memory many = new uint256[](17);
        for (uint256 i; i < 17; ++i) many[i] = i;
        vm.prank(alice);
        vm.expectRevert(BushidoRoomsGauge.TooManyRooms.selector);
        gauge.vote(many, many);
    }

    function test_EmptyVoteWithdraws() public {
        _vote(alice, _ids(0, 1), _ids(5_000, 5_000));
        _vote(alice, new uint256[](0), new uint256[](0));
        assertEq(gauge.totalWeight(0), 0);
        assertEq(gauge.roomWeight(0, 0), 0);
        assertEq(gauge.roomWeight(0, 1), 0);
        (uint256[] memory ids,) = gauge.ballotOf(0, alice);
        assertEq(ids.length, 0);
        // Withdrawing with no vote cast is a harmless no-op, even with no voting power.
        _vote(makeAddr("nobody"), new uint256[](0), new uint256[](0));
    }

    function test_FreshEpochStartsEmpty() public {
        _vote(alice, _ids(0), _ids(10_000));
        _nextEpoch();
        assertEq(gauge.currentEpoch(), 1);
        assertEq(gauge.totalWeight(1), 0);
        (uint256[] memory ids,) = gauge.ballotOf(1, alice);
        assertEq(ids.length, 0);
    }

    // --- rewards ---

    function test_FullEpochRewards() public {
        vm.prank(funder);
        gauge.fund(0, 1_000 ether);
        _vote(alice, _ids(0, 1), _ids(5_000, 5_000)); // A 150, B 150
        _vote(bob, _ids(1), _ids(10_000)); // B 100  -> A 150/400, B 250/400

        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.EpochNotEnded.selector, 0));
        gauge.claim(0, 0);
        assertEq(gauge.claimable(0, 0), 0);

        _nextEpoch();
        assertEq(gauge.claimable(0, 0), 375 ether);
        assertEq(gauge.claimable(0, 1), 625 ether);
        gauge.claim(0, 0); // anyone may trigger; pays the recipient
        vm.prank(roomB);
        gauge.claim(0, 1);
        assertEq(runes.balanceOf(roomA), 375 ether);
        assertEq(runes.balanceOf(roomB), 625 ether);
        assertEq(runes.balanceOf(address(gauge)), 0);

        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.AlreadyClaimed.selector, 0, 0));
        gauge.claim(0, 0);
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.NothingToClaim.selector, 0, 2));
        gauge.claim(0, 2);
    }

    function test_DeactivatedRoomKeepsWeightCastThisEpoch() public {
        vm.prank(funder);
        gauge.fund(0, 100 ether);
        _vote(alice, _ids(0), _ids(10_000));
        vm.prank(owner);
        gauge.setRoomActive(0, false);
        _nextEpoch();
        gauge.claim(0, 0);
        assertEq(runes.balanceOf(roomA), 100 ether);
    }

    function test_RecipientChangeRedirectsClaim() public {
        vm.prank(funder);
        gauge.fund(0, 100 ether);
        _vote(alice, _ids(0), _ids(10_000));
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        gauge.setRoomRecipient(0, newRecipient);
        _nextEpoch();
        gauge.claim(0, 0);
        assertEq(runes.balanceOf(newRecipient), 100 ether);
        assertEq(runes.balanceOf(roomA), 0);
    }

    function test_FundRules() public {
        vm.startPrank(funder);
        vm.expectRevert(BushidoRoomsGauge.ZeroAmount.selector);
        gauge.fund(0, 0);
        gauge.fund(3, 50 ether); // a later epoch is fine
        assertEq(gauge.epochReward(3), 50 ether);
        gauge.fund(52, 1 ether); // up to 52 epochs ahead
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.EpochTooFarAhead.selector, 53, 52));
        gauge.fund(53, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.EpochTooFarAhead.selector, 1_760_000_000, 52));
        gauge.fund(1_760_000_000, 1 ether); // a timestamp passed by mistake
        vm.stopPrank();
        _nextEpoch();
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.EpochEnded.selector, 0));
        gauge.fund(0, 1 ether);
    }

    function test_RolloverWhenNobodyVoted() public {
        vm.prank(funder);
        gauge.fund(0, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.EpochNotEnded.selector, 0));
        gauge.rollover(0);
        _nextEpoch();
        _nextEpoch();
        gauge.rollover(0);
        assertEq(gauge.epochReward(0), 0);
        assertEq(gauge.epochReward(2), 100 ether);
        vm.expectRevert(BushidoRoomsGauge.ZeroAmount.selector);
        gauge.rollover(0);
    }

    function test_RevertWhen_RolloverEpochHadVotes() public {
        vm.prank(funder);
        gauge.fund(0, 100 ether);
        _vote(bob, _ids(0), _ids(10_000));
        _nextEpoch();
        vm.expectRevert(abi.encodeWithSelector(BushidoRoomsGauge.EpochHadVotes.selector, 0));
        gauge.rollover(0);
    }

    function test_RecoverOnlyUnowedTokens() public {
        vm.prank(funder);
        gauge.fund(0, 100 ether);
        vm.prank(funder);
        runes.transfer(address(gauge), 7 ether); // sent without fund(): owed to no pot
        assertEq(gauge.outstanding(), 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gauge.recoverUnowed(alice);

        address treasury = makeAddr("treasury");
        vm.prank(owner);
        assertEq(gauge.recoverUnowed(treasury), 7 ether);
        assertEq(runes.balanceOf(treasury), 7 ether);
        assertEq(runes.balanceOf(address(gauge)), 100 ether); // the funded pot is untouched

        vm.prank(owner);
        vm.expectRevert(BushidoRoomsGauge.ZeroAmount.selector);
        gauge.recoverUnowed(treasury);

        // After claims, outstanding falls with the payouts and the pot still cannot be recovered.
        _vote(alice, _ids(0), _ids(10_000));
        _nextEpoch();
        gauge.claim(0, 0);
        assertEq(gauge.outstanding(), 0);
    }

    /// Re-votes never double count, and the rooms together can never be paid more than the pot.
    function testFuzz_PayoutNeverExceedsPot(uint96 pot, uint16 a1, uint16 a2, uint16 b1, uint16 b2, uint16 c1)
        public
    {
        pot = uint96(bound(pot, 1, 1_000_000 ether));
        a1 = uint16(bound(a1, 1, 9_999));
        a2 = uint16(bound(a2, 1, MAX_LEFT(a1)));
        b1 = uint16(bound(b1, 1, 10_000));
        b2 = uint16(bound(b2, 1, 9_999));
        c1 = uint16(bound(c1, 1, 10_000 - b2));

        vm.prank(funder);
        gauge.fund(0, pot);
        _vote(alice, _ids(0, 1), _ids(a1, a2));
        _vote(bob, _ids(2), _ids(b1));
        _vote(alice, _ids(1, 2), _ids(b2, c1)); // re-vote

        uint256 sum = gauge.roomWeight(0, 0) + gauge.roomWeight(0, 1) + gauge.roomWeight(0, 2);
        assertEq(sum, gauge.totalWeight(0));
        assertEq(gauge.roomWeight(0, 0), 0);

        _nextEpoch();
        uint256 paid;
        for (uint256 id; id < 3; ++id) {
            uint256 c = gauge.claimable(0, id);
            if (c > 0) paid += gauge.claim(0, id);
        }
        assertLe(paid, pot);
        assertLe(pot - paid, 3); // only rounding dust remains
        assertEq(runes.balanceOf(address(gauge)), pot - paid);
        assertEq(gauge.outstanding(), pot - paid); // dust stays owed, so recovery can never take a pot
    }

    function MAX_LEFT(uint16 used) internal pure returns (uint256) {
        return 10_000 - uint256(used);
    }

    // --- governance wiring: the V1.1 timelock owns the gauge ---

    function test_GovernanceAddsRoomThroughTimelock() public {
        DeployGovernanceV1_1 d = new DeployGovernanceV1_1();
        (BushidoGovernanceV1_1 gov, TimelockController tl) = d.deploy(
            DeployGovernanceV1_1.Config({
                token: address(wrunes),
                proposalThreshold: 0,
                existingTimelock: address(0),
                securityMultisig: address(0),
                v1Governor: address(0)
            })
        );
        BushidoRoomsGauge g = new BushidoRoomsGauge(wrunes, runes, address(tl));
        vm.warp(vm.getBlockTimestamp() + 1);

        address[] memory t = new address[](1);
        t[0] = address(g);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(BushidoRoomsGauge.addRoom, (roomA, "Dojo"));
        bytes32 h = keccak256(bytes("Open the Dojo room"));

        vm.prank(alice);
        uint256 id = gov.propose(t, v, c, "Open the Dojo room");
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(alice);
        gov.castVote(id, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        gov.queue(t, v, c, h);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        gov.execute(t, v, c, h);

        assertEq(g.roomCount(), 1);
        assertEq(g.room(0).name, "Dojo");
    }
}
