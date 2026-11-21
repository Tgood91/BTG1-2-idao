// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../BushidoGovernanceV1_1.sol";
import "../script/DeployGovernanceV1_1.s.sol";
import "./MockRunes.sol";
import "./WrappedRunesVotesTest.sol";

contract Target {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }
}

contract BushidoGovernanceV1_1Test is Test {
    MockRunes runes;
    WrappedRunesVotesTest wrunes;
    TimelockController timelock;
    BushidoGovernanceV1_1 governor;
    DeployGovernanceV1_1 deployer;
    Target target;

    address alice = makeAddr("alice"); // 10% of supply, delegated
    address bob = makeAddr("bob"); // 1% of supply, delegated
    address carol = makeAddr("carol"); // the rest, not delegated
    address multisig = makeAddr("securityMultisig");

    function setUp() public {
        vm.warp(1_700_000_000);

        runes = new MockRunes();
        wrunes = new WrappedRunesVotesTest(runes);
        _wrap(alice, 100 ether, true);
        _wrap(bob, 10 ether, true);
        _wrap(carol, 890 ether, false);

        deployer = new DeployGovernanceV1_1();
        (governor, timelock) = deployer.deploy(
            DeployGovernanceV1_1.Config({
                token: address(wrunes),
                proposalThreshold: 0,
                existingTimelock: address(0),
                securityMultisig: multisig,
                v1Governor: address(0)
            })
        );
        target = new Target();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _wrap(address who, uint256 amount, bool delegateSelf) internal {
        runes.mint(who, amount);
        vm.startPrank(who);
        runes.approve(address(wrunes), amount);
        wrunes.depositFor(who, amount);
        if (delegateSelf) wrunes.delegate(who);
        vm.stopPrank();
    }

    function _proposal()
        internal
        view
        returns (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 descHash)
    {
        t = new address[](1);
        t[0] = address(target);
        v = new uint256[](1);
        c = new bytes[](1);
        c[0] = abi.encodeCall(Target.set, (42));
        descHash = keccak256(bytes("Set target to 42"));
    }

    function _propose() internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _proposal();
        vm.prank(alice);
        id = governor.propose(t, v, c, "Set target to 42");
    }

    // --- configuration ---

    function test_Config() public view {
        assertEq(governor.name(), "BushidoGovernance V1.1");
        (, string memory domainName, string memory domainVersion,,,,) = governor.eip712Domain();
        assertEq(domainName, "BushidoGovernance V1.1");
        assertEq(domainVersion, "1");
        assertEq(governor.votingDelay(), 1 days);
        assertEq(governor.votingPeriod(), 7 days);
        assertEq(governor.proposalThreshold(), 0);
        assertEq(governor.quorumNumerator(), 4);
        assertEq(address(governor.token()), address(wrunes));
        assertEq(governor.timelock(), address(timelock));
        assertEq(governor.CLOCK_MODE(), "mode=timestamp");
        assertEq(timelock.getMinDelay(), 2 days);
    }

    function test_VotesAreOneWRuneOneVote() public view {
        assertEq(governor.getVotes(alice, vm.getBlockTimestamp() - 1), 100 ether);
        assertEq(governor.getVotes(carol, vm.getBlockTimestamp() - 1), 0); // not delegated
    }

    // --- constructor reverts ---

    function test_RevertWhen_TokenIsEOA() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(BushidoGovernanceV1_1.InvalidContractAddress.selector, eoa));
        new BushidoGovernanceV1_1(IVotes(eoa), timelock, 0);
    }

    function test_RevertWhen_TokenIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(BushidoGovernanceV1_1.InvalidContractAddress.selector, address(0)));
        new BushidoGovernanceV1_1(IVotes(address(0)), timelock, 0);
    }

    function test_RevertWhen_TimelockIsEOA() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(BushidoGovernanceV1_1.InvalidContractAddress.selector, eoa));
        new BushidoGovernanceV1_1(wrunes, TimelockController(payable(eoa)), 0);
    }

    function test_RevertWhen_TimelockIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(BushidoGovernanceV1_1.InvalidContractAddress.selector, address(0)));
        new BushidoGovernanceV1_1(wrunes, TimelockController(payable(address(0))), 0);
    }

    // --- lifecycle ---

    function test_FullLifecycle() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _proposal();
        uint256 id = _propose();
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));

        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));
        vm.prank(alice);
        governor.castVote(id, 1);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 100 ether);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        governor.queue(t, v, c, h);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(vm.getBlockTimestamp() + 2 days);
        governor.execute(t, v, c, h);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
        assertEq(target.value(), 42);
    }

    function test_QuorumNotReachedBelowFourPercent() public {
        uint256 id = _propose();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(bob); // 1% of supply, under the 4% quorum (40 WRunes)
        governor.castVote(id, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        assertEq(governor.quorum(governor.proposalSnapshot(id)), 40 ether);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _proposal();
        vm.expectRevert();
        governor.queue(t, v, c, h);
    }

    function test_RevertWhen_ExecutedBeforeTimelockDelay() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _proposal();
        uint256 id = _propose();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(alice);
        governor.castVote(id, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        governor.queue(t, v, c, h);

        vm.warp(vm.getBlockTimestamp() + 2 days - 1);
        vm.expectRevert();
        governor.execute(t, v, c, h);
        assertEq(target.value(), 0);
    }

    // --- deploy script wiring ---

    function test_DeployerRenouncedAdmin() public view {
        (, address broadcaster,) = _defaultCallers();
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), broadcaster));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(deployer)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        // Only the timelock administers itself.
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), multisig));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
    }

    function test_DeployWiresExistingTimelock() public {
        (BushidoGovernanceV1_1 gov2, TimelockController tl2) = deployer.deploy(
            DeployGovernanceV1_1.Config({
                token: address(wrunes),
                proposalThreshold: 5 ether,
                existingTimelock: address(timelock),
                securityMultisig: address(0),
                v1Governor: address(governor)
            })
        );
        assertEq(address(tl2), address(timelock));
        assertEq(gov2.timelock(), address(timelock));
        assertEq(gov2.proposalThreshold(), 5 ether);
        // The existing timelock's roles are untouched: the migration calls are only logged.
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(gov2)));
    }

    function _defaultCallers() internal pure returns (uint8, address, address) {
        // forge-std's default broadcaster when no --sender / key is given.
        return (0, 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, address(0));
    }
}
