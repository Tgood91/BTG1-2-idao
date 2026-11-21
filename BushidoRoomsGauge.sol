// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BushidoRoomsGauge
/// @notice Gauge voting for BTG. Each "room" is a gauge with a recipient. Every week (an epoch) invokers — any
/// holder of delegated WRunes — split their voting power across rooms. A reward pot (Runes) funded for that epoch
/// is then split between rooms in proportion to the weight they received, and each room's recipient claims its share.
/// @dev
/// - Voting power is 1 WRune = 1 vote, read with `getPastVotes` at the second before the epoch starts. Moving or
///   re-delegating WRunes during an epoch cannot add weight to it. No virtue bonus (deferred to V2).
/// - An invoker can vote again during the same epoch; the new split replaces the old one.
/// - The owner (meant to be the BushidoGovernanceV1_1 timelock) adds rooms, switches them on/off and changes their
///   recipient. A room switched off mid-epoch keeps the weight already cast that epoch and can still claim it.
/// - Rewards for an epoch can be claimed once that epoch has ended. If nobody voted in an epoch, its pot can be
///   rolled into the current epoch by anyone. Integer-division dust (under one wei per room per epoch) stays here.
/// - The reward token must not take a fee on transfer (Runes does not); funding counts the amount actually received.
contract BushidoRoomsGauge is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Room {
        address recipient;
        bool active;
        string name;
    }

    /// @notice One week per epoch.
    uint256 public constant EPOCH_LENGTH = 7 days;
    /// @notice A vote's weights are in basis points of the invoker's power; they may add up to at most 100%.
    uint256 public constant MAX_BPS = 10_000;
    /// @notice Most rooms a single vote may split across (bounds gas for re-votes).
    uint256 public constant MAX_ROOMS_PER_VOTE = 16;

    /// @notice The vote token: WRunes (timestamp clock).
    IVotes public immutable votesToken;
    /// @notice The token rewards are paid in (Runes on Base).
    IERC20 public immutable rewardToken;
    /// @notice Start of epoch 0.
    uint256 public immutable genesis;

    Room[] internal _rooms;

    /// @notice epoch => room id => weight received.
    mapping(uint256 => mapping(uint256 => uint256)) public roomWeight;
    /// @notice epoch => total weight cast.
    mapping(uint256 => uint256) public totalWeight;
    /// @notice epoch => reward pot.
    mapping(uint256 => uint256) public epochReward;
    /// @notice epoch => room id => claimed already.
    mapping(uint256 => mapping(uint256 => bool)) public claimed;

    /// @dev epoch => invoker => the rooms and weights of their current vote (to undo it on a re-vote).
    mapping(uint256 => mapping(address => uint256[])) internal _ballotRooms;
    mapping(uint256 => mapping(address => uint256[])) internal _ballotWeights;

    event RoomAdded(uint256 indexed roomId, address indexed recipient, string name);
    event RoomActiveSet(uint256 indexed roomId, bool active);
    event RoomRecipientSet(uint256 indexed roomId, address indexed recipient);
    event Voted(uint256 indexed epoch, address indexed invoker, uint256 power, uint256[] roomIds, uint256[] weightsBps);
    event Funded(uint256 indexed epoch, address indexed from, uint256 amount);
    event Claimed(uint256 indexed epoch, uint256 indexed roomId, address indexed recipient, uint256 amount);
    event RolledOver(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);

    error InvalidContractAddress(address account);
    error ZeroAddress();
    error UnknownRoom(uint256 roomId);
    error RoomInactive(uint256 roomId);
    error LengthMismatch();
    error TooManyRooms();
    error RoomsNotAscending();
    error ZeroWeight();
    error WeightsOverMax(uint256 totalBps);
    error NoVotingPower();
    error EpochNotEnded(uint256 epoch);
    error EpochEnded(uint256 epoch);
    error AlreadyClaimed(uint256 epoch, uint256 roomId);
    error NothingToClaim(uint256 epoch, uint256 roomId);
    error EpochHadVotes(uint256 epoch);
    error ZeroAmount();

    /// @param _votesToken WRunes.
    /// @param _rewardToken Runes (or the token rewards are paid in).
    /// @param _owner The BushidoGovernanceV1_1 timelock.
    constructor(IVotes _votesToken, IERC20 _rewardToken, address _owner) Ownable(_owner) {
        if (address(_votesToken).code.length == 0) revert InvalidContractAddress(address(_votesToken));
        if (address(_rewardToken).code.length == 0) revert InvalidContractAddress(address(_rewardToken));
        votesToken = _votesToken;
        rewardToken = _rewardToken;
        genesis = block.timestamp;
    }

    // --- epochs ---

    /// @notice The current epoch number.
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / EPOCH_LENGTH;
    }

    /// @notice When an epoch starts.
    function epochStart(uint256 epoch) public view returns (uint256) {
        return genesis + epoch * EPOCH_LENGTH;
    }

    /// @notice The timestamp voting power is read at for an epoch: one second before it starts.
    function snapshotOf(uint256 epoch) public view returns (uint256) {
        return epochStart(epoch) - 1;
    }

    // --- rooms (owner = governance timelock) ---

    function addRoom(address recipient, string calldata name) external onlyOwner returns (uint256 roomId) {
        if (recipient == address(0)) revert ZeroAddress();
        roomId = _rooms.length;
        _rooms.push(Room({recipient: recipient, active: true, name: name}));
        emit RoomAdded(roomId, recipient, name);
    }

    function setRoomActive(uint256 roomId, bool active) external onlyOwner {
        _room(roomId).active = active;
        emit RoomActiveSet(roomId, active);
    }

    function setRoomRecipient(uint256 roomId, address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _room(roomId).recipient = recipient;
        emit RoomRecipientSet(roomId, recipient);
    }

    function roomCount() external view returns (uint256) {
        return _rooms.length;
    }

    function room(uint256 roomId) external view returns (Room memory) {
        return _room(roomId);
    }

    function _room(uint256 roomId) internal view returns (Room storage) {
        if (roomId >= _rooms.length) revert UnknownRoom(roomId);
        return _rooms[roomId];
    }

    // --- voting (invokers = WRunes holders) ---

    /// @notice An invoker's voting power for the current epoch.
    function powerOf(address invoker) public view returns (uint256) {
        return votesToken.getPastVotes(invoker, snapshotOf(currentEpoch()));
    }

    /// @notice Split your voting power for the current epoch across rooms. Replaces any earlier vote this epoch.
    /// @param roomIds Rooms to vote for, in strictly ascending order (no repeats).
    /// @param weightsBps Share of your power for each room, in basis points; together at most 10,000.
    function vote(uint256[] calldata roomIds, uint256[] calldata weightsBps) external {
        uint256 n = roomIds.length;
        if (n != weightsBps.length) revert LengthMismatch();
        if (n == 0 || n > MAX_ROOMS_PER_VOTE) revert TooManyRooms();

        uint256 epoch = currentEpoch();
        uint256 power = votesToken.getPastVotes(msg.sender, snapshotOf(epoch));
        if (power == 0) revert NoVotingPower();

        _clearBallot(epoch, msg.sender);

        uint256 sumBps;
        uint256 added;
        for (uint256 i; i < n; ++i) {
            uint256 id = roomIds[i];
            if (i > 0 && id <= roomIds[i - 1]) revert RoomsNotAscending();
            if (!_room(id).active) revert RoomInactive(id);
            uint256 bps = weightsBps[i];
            if (bps == 0) revert ZeroWeight();
            sumBps += bps;
            if (sumBps > MAX_BPS) revert WeightsOverMax(sumBps);

            uint256 w = (power * bps) / MAX_BPS;
            roomWeight[epoch][id] += w;
            added += w;
            _ballotRooms[epoch][msg.sender].push(id);
            _ballotWeights[epoch][msg.sender].push(w);
        }
        totalWeight[epoch] += added;
        emit Voted(epoch, msg.sender, power, roomIds, weightsBps);
    }

    /// @notice An invoker's vote in an epoch: rooms and the weight each received.
    function ballotOf(uint256 epoch, address invoker)
        external
        view
        returns (uint256[] memory roomIds, uint256[] memory weights)
    {
        return (_ballotRooms[epoch][invoker], _ballotWeights[epoch][invoker]);
    }

    function _clearBallot(uint256 epoch, address invoker) internal {
        uint256[] storage ids = _ballotRooms[epoch][invoker];
        uint256[] storage ws = _ballotWeights[epoch][invoker];
        uint256 removed;
        for (uint256 i; i < ids.length; ++i) {
            roomWeight[epoch][ids[i]] -= ws[i];
            removed += ws[i];
        }
        totalWeight[epoch] -= removed;
        delete _ballotRooms[epoch][invoker];
        delete _ballotWeights[epoch][invoker];
    }

    // --- rewards ---

    /// @notice Add `amount` of the reward token to an epoch's pot (the current one or a later one).
    function fund(uint256 epoch, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (epoch < currentEpoch()) revert EpochEnded(epoch);
        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - before;
        epochReward[epoch] += received;
        emit Funded(epoch, msg.sender, received);
    }

    /// @notice A room's share of an ended epoch's pot (0 if nothing is owed or it was claimed).
    function claimable(uint256 epoch, uint256 roomId) public view returns (uint256) {
        if (epoch >= currentEpoch() || claimed[epoch][roomId]) return 0;
        uint256 total = totalWeight[epoch];
        if (total == 0) return 0;
        return (epochReward[epoch] * roomWeight[epoch][roomId]) / total;
    }

    /// @notice Pay a room's share of an ended epoch to the room's recipient. Anyone may call it.
    function claim(uint256 epoch, uint256 roomId) external nonReentrant returns (uint256 amount) {
        address recipient = _room(roomId).recipient;
        if (epoch >= currentEpoch()) revert EpochNotEnded(epoch);
        if (claimed[epoch][roomId]) revert AlreadyClaimed(epoch, roomId);
        amount = claimable(epoch, roomId);
        if (amount == 0) revert NothingToClaim(epoch, roomId);
        claimed[epoch][roomId] = true;
        rewardToken.safeTransfer(recipient, amount);
        emit Claimed(epoch, roomId, recipient, amount);
    }

    /// @notice Move the pot of an ended epoch in which nobody voted into the current epoch. Anyone may call it.
    function rollover(uint256 epoch) external {
        uint256 cur = currentEpoch();
        if (epoch >= cur) revert EpochNotEnded(epoch);
        if (totalWeight[epoch] != 0) revert EpochHadVotes(epoch);
        uint256 amount = epochReward[epoch];
        if (amount == 0) revert ZeroAmount();
        epochReward[epoch] = 0;
        epochReward[cur] += amount;
        emit RolledOver(epoch, cur, amount);
    }
}
