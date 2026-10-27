// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @title PadBox
/// @notice A deposit box of Ostrapad at a CREATE2 address fixed by its purpose (a job's escrow, a bond, an appeal
///         fee): fundable with a plain USDG transfer, which is all an Ostra vault can send, before it has code. Only
///         OstraPad moves what it holds.
contract PadBox {
    using SafeERC20 for IERC20;

    address public immutable PAD;
    IERC20 public immutable TOKEN;

    error OnlyPad();

    constructor() {
        PAD = msg.sender;
        TOKEN = OstraPad(msg.sender).TOKEN();
    }

    function send(address to, uint256 amount) external {
        if (msg.sender != PAD) revert OnlyPad();
        TOKEN.safeTransfer(to, amount);
    }
}

/// @title OstraPad
/// @notice Ostrapad: a market where agents are hired for work, paid in USDG through escrow, judged by an evaluator.
///         The job flow follows ERC-8183 (client, provider, evaluator; funded escrow; submit; complete or reject;
///         refund on expiry) and emits its events. Every role may act as msg.sender, or, for a contract account such
///         as an Ostra vault (which can only transfer tokens and approve hashes), through an EIP-1271 approval of the
///         action's digest (actionDigest), with anyone (Ostra's relayer) sending the call. Money comes in by a plain
///         transfer to a deposit box (boxAddress) or, from msg.sender, by transferFrom. Payouts are pushed; one that
///         USDG refuses (a frozen account, a pause) is kept as owed to its recipient and claimable by anyone for it.
///
///         A job's evaluator is either fixed when the client creates it (the client itself, or a verification
///         contract; the provider agrees by accepting, no evaluator fee, no appeal) or drawn from the evaluator pool:
///         bonded evaluators, paid a fee up front whatever they decide, with an appeal to a panel of three other
///         evaluators. Draws come from the client's and the provider's revealed secrets and a later block hash, over
///         the pool as it stood when the draw was armed (the job's secrets known, a silent evaluator replaced, or the
///         appeal opened): a member counts if its membership had taken effect by then (a join, like a top-up, takes
///         effect STAKE_DELAY after it is made) and had not ended before then, with its stake then (deposits in
///         effect, less what was slashed), unless it was removed for misconduct. Each candidate's chance is its own
///         keyed score over its tickets (one per minimum bond), so no join, top-up, departure or reordering after the
///         snapshot changes who is drawn. A snapshot serves draws for SNAPSHOT_TTL at most (an older one is re-armed),
///         so members gone longer than that are dropped from the draw list. An evaluator overturned on appeal, or
///         silent past its window or its panel vote, loses part of its bond. Providers take jobs up to a limit that
///         grows with their record of pool-judged jobs (completed, their total value, distinct clients, few
///         rejections) or with a voluntary bond, which a rejection slashes. Completed jobs pay 0.5%: half to
///         BURN_SINK (OSTRA bought and burned), half to TREASURY. There is no owner and no way to move funds other
///         than the rules below.
contract OstraPad is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    // ---------------------------------------------------------------------------------------------
    // Parameters (USDG, 6 decimals)
    // ---------------------------------------------------------------------------------------------

    uint256 public constant JOB_LIFETIME = 7 days;
    uint256 public constant REVEAL_WINDOW = 24 hours;
    uint256 public constant EVAL_WINDOW = 48 hours;
    uint256 public constant DRAW_GRACE = 24 hours; // a submitted pool job outlives its expiry while it can be judged
    uint256 public constant APPEAL_WINDOW = 48 hours;
    uint256 public constant PANEL_DRAW_WINDOW = 24 hours;
    uint256 public constant VOTE_WINDOW = 48 hours;
    uint256 public constant BOND_COOLDOWN = 7 days;
    uint256 public constant STAKE_DELAY = 2 days; // a join or top-up counts in snapshots after it matures
    /// @dev The oldest a snapshot can be when a draw uses it (equal to PANEL_DRAW_WINDOW, and under STAKE_DELAY: a
    ///      member can leave only once its membership took effect, so the members gone within SNAPSHOT_TTL all held a
    ///      pool seat SNAPSHOT_TTL ago, and at most MAX_POOL of them are not yet prunable).
    uint256 public constant SNAPSHOT_TTL = 24 hours;

    uint256 public constant MIN_BUDGET = 100_000; // 0.1 USDG
    uint256 public constant MAX_BUDGET = 500_000_000; // 500 USDG
    uint256 public constant RECORD_MIN_BUDGET = 1_000_000; // jobs under 1 USDG do not build a provider's record
    uint256 public constant PLATFORM_FEE_BPS = 50; // 0.5%, on completion only
    uint256 public constant EVAL_FEE_BPS = 100; // 1%, paid by the client up front
    uint256 public constant MIN_EVAL_FEE = 50_000; // 0.05 USDG
    uint256 public constant APPEAL_FEE_BPS = 200; // 2%
    uint256 public constant MIN_APPEAL_FEE = 250_000; // 0.25 USDG
    uint256 public constant EVALUATOR_SLASH_BPS = 2_000; // 20% of the budget
    uint256 public constant MIN_EVALUATOR_SLASH = 1_000_000; // 1 USDG
    uint256 public constant PROVIDER_SLASH_BPS = 1_000; // 10% of the budget, plus the evaluator fee
    uint256 public constant MIN_EVALUATOR_BOND = 50_000_000; // 50 USDG = one ticket; judges budgets up to half its stake
    uint256 public constant MAX_TICKETS = 20;
    uint256 public constant MAX_POOL = 128; // members in the pool
    uint256 public constant MAX_MEMBERS = 256; // the draw list: the pool, and members gone but not yet pruned
    uint256 public constant MIN_POOL_FOR_DRAW = 4; // an evaluator, then a panel of three others
    uint256 public constant PANEL = 3;

    bytes32 public constant DOMAIN = keccak256("OSTRAPAD/v1");

    IERC20 public immutable TOKEN;
    address public immutable TREASURY;
    address public immutable BURN_SINK;
    bytes32 public immutable BOX_CODE_HASH;

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    enum Status {
        None,
        Open, // funded by the client, waiting for the provider
        Accepted, // the provider took it (in pool mode: commit-reveal, then an evaluator is drawn)
        Submitted, // work delivered, waiting for the evaluator
        Decided, // pool mode: decided, open to appeal
        Appealed, // pool mode: a panel votes
        Completed,
        Rejected,
        Expired,
        Cancelled
    }

    /// @notice What the client signs: the job id is keccak256(abi.encode(terms)).
    struct Terms {
        address client;
        address provider;
        address evaluator; // address(0): drawn from the pool
        uint256 budget;
        bytes32 description; // the job's description (its hash or a content id)
        bytes32 clientCommit; // pool mode: keccak256(abi.encode(secret))
        bytes32 salt;
    }

    struct Job {
        address client;
        address provider;
        address evaluator;
        uint128 budget;
        uint128 evaluatorFee;
        Status status;
        bool pool;
        bool approved; // the decision (Decided / Appealed)
        bool feePaid; // the evaluator fee left the escrow
        uint8 round; // evaluators drawn so far (a silent one is replaced)
        uint8 revealed; // bit 0: client, bit 1: provider
        uint64 expiresAt;
        uint64 acceptedAt;
        uint64 revealBy;
        uint64 submittedAt;
        uint64 assignedAt; // the evaluator's assignment, or a silent one's removal
        uint64 appealBy;
        uint64 drawBlock;
        uint64 drawAt; // the pool snapshot of the armed evaluator draw
        bytes32 clientCommit;
        bytes32 providerCommit;
        bytes32 seed; // the client's and provider's secrets, combined
        bytes32 deliverable;
    }

    struct Appeal {
        address appellant;
        uint128 fee;
        uint64 openedAt; // the pool snapshot of the panel draw
        uint64 panelBlock;
        uint64 voteBy;
        address[3] panel;
        uint8 voted; // bit per panel member
        uint8 agreed; // bit per member that agreed with the evaluator's decision
        uint8 agree;
        uint8 disagree;
    }

    struct Evaluator {
        uint128 bond; // all it holds here: slashable, withdrawable after leaving
        uint64 joinedAt; // when its (last) membership takes effect: STAKE_DELAY after the join
        uint64 exitAt; // when it left (0: in the pool, or never joined)
        uint32 active; // jobs and panels it is assigned to, not yet over
        bool inPool;
        bool removed; // removed for misconduct (silent, no vote, slashed below the minimum): never drawn again
        uint128 slashed; // taken from its bond in its current membership
    }

    struct Provider {
        uint128 bond;
        uint64 lastEnd;
        uint32 active;
        uint32 completed; // pool-judged, budget >= RECORD_MIN_BUDGET
        uint32 rejected;
        uint32 expired;
        uint32 clients; // distinct clients of those completed jobs
        uint32 fixedCompleted; // completed with a fixed evaluator (shown, not counted in the limit)
        uint128 volume; // the budgets of the completed jobs counted in `completed`
    }

    mapping(bytes32 jobId => Job) internal _jobs;
    mapping(bytes32 jobId => Appeal) internal _appeals;
    mapping(address => Evaluator) internal _evaluators;
    /// @dev Per evaluator: its deposits since its last join, by the time they take effect (keys only grow).
    mapping(address => Checkpoints.Trace208) internal _stakes;
    mapping(address => Provider) internal _providers;
    mapping(address provider => mapping(address client => bool)) public servedClient;
    mapping(address => uint256) public nonces;
    mapping(address => uint256) public owed;
    uint256 public totalOwed;
    /// @dev The draw list: the pool, and members out of it not yet pruned (those gone within SNAPSHOT_TTL still
    ///      count in snapshots taken before they left). Draws run over all of them.
    address[] internal _members;
    mapping(address => uint256) internal _memberIndex; // index + 1
    uint256 public poolSize;

    // ---------------------------------------------------------------------------------------------
    // Events (ERC-8183's, then Ostrapad's)
    // ---------------------------------------------------------------------------------------------

    event JobCreated(bytes32 indexed jobId, address indexed client, address indexed provider, address evaluator, uint256 expiredAt);
    event JobFunded(bytes32 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(bytes32 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(bytes32 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(bytes32 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(bytes32 indexed jobId);
    event PaymentReleased(bytes32 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(bytes32 indexed jobId, address indexed client, uint256 amount);

    event JobAccepted(bytes32 indexed jobId, address indexed provider);
    event JobCancelled(bytes32 indexed jobId);
    event Revealed(bytes32 indexed jobId, bool client);
    event EvaluatorDrawn(bytes32 indexed jobId, address indexed evaluator, uint8 round);
    event EvaluatorReplaced(bytes32 indexed jobId, address indexed silent);
    event Decided(bytes32 indexed jobId, address indexed evaluator, bool approved, bytes32 reason);
    event AppealOpened(bytes32 indexed jobId, address indexed appellant, uint256 fee);
    event PanelDrawn(bytes32 indexed jobId, address[3] panel);
    event Voted(bytes32 indexed jobId, address indexed member, bool agree);
    event AppealResolved(bytes32 indexed jobId, bool overturned);
    event AppealLapsed(bytes32 indexed jobId);
    event FeePaid(bytes32 indexed jobId, uint256 burn, uint256 treasury);
    event EvaluatorFeePaid(bytes32 indexed jobId, address indexed evaluator, uint256 amount);
    event EvaluatorJoined(address indexed evaluator, uint256 bond);
    event EvaluatorLeft(address indexed evaluator);
    event EvaluatorSlashed(address indexed evaluator, uint256 amount);
    event ProviderSlashed(address indexed provider, uint256 amount);
    event BondDeposited(address indexed account, bool evaluator, uint256 amount);
    event BondWithdrawn(address indexed account, bool evaluator, uint256 amount);
    event Owed(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);

    error BadParams();
    error NotAuthorized();
    error WrongStatus(Status status);
    error NotFunded(uint256 needed);
    error OverLimit(uint256 limit);
    error PoolTooSmall();
    error TooEarly(uint256 at);
    error TooLate(uint256 at);
    error Busy();

    constructor(address token, address treasury, address burnSink) {
        if (token == address(0) || treasury == address(0) || burnSink == address(0)) revert BadParams();
        TOKEN = IERC20(token);
        TREASURY = treasury;
        BURN_SINK = burnSink;
        BOX_CODE_HASH = keccak256(type(PadBox).creationCode);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function jobId(Terms calldata t) public pure returns (bytes32) {
        return keccak256(abi.encode(t));
    }

    function job(bytes32 id) external view returns (Job memory) {
        return _jobs[id];
    }

    function appeal(bytes32 id) external view returns (Appeal memory) {
        return _appeals[id];
    }

    function evaluator(address a) external view returns (Evaluator memory) {
        return _evaluators[a];
    }

    function provider(address a) external view returns (Provider memory) {
        return _providers[a];
    }

    /// @notice The evaluators in the pool now.
    function pool() external view returns (address[] memory out) {
        out = new address[](poolSize);
        uint256 n;
        for (uint256 i = 0; i < _members.length; i++) if (_evaluators[_members[i]].inPool) out[n++] = _members[i];
    }

    /// @notice The draw list: the pool, and members out of it not yet pruned (some still counted in recent snapshots).
    function members() external view returns (address[] memory) {
        return _members;
    }

    /// @notice The digest a role approves (EIP-1271) for an action: actions are named and carry their arguments.
    function actionDigest(bytes32 action) public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, block.chainid, address(this), action));
    }

    function boxAddress(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, BOX_CODE_HASH)))));
    }

    function jobBox(bytes32 id) public view returns (address) {
        return boxAddress(_jobSalt(id));
    }

    function appealBox(bytes32 id, uint8 round, address appellant) public view returns (address) {
        return boxAddress(_appealSalt(id, round, appellant));
    }

    function bondBox(address account, bool evaluator_) public view returns (address) {
        return boxAddress(_bondSalt(account, evaluator_));
    }

    function evaluatorFeeFor(uint256 budget) public pure returns (uint256) {
        uint256 f = budget * EVAL_FEE_BPS / 10_000;
        return f < MIN_EVAL_FEE ? MIN_EVAL_FEE : f;
    }

    function appealFeeFor(uint256 budget) public pure returns (uint256) {
        uint256 f = budget * APPEAL_FEE_BPS / 10_000;
        return f < MIN_APPEAL_FEE ? MIN_APPEAL_FEE : f;
    }

    /// @notice The largest budget a provider may accept: by its record, or up to its voluntary bond. A tier needs a
    ///         number of completed jobs, of distinct clients and a total value completed, with few rejections. A
    ///         record built from its own clients costs at least the 0.5% platform fee on that value, plus the 1%
    ///         evaluator fee (at least 0.05 USDG a job) except where its own evaluators are drawn. Tiers: 25 USDG at
    ///         10 jobs, 5 clients, 100 USDG of value and under 20% rejected; 100 USDG at 50, 20, 1,000 USDG and under
    ///         10%; 500 USDG at 200, 50, 10,000 USDG and under 5%.
    function limitOf(address p) public view returns (uint256) {
        Provider storage r = _providers[p];
        uint256 done = uint256(r.completed) + r.rejected;
        uint256 v = r.volume;
        uint256 tier = 5_000_000;
        if (r.completed >= 200 && r.clients >= 50 && v >= 10_000_000_000 && r.rejected * 100 < done * 5) {
            tier = 500_000_000;
        } else if (r.completed >= 50 && r.clients >= 20 && v >= 1_000_000_000 && r.rejected * 100 < done * 10) {
            tier = 100_000_000;
        } else if (r.completed >= 10 && r.clients >= 5 && v >= 100_000_000 && r.rejected * 100 < done * 20) {
            tier = 25_000_000;
        }
        uint256 bond = r.bond > MAX_BUDGET ? MAX_BUDGET : r.bond;
        return bond > tier ? bond : tier;
    }

    /// @notice An evaluator's stake counted in a draw whose pool snapshot is at `t`: 0 unless its membership had taken
    ///         effect before `t` and had not ended before it, and it was not removed for misconduct; else its deposits
    ///         in effect at `t` less everything slashed in this membership (a later top-up does not undo a slash).
    function stakeAt(address e, uint256 t) public view returns (uint256) {
        Evaluator storage v = _evaluators[e];
        if (v.removed || v.joinedAt == 0 || v.joinedAt >= t) return 0;
        // Out of the pool only from the second after it left: anything done in the snapshot's own second (in the
        // same block, before or after the action that took the snapshot) does not change it.
        if (!v.inPool && v.exitAt < t) return 0;
        uint256 s = _stakes[e].upperLookup(uint48(t));
        return s > v.slashed ? s - v.slashed : 0;
    }

    /// @notice Pool evaluators who could be drawn for a budget at snapshot `t`, leaving out the listed addresses.
    function eligibleCount(uint256 budget, uint256 t, address a, address b, address c) public view returns (uint256 n) {
        for (uint256 i = 0; i < _members.length; i++) {
            address e = _members[i];
            if (e != a && e != b && e != c && _eligibleStake(e, budget, t) != 0) n++;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Jobs
    // ---------------------------------------------------------------------------------------------

    /// @notice Creates and funds a job. The client authorizes it (msg.sender, or EIP-1271 of
    ///         actionDigest(keccak256(abi.encode("create", id)))); budget plus the evaluator fee (pool mode) come from
    ///         the job's box or, from a calling client, by transferFrom.
    function create(Terms calldata t) external nonReentrant returns (bytes32 id) {
        id = jobId(t);
        if (_jobs[id].status != Status.None) revert WrongStatus(_jobs[id].status);
        if (t.client == address(0) || t.provider == address(0) || t.provider == t.client) revert BadParams();
        if (t.budget < MIN_BUDGET || t.budget > MAX_BUDGET) revert BadParams();
        bool pool_ = t.evaluator == address(0);
        if (!pool_ && t.evaluator == t.provider) revert BadParams();
        if (pool_ && t.clientCommit == bytes32(0)) revert BadParams();
        _auth(t.client, keccak256(abi.encode("create", id)));
        uint256 fee = pool_ ? evaluatorFeeFor(t.budget) : 0;
        _pull(_jobSalt(id), t.client, t.budget + fee);

        Job storage j = _jobs[id];
        j.client = t.client;
        j.provider = t.provider;
        j.evaluator = t.evaluator;
        j.budget = uint128(t.budget);
        j.evaluatorFee = uint128(fee);
        j.status = Status.Open;
        j.pool = pool_;
        j.expiresAt = uint64(block.timestamp + JOB_LIFETIME);
        j.clientCommit = t.clientCommit;
        emit JobCreated(id, t.client, t.provider, t.evaluator, j.expiresAt);
        emit JobFunded(id, t.client, t.budget + fee);
    }

    /// @notice The client takes back a job no provider accepted: everything is refunded (ERC-8183: Open, rejected by
    ///         the client).
    function cancel(bytes32 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Open) revert WrongStatus(j.status);
        _auth(j.client, keccak256(abi.encode("cancel", id)));
        j.status = Status.Cancelled;
        emit JobCancelled(id);
        emit JobRejected(id, j.client, bytes32(0));
        _refund(id, j, uint256(j.budget) + j.evaluatorFee);
    }

    /// @notice The provider takes the job, within its limit; in pool mode with its commit (keccak256(abi.encode(secret))),
    ///         early enough for the reveal window, and only when enough evaluators can judge it.
    function accept(bytes32 id, bytes32 providerCommit) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Open) revert WrongStatus(j.status);
        if (block.timestamp >= j.expiresAt) revert TooLate(j.expiresAt);
        _auth(j.provider, keccak256(abi.encode("accept", id, providerCommit)));
        uint256 limit = limitOf(j.provider);
        if (j.budget > limit) revert OverLimit(limit);
        if (j.pool) {
            if (providerCommit == bytes32(0)) revert BadParams();
            if (block.timestamp + REVEAL_WINDOW >= j.expiresAt) revert TooLate(j.expiresAt - REVEAL_WINDOW);
            if (eligibleCount(j.budget, block.timestamp, j.client, j.provider, address(0)) < MIN_POOL_FOR_DRAW) revert PoolTooSmall();
            j.providerCommit = providerCommit;
            j.revealBy = uint64(block.timestamp + REVEAL_WINDOW);
        } else {
            j.assignedAt = uint64(block.timestamp);
        }
        j.acceptedAt = uint64(block.timestamp);
        j.status = Status.Accepted;
        _providers[j.provider].active++;
        emit JobAccepted(id, j.provider);
    }

    /// @notice Anyone with a secret reveals it (pool mode). Once both are known, the evaluator can be drawn from the
    ///         next block's hash on.
    function reveal(bytes32 id, bytes32 secret) external {
        Job storage j = _jobs[id];
        if (!j.pool || j.status < Status.Accepted || j.status > Status.Submitted || j.revealed == 3) revert WrongStatus(j.status);
        bytes32 h = keccak256(abi.encode(secret));
        if (h == j.clientCommit && j.revealed & 1 == 0) {
            j.revealed |= 1;
            j.seed ^= keccak256(abi.encode(secret, "client"));
            emit Revealed(id, true);
        } else if (h == j.providerCommit && j.revealed & 2 == 0) {
            j.revealed |= 2;
            j.seed ^= keccak256(abi.encode(secret, "provider"));
            emit Revealed(id, false);
        } else {
            revert BadParams();
        }
        if (j.revealed == 3) _armDraw(j);
    }

    /// @notice After the reveal window: a provider that did not reveal has its job rejected; a client that did not
    ///         reveal is replaced by nothing (the draw then rests on the provider's secret and the block hash).
    function lapseReveal(bytes32 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (!j.pool || j.status < Status.Accepted || j.status > Status.Submitted || j.revealed == 3) revert WrongStatus(j.status);
        if (block.timestamp < j.revealBy) revert TooEarly(j.revealBy);
        if (j.revealed & 2 == 0) {
            _finishRejected(id, j, address(this), keccak256("provider did not reveal"));
            return;
        }
        j.revealed = 3;
        _armDraw(j);
    }

    /// @notice Draws the job's evaluator, from the block after both secrets were known (re-armed, with a new snapshot,
    ///         when that block's hash is no longer readable or the snapshot is older than SNAPSHOT_TTL). Also replaces
    ///         an evaluator silent past its window: it is slashed (to the client), leaves the pool, and a new draw is
    ///         armed.
    function draw(bytes32 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (!j.pool || (j.status != Status.Accepted && j.status != Status.Submitted)) revert WrongStatus(j.status);
        if (j.evaluator != address(0)) {
            if (j.status != Status.Submitted) revert WrongStatus(j.status);
            uint256 start = _evalStart(j);
            if (block.timestamp < start + EVAL_WINDOW) revert TooEarly(start + EVAL_WINDOW);
            address silent = j.evaluator;
            _evaluators[silent].active--;
            uint256 slash = _slashEvaluator(silent, _evaluatorSlash(j.budget));
            _remove(silent);
            j.evaluator = address(0);
            j.assignedAt = uint64(block.timestamp);
            _armDraw(j);
            emit EvaluatorReplaced(id, silent);
            _send(j.client, slash);
            return;
        }
        if (j.revealed != 3 || j.drawBlock == 0) revert WrongStatus(j.status);
        if (block.number <= j.drawBlock) revert TooEarly(uint256(j.drawBlock) + 1);
        if (block.number - j.drawBlock > 256 || block.timestamp > uint256(j.drawAt) + SNAPSHOT_TTL) {
            _armDraw(j);
            return;
        }
        bytes32 seed = keccak256(abi.encode(j.seed, blockhash(j.drawBlock), id, j.round));
        address[3] memory none;
        address e = _pick(DrawArgs(seed, j.budget, j.drawAt, j.client, j.provider, address(0)), none, 0);
        if (e == address(0)) revert PoolTooSmall();
        j.evaluator = e;
        j.round++;
        j.assignedAt = uint64(block.timestamp);
        _evaluators[e].active++;
        emit EvaluatorDrawn(id, e, j.round);
    }

    /// @notice The provider delivers (its deliverable: a hash or content id), before the job expires.
    function submit(bytes32 id, bytes32 deliverable) external {
        Job storage j = _jobs[id];
        if (j.status != Status.Accepted) revert WrongStatus(j.status);
        if (block.timestamp >= j.expiresAt) revert TooLate(j.expiresAt);
        _auth(j.provider, keccak256(abi.encode("submit", id, deliverable)));
        j.status = Status.Submitted;
        j.deliverable = deliverable;
        j.submittedAt = uint64(block.timestamp);
        emit JobSubmitted(id, j.provider, deliverable);
    }

    /// @notice The evaluator decides a submitted job. A fixed evaluator's decision is final at once; a pool
    ///         evaluator, within its window, is paid its fee and its decision is open to appeal for APPEAL_WINDOW (it
    ///         stays bound to the job until it settles).
    function decide(bytes32 id, bool approve, bytes32 reason) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Submitted || j.evaluator == address(0)) revert WrongStatus(j.status);
        _auth(j.evaluator, keccak256(abi.encode("decide", id, j.round, approve, reason)));
        emit Decided(id, j.evaluator, approve, reason);
        if (!j.pool) {
            if (approve) _finishCompleted(id, j, reason);
            else _finishRejected(id, j, j.evaluator, reason);
            return;
        }
        uint256 start = _evalStart(j);
        if (block.timestamp >= start + EVAL_WINDOW) revert TooLate(start + EVAL_WINDOW);
        j.status = Status.Decided;
        j.approved = approve;
        j.appealBy = uint64(block.timestamp + APPEAL_WINDOW);
        j.feePaid = true;
        emit EvaluatorFeePaid(id, j.evaluator, j.evaluatorFee);
        _send(j.evaluator, j.evaluatorFee);
    }

    /// @notice The side the decision went against appeals within APPEAL_WINDOW, paying the appeal fee (from its appeal
    ///         box, appealBox(id, round, appellant), or by transferFrom); a panel of three other pool evaluators is
    ///         drawn from a later block, over the pool as it stands now.
    function openAppeal(bytes32 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Decided) revert WrongStatus(j.status);
        if (block.timestamp >= j.appealBy) revert TooLate(j.appealBy);
        address appellant = j.approved ? j.client : j.provider;
        _auth(appellant, keccak256(abi.encode("appeal", id, j.round)));
        if (eligibleCount(j.budget, block.timestamp, j.client, j.provider, j.evaluator) < PANEL) revert PoolTooSmall();
        uint256 fee = appealFeeFor(j.budget);
        _pull(_appealSalt(id, j.round, appellant), appellant, fee);
        Appeal storage a = _appeals[id];
        a.appellant = appellant;
        a.fee = uint128(fee);
        a.openedAt = uint64(block.timestamp);
        a.panelBlock = uint64(block.number);
        j.status = Status.Appealed;
        emit AppealOpened(id, appellant, fee);
    }

    /// @notice Draws the appeal panel from the block after the appeal (re-armed when its hash is gone).
    function drawPanel(bytes32 id) external nonReentrant {
        Job storage j = _jobs[id];
        Appeal storage a = _appeals[id];
        if (j.status != Status.Appealed || a.panel[0] != address(0)) revert WrongStatus(j.status);
        if (block.timestamp >= uint256(a.openedAt) + PANEL_DRAW_WINDOW) revert TooLate(uint256(a.openedAt) + PANEL_DRAW_WINDOW);
        if (block.number <= a.panelBlock) revert TooEarly(uint256(a.panelBlock) + 1);
        if (block.number - a.panelBlock > 256) {
            a.panelBlock = uint64(block.number); // the snapshot stays: PANEL_DRAW_WINDOW (== SNAPSHOT_TTL) bounds its age
            return;
        }
        bytes32 seed = keccak256(abi.encode(j.seed, blockhash(a.panelBlock), id, "panel"));
        address[3] memory panel;
        DrawArgs memory d = DrawArgs(seed, j.budget, a.openedAt, j.client, j.provider, j.evaluator);
        for (uint256 k = 0; k < PANEL; k++) {
            address m = _pick(d, panel, k);
            if (m == address(0)) revert PoolTooSmall();
            panel[k] = m;
            _evaluators[m].active++;
        }
        a.panel = panel;
        a.voteBy = uint64(block.timestamp + VOTE_WINDOW);
        emit PanelDrawn(id, panel);
    }

    /// @notice A panel member votes whether it agrees with the evaluator's decision.
    function vote(bytes32 id, uint8 member, bool agree) external nonReentrant {
        Job storage j = _jobs[id];
        Appeal storage a = _appeals[id];
        if (j.status != Status.Appealed || a.panel[0] == address(0) || member >= PANEL) revert WrongStatus(j.status);
        if (block.timestamp >= a.voteBy) revert TooLate(a.voteBy);
        if (a.voted & (1 << member) != 0) revert BadParams();
        address m = a.panel[member];
        _auth(m, keccak256(abi.encode("vote", id, j.round, agree)));
        a.voted |= uint8(1 << member);
        if (agree) {
            a.agreed |= uint8(1 << member);
            a.agree++;
        } else {
            a.disagree++;
        }
        emit Voted(id, m, agree);
        if (a.agree + a.disagree == PANEL) _resolveAppeal(id, j, a);
    }

    /// @notice Settles a job whose time has come: a pool decision not appealed in time; an appeal whose vote window
    ///         closed, or whose panel could not be drawn within PANEL_DRAW_WINDOW (the fee back, the decision stands);
    ///         or a job past its expiry without a decision (refunded in full). A submitted pool job outlives its
    ///         expiry while it can still be judged: until DRAW_GRACE plus EVAL_WINDOW after its submission or its
    ///         latest evaluator assignment or replacement.
    function settle(bytes32 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status == Status.Decided) {
            if (block.timestamp < j.appealBy) revert TooEarly(j.appealBy);
            if (j.approved) _finishCompleted(id, j, bytes32(0));
            else _finishRejected(id, j, j.evaluator, bytes32(0));
        } else if (j.status == Status.Appealed) {
            Appeal storage a = _appeals[id];
            if (a.panel[0] == address(0)) {
                uint256 lapse = uint256(a.openedAt) + PANEL_DRAW_WINDOW;
                if (block.timestamp < lapse) revert TooEarly(lapse);
                emit AppealLapsed(id);
                _send(a.appellant, a.fee);
                if (j.approved) _finishCompleted(id, j, bytes32(0));
                else _finishRejected(id, j, j.evaluator, bytes32(0));
            } else {
                if (block.timestamp < a.voteBy) revert TooEarly(a.voteBy);
                _resolveAppeal(id, j, a);
            }
        } else if (j.status == Status.Open || j.status == Status.Accepted || j.status == Status.Submitted) {
            uint256 at = j.expiresAt;
            if (j.status == Status.Submitted && j.pool) {
                uint256 judged = _evalStart(j) + DRAW_GRACE + EVAL_WINDOW;
                if (judged > at) at = judged;
            }
            if (block.timestamp < at) revert TooEarly(at);
            _finishExpired(id, j);
        } else {
            revert WrongStatus(j.status);
        }
    }

    /// @notice Pays what is owed to `account` (a payout USDG refused earlier); anyone may call it.
    function claim(address account) external nonReentrant {
        uint256 amount = owed[account];
        if (amount == 0) return;
        owed[account] = 0;
        totalOwed -= amount;
        emit Claimed(account, amount);
        TOKEN.safeTransfer(account, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Evaluators and provider bonds
    // ---------------------------------------------------------------------------------------------

    /// @notice An evaluator joins the pool, or tops up its bond, the bond from its box or by transferFrom; a join and
    ///         a top-up count in draws from STAKE_DELAY later. A full pool takes a newcomer only in place of its
    ///         smallest member whose membership took effect.
    function joinPool(address e, uint256 amount) external nonReentrant {
        _auth(e, keccak256(abi.encode("join", e, amount, nonces[e]++)));
        Evaluator storage v = _evaluators[e];
        if (v.exitAt != 0) revert Busy();
        if (amount > type(uint96).max) revert BadParams();
        uint48 effective = uint48(block.timestamp + STAKE_DELAY);
        if (amount > 0) {
            _pull(_bondSalt(e, true), e, amount);
            v.bond += uint128(amount);
            emit BondDeposited(e, true, amount);
        }
        if (v.inPool) {
            if (amount > 0) _stakes[e].push(effective, _stakes[e].latest() + uint208(amount));
            return;
        }
        if (v.bond < MIN_EVALUATOR_BOND) revert BadParams();
        if (poolSize >= MAX_POOL) {
            address smallest;
            for (uint256 i = 0; i < _members.length; i++) {
                Evaluator storage m = _evaluators[_members[i]];
                if (m.inPool && m.joinedAt <= block.timestamp && (smallest == address(0) || m.bond < _evaluators[smallest].bond)) {
                    smallest = _members[i];
                }
            }
            if (smallest == address(0)) revert Busy();
            if (_evaluators[smallest].bond >= v.bond) revert BadParams();
            _leavePool(smallest);
        }
        if (_members.length >= MAX_MEMBERS) _pruneOne();
        v.inPool = true;
        v.removed = false;
        v.slashed = 0;
        v.joinedAt = effective;
        _stakes[e].push(effective, uint208(v.bond));
        poolSize++;
        _members.push(e);
        _memberIndex[e] = _members.length;
        emit EvaluatorJoined(e, v.bond);
    }

    /// @notice An evaluator leaves the pool, once its membership took effect; its bond can be withdrawn BOND_COOLDOWN
    ///         later, with nothing assigned.
    function leavePool(address e) external nonReentrant {
        _auth(e, keccak256(abi.encode("leave", e, nonces[e]++)));
        Evaluator storage v = _evaluators[e];
        if (!v.inPool) revert Busy();
        if (block.timestamp < v.joinedAt) revert TooEarly(v.joinedAt);
        _leavePool(e);
    }

    /// @notice Drops a member gone longer than SNAPSHOT_TTL from the draw list (no snapshot still in use counts it);
    ///         anyone may call it. Its bond stays withdrawable.
    function prune(address e) external {
        if (_memberIndex[e] == 0 || !_stale(e)) revert BadParams();
        _dropMember(e);
    }

    function withdrawEvaluatorBond(address e) external nonReentrant {
        _auth(e, keccak256(abi.encode("withdraw", e, true, nonces[e]++)));
        Evaluator storage v = _evaluators[e];
        if (v.exitAt == 0 || v.inPool || v.active != 0) revert Busy();
        if (block.timestamp < v.exitAt + BOND_COOLDOWN) revert TooEarly(v.exitAt + BOND_COOLDOWN);
        uint256 amount = v.bond;
        v.bond = 0;
        v.exitAt = 0;
        v.joinedAt = 0;
        _dropMember(e);
        emit BondWithdrawn(e, true, amount);
        _send(e, amount);
    }

    /// @notice A provider's voluntary bond: it raises the limit to the bond (up to MAX_BUDGET); a rejection slashes it.
    function depositProviderBond(address p, uint256 amount) external nonReentrant {
        if (amount == 0 || amount > type(uint96).max) revert BadParams();
        _auth(p, keccak256(abi.encode("bond", p, amount, nonces[p]++)));
        _pull(_bondSalt(p, false), p, amount);
        _providers[p].bond += uint128(amount);
        emit BondDeposited(p, false, amount);
    }

    function withdrawProviderBond(address p) external nonReentrant {
        _auth(p, keccak256(abi.encode("withdraw", p, false, nonces[p]++)));
        Provider storage r = _providers[p];
        if (r.active != 0) revert Busy();
        if (block.timestamp < uint256(r.lastEnd) + BOND_COOLDOWN) revert TooEarly(uint256(r.lastEnd) + BOND_COOLDOWN);
        uint256 amount = r.bond;
        r.bond = 0;
        emit BondWithdrawn(p, false, amount);
        _send(p, amount);
    }

    /// @notice Returns what is left in a job's box to its client: anyone may, once the job exists (nothing more is
    ///         pulled from it); before that, only the client (msg.sender or EIP-1271), for terms never created.
    function sweepJobBox(Terms calldata t) external nonReentrant {
        bytes32 id = jobId(t);
        if (_jobs[id].status == Status.None) _auth(t.client, keccak256(abi.encode("sweep job", id, nonces[t.client]++)));
        _sweep(_jobSalt(id), t.client);
    }

    /// @notice Returns an appeal box's USDG to its appellant once no appeal can draw on it (the job left Decided, or
    ///         this round's appeal was opened by someone else).
    function sweepAppealBox(bytes32 id, uint8 round, address appellant) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status == Status.None || (j.status == Status.Decided && j.round == round)) revert Busy();
        _sweep(_appealSalt(id, round, appellant), appellant);
    }

    /// @notice Returns a bond box's USDG to its account: the account's own call (msg.sender or EIP-1271), so nobody
    ///         can empty a box between a vault's transfer and its deposit.
    function sweepBondBox(address account, bool evaluator_) external nonReentrant {
        _auth(account, keccak256(abi.encode("sweep bond", account, evaluator_, nonces[account]++)));
        _sweep(_bondSalt(account, evaluator_), account);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _jobSalt(bytes32 id) internal pure returns (bytes32) {
        return keccak256(abi.encode("job", id));
    }

    function _appealSalt(bytes32 id, uint8 round, address appellant) internal pure returns (bytes32) {
        return keccak256(abi.encode("appeal", id, round, appellant));
    }

    function _bondSalt(address account, bool evaluator_) internal pure returns (bytes32) {
        return keccak256(abi.encode(evaluator_ ? "evaluator" : "provider", account));
    }

    function _evalStart(Job storage j) internal view returns (uint256) {
        return j.submittedAt > j.assignedAt ? j.submittedAt : j.assignedAt;
    }

    /// @dev msg.sender, or the account's EIP-1271 approval of the action's digest.
    function _auth(address account, bytes32 action) internal view {
        if (msg.sender == account) return;
        if (account.code.length == 0) revert NotAuthorized();
        try IERC1271(account).isValidSignature(actionDigest(action), "") returns (bytes4 magic) {
            if (magic != IERC1271.isValidSignature.selector) revert NotAuthorized();
        } catch {
            revert NotAuthorized();
        }
    }

    function _box(bytes32 salt) internal returns (address box) {
        box = boxAddress(salt);
        if (box.code.length == 0) {
            if (address(new PadBox{salt: salt}()) != box) revert BadParams();
        }
    }

    /// @dev `amount` from the box (all it holds, the excess back to `payer`) or, from a calling payer, by transferFrom.
    function _pull(bytes32 salt, address payer, uint256 amount) internal {
        address box = boxAddress(salt);
        uint256 held = TOKEN.balanceOf(box);
        if (held >= amount) {
            _box(salt);
            PadBox(box).send(address(this), amount);
            if (held > amount) PadBox(box).send(payer, held - amount);
        } else if (msg.sender == payer) {
            uint256 before = TOKEN.balanceOf(address(this));
            TOKEN.safeTransferFrom(payer, address(this), amount);
            if (TOKEN.balanceOf(address(this)) - before != amount) revert NotFunded(amount);
        } else {
            revert NotFunded(amount);
        }
    }

    function _sweep(bytes32 salt, address to) internal {
        address box = boxAddress(salt);
        uint256 amount = TOKEN.balanceOf(box);
        if (amount == 0) return;
        _box(salt);
        PadBox(box).send(to, amount);
    }

    /// @dev Pushes a payout; one USDG refuses (a frozen recipient, a pause) is kept as owed, so it blocks nothing else.
    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!TOKEN.trySafeTransfer(to, amount)) {
            owed[to] += amount;
            totalOwed += amount;
            emit Owed(to, amount);
        }
    }

    function _refund(bytes32 id, Job storage j, uint256 amount) internal {
        emit Refunded(id, j.client, amount);
        _send(j.client, amount);
    }

    /// @dev The provider's job ends: its active count (if it had accepted) and its bond cooldown (likewise).
    function _endProvider(Job storage j) internal {
        if (j.status == Status.Open || j.status == Status.Cancelled) return;
        Provider storage r = _providers[j.provider];
        r.active--;
        r.lastEnd = uint64(block.timestamp);
    }

    /// @dev A pool job's current evaluator is released when the job ends.
    function _endEvaluator(Job storage j) internal {
        if (j.pool && j.evaluator != address(0)) _evaluators[j.evaluator].active--;
    }

    function _countsInRecord(Job storage j) internal view returns (bool) {
        return j.pool && j.budget >= RECORD_MIN_BUDGET;
    }

    function _finishCompleted(bytes32 id, Job storage j, bytes32 reason) internal {
        _endProvider(j);
        _endEvaluator(j);
        j.status = Status.Completed;
        Provider storage r = _providers[j.provider];
        if (_countsInRecord(j)) {
            r.completed++;
            r.volume += j.budget;
            if (!servedClient[j.provider][j.client]) {
                servedClient[j.provider][j.client] = true;
                r.clients++;
            }
        } else if (!j.pool) {
            r.fixedCompleted++;
        }
        uint256 fee = uint256(j.budget) * PLATFORM_FEE_BPS / 10_000;
        uint256 burnPart = fee / 2;
        uint256 pay = uint256(j.budget) - fee;
        emit JobCompleted(id, j.evaluator, reason);
        emit PaymentReleased(id, j.provider, pay);
        emit FeePaid(id, burnPart, fee - burnPart);
        _send(j.provider, pay);
        _send(BURN_SINK, burnPart);
        _send(TREASURY, fee - burnPart);
    }

    /// @dev Rejected: the budget (and an unpaid evaluator fee) back to the client; a provider bond pays the client
    ///      the evaluator fee and 10% of the budget, up to what it holds.
    function _finishRejected(bytes32 id, Job storage j, address rejector, bytes32 reason) internal {
        _endProvider(j);
        _endEvaluator(j);
        j.status = Status.Rejected;
        Provider storage r = _providers[j.provider];
        if (_countsInRecord(j)) r.rejected++;
        uint256 refund = uint256(j.budget) + (j.feePaid ? 0 : j.evaluatorFee);
        uint256 slash = j.evaluatorFee + uint256(j.budget) * PROVIDER_SLASH_BPS / 10_000;
        if (slash > r.bond) slash = r.bond;
        r.bond -= uint128(slash);
        emit JobRejected(id, rejector, reason);
        if (slash != 0) emit ProviderSlashed(j.provider, slash);
        _refund(id, j, refund + slash);
    }

    function _finishExpired(bytes32 id, Job storage j) internal {
        if (j.status != Status.Open) _providers[j.provider].expired++;
        _endProvider(j);
        _endEvaluator(j);
        j.status = Status.Expired;
        emit JobExpired(id);
        _refund(id, j, uint256(j.budget) + (j.feePaid ? 0 : j.evaluatorFee));
    }

    /// @dev Overturned (more members disagreed than agreed): the appellant's fee comes back, the first evaluator is
    ///      slashed, half to the appellant and half shared by the members who disagreed, and the decision flips.
    ///      Upheld (otherwise, a tie or no vote included): the appeal fee is shared by the members who agreed, or goes
    ///      to the treasury when none did. Members who did not vote are slashed (to the treasury: paid to the
    ///      appellant, a member's absence would make losing appeals profitable) and leave the pool.
    function _resolveAppeal(bytes32 id, Job storage j, Appeal storage a) internal {
        for (uint256 k = 0; k < PANEL; k++) _evaluators[a.panel[k]].active--;
        bool overturned = a.disagree > a.agree;
        emit AppealResolved(id, overturned);
        uint256 pot;
        uint8 winners;
        if (overturned) {
            _send(a.appellant, a.fee);
            uint256 slash = _slashEvaluator(j.evaluator, _evaluatorSlash(j.budget));
            pot = slash / 2;
            _send(a.appellant, slash - pot);
            winners = a.disagree;
            j.approved = !j.approved;
        } else {
            pot = a.fee;
            winners = a.agree;
        }
        if (winners == 0) {
            _send(TREASURY, pot);
        } else {
            uint256 share = pot / winners;
            uint256 left = pot;
            for (uint256 k = 0; k < PANEL; k++) {
                bool votedK = a.voted & (1 << k) != 0;
                bool agreedK = a.agreed & (1 << k) != 0;
                if (votedK && agreedK != overturned) {
                    left -= share;
                    _send(a.panel[k], share);
                }
            }
            _send(TREASURY, left);
        }
        for (uint256 k = 0; k < PANEL; k++) {
            if (a.voted & (1 << k) != 0) continue;
            uint256 slash = _slashEvaluator(a.panel[k], _evaluatorSlash(j.budget));
            _remove(a.panel[k]);
            _send(TREASURY, slash);
        }
        if (j.approved) _finishCompleted(id, j, bytes32(0));
        else _finishRejected(id, j, j.evaluator, bytes32(0));
    }

    function _evaluatorSlash(uint256 budget) internal pure returns (uint256 s) {
        s = budget * EVALUATOR_SLASH_BPS / 10_000;
        if (s < MIN_EVALUATOR_SLASH) s = MIN_EVALUATOR_SLASH;
    }

    /// @dev Takes up to `amount` of an evaluator's bond (the caller pays it out); below the minimum it leaves the pool.
    function _slashEvaluator(address e, uint256 amount) internal returns (uint256) {
        Evaluator storage v = _evaluators[e];
        if (amount > v.bond) amount = v.bond;
        v.bond -= uint128(amount);
        v.slashed += uint128(amount);
        if (v.inPool && v.bond < MIN_EVALUATOR_BOND) _remove(e);
        if (amount != 0) emit EvaluatorSlashed(e, amount);
        return amount;
    }

    /// @dev Out of the pool for misconduct: never drawn again in this membership, whatever the snapshot.
    function _remove(address e) internal {
        _evaluators[e].removed = true;
        _leavePool(e);
    }

    /// @dev Out of the pool from now: still a member (counted in snapshots before now) until it withdraws.
    function _leavePool(address e) internal {
        Evaluator storage v = _evaluators[e];
        if (!v.inPool) return;
        v.inPool = false;
        v.exitAt = uint64(block.timestamp);
        poolSize--;
        emit EvaluatorLeft(e);
    }

    /// @dev Out of the pool for longer than SNAPSHOT_TTL: no draw can count it (every draw's snapshot is newer).
    function _stale(address e) internal view returns (bool) {
        Evaluator storage v = _evaluators[e];
        return !v.inPool && uint256(v.exitAt) + SNAPSHOT_TTL < block.timestamp;
    }

    /// @dev Makes room in a full draw list; with leaving and eviction only after a membership took effect, a full
    ///      list that takes a newcomer always holds a stale member.
    function _pruneOne() internal {
        for (uint256 i = 0; i < _members.length; i++) {
            address m = _members[i];
            if (_stale(m)) {
                _dropMember(m);
                return;
            }
        }
        revert Busy();
    }

    function _armDraw(Job storage j) internal {
        j.drawBlock = uint64(block.number);
        j.drawAt = uint64(block.timestamp);
    }

    function _dropMember(address e) internal {
        uint256 i = _memberIndex[e];
        if (i == 0) return;
        address last = _members[_members.length - 1];
        _members[i - 1] = last;
        _memberIndex[last] = i;
        _members.pop();
        _memberIndex[e] = 0;
    }

    /// @dev The stake that counts for `e` in a draw for `budget` at snapshot `t`: 0 if it cannot judge it.
    function _eligibleStake(address e, uint256 budget, uint256 t) internal view returns (uint256 s) {
        s = stakeAt(e, t);
        if (s < MIN_EVALUATOR_BOND || s < 2 * budget) s = 0;
    }

    struct DrawArgs {
        bytes32 seed;
        uint256 budget;
        uint256 t; // the pool snapshot
        address a; // left out: the client,
        address b; // the provider,
        address c; // and the first evaluator (panels)
    }

    /// @dev The eligible member (not a, b, c, nor among the first k of `chosen`) with the highest keyed score: each
    ///      member draws one keccak score per ticket (a ticket per MIN_EVALUATOR_BOND of its stake at the snapshot,
    ///      up to MAX_TICKETS) and keeps its best, so its chance is its share of the tickets, and no other member's
    ///      joining, leaving or position changes its own score.
    function _pick(DrawArgs memory d, address[3] memory chosen, uint256 k) internal view returns (address best) {
        uint256 bestScore;
        for (uint256 i = 0; i < _members.length; i++) {
            address e = _members[i];
            if (e == d.a || e == d.b || e == d.c || _taken(chosen, k, e)) continue;
            uint256 score = _score(d.seed, e, _eligibleStake(e, d.budget, d.t));
            if (score > bestScore) {
                best = e;
                bestScore = score;
            }
        }
    }

    function _taken(address[3] memory chosen, uint256 k, address e) internal pure returns (bool) {
        for (uint256 x = 0; x < k; x++) if (chosen[x] == e) return true;
        return false;
    }

    /// @dev A member's best keyed score over its tickets, plus one (0: not eligible).
    function _score(bytes32 seed, address e, uint256 stake) internal pure returns (uint256 best) {
        uint256 tickets = stake / MIN_EVALUATOR_BOND;
        if (tickets > MAX_TICKETS) tickets = MAX_TICKETS;
        for (uint256 n = 0; n < tickets; n++) {
            uint256 s = uint256(keccak256(abi.encode(seed, e, n))) >> 1;
            if (s + 1 > best) best = s + 1;
        }
    }
}
