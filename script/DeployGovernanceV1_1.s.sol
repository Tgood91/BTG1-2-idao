// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "../BushidoGovernanceV1_1.sol";

/// @title DeployGovernanceV1_1
/// @notice Deploys BushidoGovernanceV1_1. Dry-run it first (no --broadcast) and read the logs.
///
/// Environment variables:
///   WRUNES_ADDRESS      required  the deployed WrappedRunesVotes (WRunes) token
///   PROPOSAL_THRESHOLD  optional  WRunes votes needed to propose, in wei (default 0 = anyone)
///   TIMELOCK_ADDRESS    optional  set: wire V1.1 to this existing timelock (migration from V1)
///                                 unset: deploy a new TimelockController
///   SECURITY_MULTISIG   optional  new-timelock path only: gets CANCELLER_ROLE when non-zero
///   V1_GOVERNOR_ADDRESS optional  existing-timelock path only: the V1 governor, to log its revokeRole calls
///
/// Path A (TIMELOCK_ADDRESS set): only the governor is deployed. The deployer cannot change the timelock's roles,
/// so the script logs the exact grantRole / revokeRole calls; they must be passed as a V1 proposal (target = the
/// timelock, value 0), or sent by whoever holds the timelock's admin role.
///
/// Path B (TIMELOCK_ADDRESS unset): deploys a TimelockController (2 days min delay) with the deployer as temporary
/// admin, deploys the governor, grants PROPOSER_ROLE to the governor, EXECUTOR_ROLE to address(0) (anyone may
/// execute), CANCELLER_ROLE to SECURITY_MULTISIG (if set), then the deployer renounces DEFAULT_ADMIN_ROLE.
contract DeployGovernanceV1_1 is Script {
    uint256 public constant NEW_TIMELOCK_MIN_DELAY = 2 days;

    struct Config {
        address token;
        uint256 proposalThreshold;
        address existingTimelock;
        address securityMultisig;
        address v1Governor;
    }

    function run() external returns (BushidoGovernanceV1_1 governor, TimelockController timelock) {
        Config memory cfg = Config({
            token: vm.envAddress("WRUNES_ADDRESS"),
            proposalThreshold: vm.envOr("PROPOSAL_THRESHOLD", uint256(0)),
            existingTimelock: vm.envOr("TIMELOCK_ADDRESS", address(0)),
            securityMultisig: vm.envOr("SECURITY_MULTISIG", address(0)),
            v1Governor: vm.envOr("V1_GOVERNOR_ADDRESS", address(0))
        });
        return deploy(cfg);
    }

    function deploy(Config memory cfg) public returns (BushidoGovernanceV1_1 governor, TimelockController timelock) {
        if (cfg.existingTimelock != address(0)) {
            return _wireExistingTimelock(cfg);
        }
        return _deployWithNewTimelock(cfg);
    }

    function _wireExistingTimelock(Config memory cfg)
        internal
        returns (BushidoGovernanceV1_1 governor, TimelockController timelock)
    {
        timelock = TimelockController(payable(cfg.existingTimelock));

        vm.startBroadcast();
        governor = new BushidoGovernanceV1_1(IVotes(cfg.token), timelock, cfg.proposalThreshold);
        vm.stopBroadcast();

        console.log("BushidoGovernanceV1_1:", address(governor));
        console.log("Existing timelock:    ", address(timelock));
        console.log("");
        console.log("Migration calls (target = timelock, value = 0), e.g. as one V1 proposal:");

        bytes32 proposer = timelock.PROPOSER_ROLE();
        bytes32 canceller = timelock.CANCELLER_ROLE();

        console.log("1. grantRole(PROPOSER_ROLE, V1.1)");
        console.logBytes(abi.encodeCall(timelock.grantRole, (proposer, address(governor))));
        console.log("2. grantRole(CANCELLER_ROLE, V1.1)");
        console.logBytes(abi.encodeCall(timelock.grantRole, (canceller, address(governor))));

        if (cfg.v1Governor != address(0)) {
            console.log("3. revokeRole(PROPOSER_ROLE, V1)");
            console.logBytes(abi.encodeCall(timelock.revokeRole, (proposer, cfg.v1Governor)));
            console.log("4. revokeRole(CANCELLER_ROLE, V1)");
            console.logBytes(abi.encodeCall(timelock.revokeRole, (canceller, cfg.v1Governor)));
        } else {
            console.log("Set V1_GOVERNOR_ADDRESS to also log the revokeRole calls for V1.");
        }
    }

    function _deployWithNewTimelock(Config memory cfg)
        internal
        returns (BushidoGovernanceV1_1 governor, TimelockController timelock)
    {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        address[] memory none = new address[](0);
        timelock = new TimelockController(NEW_TIMELOCK_MIN_DELAY, none, none, deployer);
        governor = new BushidoGovernanceV1_1(IVotes(cfg.token), timelock, cfg.proposalThreshold);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        if (cfg.securityMultisig != address(0)) {
            timelock.grantRole(timelock.CANCELLER_ROLE(), cfg.securityMultisig);
        }
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopBroadcast();

        console.log("BushidoGovernanceV1_1:", address(governor));
        console.log("TimelockController:   ", address(timelock));
        console.log("Deployer (admin renounced):", deployer);
        if (cfg.securityMultisig == address(0)) {
            console.log("WARNING: SECURITY_MULTISIG unset, no canceller was granted.");
        }
    }
}
