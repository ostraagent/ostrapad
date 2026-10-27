// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OstraPad, PadBox} from "../src/OstraPad.sol";
import {IBeacon, IOstraVault as OstraVault, IOstraVaultFactory} from "./utils/IOstraVault.sol";
import {WotsSigner} from "./utils/WotsSigner.sol";

/// @notice OstraPad on a Robinhood Chain mainnet fork with the real USDG and the live Ostra vaults of version 3, made by
///         the live OstraVaultFactory: vaults act only by transfers and EIP-1271 approvals (spend 23), sent by a relayer
///         account, as on mainnet; plain accounts act as msg.sender.
contract OstraPadForkTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 internal constant CLIENT_KEYS = keccak256("OSTRA/EVM/TEST/pad-client");
    bytes32 internal constant PROVIDER_KEYS = keccak256("OSTRA/EVM/TEST/pad-provider");
    bytes32 internal constant EVAL_KEYS = keccak256("OSTRA/EVM/TEST/pad-evaluator");
    address internal constant SUBMITTER = address(0x5EB);
    /// @dev The live OstraVaultFactory (github.com/ostraagent/ostra-robinhood, deployments/robinhood-mainnet.json).
    IOstraVaultFactory internal constant FACTORY = IOstraVaultFactory(0x043a15c514CFE2c797d33520bFF91a5DCdbf2979);
    IBeacon internal constant VAULT_BEACON = IBeacon(0xE9F525B9EaeE48d13AEd28fE146F48f2832a18a0);
    /// @dev The vault implementation of version 3 (OstraVault, activated on 27 Oct 2026).
    address internal constant VAULT_V3 = 0xec0ca4A1393D91c42cA809F7F9dd82Bd597E8E58;

    /// @dev Per run (from the fork's head): the test vaults' WOTS keys and every makeAddr account are new each run, so
    ///      that nobody can create, spend or fund them on mainnet beforehand. These keys are public test keys: their
    ///      vaults must never hold funds on mainnet.
    bytes32 internal runSalt;
    bytes32 internal master;
    OstraPad internal pad;
    address internal treasury;
    address internal burn;
    address internal relayer;
    OstraVault internal client;
    OstraVault internal providerVault;
    OstraVault internal evalVault;
    address[5] internal evals;

    function setUp() public {
        vm.createSelectFork("robinhood");
        assertEq(block.chainid, 4663);
        assertEq(VAULT_BEACON.implementation(), VAULT_V3, "the live vaults run version 3");
        runSalt = keccak256(abi.encode(block.number, block.timestamp, vm.unixTime()));
        master = keccak256(abi.encode("OSTRA/EVM/TEST/pad-master", runSalt));
        treasury = makeAddr("treasury");
        burn = makeAddr("burn");
        relayer = makeAddr("relayer");
        // At a new address every run (CREATE2 with the run's salt), so that its deposit boxes are new every run too.
        pad = new OstraPad{salt: runSalt}(USDG, treasury, burn);
        assertEq(_usdg(address(pad)), 0, "a new pad holds nothing");
        client = _vault(CLIENT_KEYS);
        providerVault = _vault(PROVIDER_KEYS);
        evalVault = _vault(EVAL_KEYS);
        assertEq(evalVault.VERSION(), 3);
        for (uint256 i = 0; i < 5; i++) evals[i] = makeAddr(string(abi.encodePacked("evaluator", vm.toString(i))));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev A test account of this run (see runSalt), labelled with its name.
    function makeAddr(string memory name) internal override returns (address addr) {
        addr = vm.addr(uint256(keccak256(abi.encode("OSTRA/EVM/TEST/pad-account", runSalt, name))));
        vm.label(addr, name);
    }

    /// @dev A new vault of this run, made by the live factory.
    function _vault(bytes32 keychain) internal returns (OstraVault) {
        bytes32 root = WotsSigner.keyRoot(WotsSigner.deriveSeed(master, keychain, 0));
        assertEq(FACTORY.vaultAddress(USDG, root, address(0)).code.length, 0, "a new vault");
        return OstraVault(FACTORY.createVault(USDG, root, address(0)));
    }

    function _spend(OstraVault v, bytes32 keychain, uint8 action, bytes memory params) internal {
        uint64 n = v.nonce();
        bytes32 next = WotsSigner.keyRoot(WotsSigner.deriveSeed(master, keychain, n + 1));
        bytes memory sig = WotsSigner.sign(WotsSigner.deriveSeed(master, keychain, n), v.spendMessage(action, next, params));
        vm.prank(SUBMITTER, SUBMITTER);
        v.spend(action, next, params, sig);
    }

    /// @dev The vault approves an Ostrapad action (spend 23 on actionDigest).
    function _approve(OstraVault v, bytes32 keychain, bytes32 action) internal {
        _spend(v, keychain, 23, abi.encode(pad.actionDigest(action), true));
    }

    function _transfer(OstraVault v, bytes32 keychain, address to, uint256 amount) internal {
        _spend(v, keychain, 0, abi.encode(to, amount));
    }

    function _usdg(address a) internal view returns (uint256) {
        return IERC20(USDG).balanceOf(a);
    }

    function _terms(address c, address p, address e, uint256 budget, bytes32 commit, bytes32 salt)
        internal
        pure
        returns (OstraPad.Terms memory)
    {
        return OstraPad.Terms({client: c, provider: p, evaluator: e, budget: budget, description: keccak256("write a haiku"), clientCommit: commit, salt: salt});
    }

    /// @dev A job created by the client vault (transfer to the box, approval, relayer sends create).
    function _vaultJob(address p, address e, uint256 budget, bytes32 commit) internal returns (bytes32 id, OstraPad.Terms memory t) {
        t = _terms(address(client), p, e, budget, commit, keccak256(abi.encode(p, e, budget, commit)));
        id = pad.jobId(t);
        uint256 need = budget + (e == address(0) ? pad.evaluatorFeeFor(budget) : 0);
        _transfer(client, CLIENT_KEYS, pad.jobBox(id), need);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("create", id)));
        vm.prank(relayer);
        pad.create(t);
    }

    function _pool(uint256 bond) internal {
        for (uint256 i = 0; i < 5; i++) {
            deal(USDG, evals[i], bond);
            vm.startPrank(evals[i]);
            IERC20(USDG).approve(address(pad), bond);
            pad.joinPool(evals[i], bond);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 2 days + 1); // a membership counts in draws STAKE_DELAY after the join
    }

    /// @dev A pool job up to the drawn evaluator: provider is a plain account.
    function _poolJobDrawn(uint256 budget, address p) internal returns (bytes32 id, address e) {
        bytes32 cs = keccak256("client secret");
        bytes32 ps = keccak256("provider secret");
        (id,) = _vaultJob(p, address(0), budget, keccak256(abi.encode(cs)));
        vm.prank(p);
        pad.accept(id, keccak256(abi.encode(ps)));
        pad.reveal(id, cs);
        pad.reveal(id, ps);
        vm.roll(block.number + 1);
        pad.draw(id);
        e = pad.job(id).evaluator;
        assertTrue(e != address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Fixed evaluator (the client): vaults all the way
    // ---------------------------------------------------------------------------------------------

    function test_fixedEvaluatorCompletes() public {
        deal(USDG, address(client), 10e6);
        (bytes32 id,) = _vaultJob(address(providerVault), address(client), 4e6, bytes32(0));
        assertEq(_usdg(address(pad)), 4e6);
        OstraPad.Job memory j = pad.job(id);
        assertEq(uint8(j.status), uint8(OstraPad.Status.Open));
        assertEq(j.expiresAt, block.timestamp + 7 days);
        assertEq(j.evaluatorFee, 0);

        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("accept", id, bytes32(0))));
        vm.prank(relayer);
        pad.accept(id, bytes32(0));
        bytes32 work = keccak256("the haiku");
        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("submit", id, work)));
        vm.prank(relayer);
        pad.submit(id, work);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("decide", id, uint8(0), true, bytes32("good"))));
        vm.prank(relayer);
        pad.decide(id, true, bytes32("good"));

        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Completed));
        assertEq(_usdg(address(providerVault)), 4e6 - 20_000, "paid the budget less 0.5%");
        assertEq(_usdg(burn), 10_000);
        assertEq(_usdg(treasury), 10_000);
        assertEq(_usdg(address(pad)), 0);
        OstraPad.Provider memory r = pad.provider(address(providerVault));
        assertEq(r.completed, 0, "a job its own client judged does not build the record");
        assertEq(r.fixedCompleted, 1);
        assertEq(r.clients, 0);
        assertEq(r.active, 0);
    }

    function test_fixedEvaluatorRejectsAndSlashesTheProviderBond() public {
        deal(USDG, address(client), 10e6);
        deal(USDG, address(providerVault), 3e6);
        _transfer(providerVault, PROVIDER_KEYS, pad.bondBox(address(providerVault), false), 3e6);
        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("bond", address(providerVault), uint256(3e6), uint256(0))));
        pad.depositProviderBond(address(providerVault), 3e6);
        assertEq(pad.provider(address(providerVault)).bond, 3e6);

        (bytes32 id,) = _vaultJob(address(providerVault), address(client), 4e6, bytes32(0));
        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("accept", id, bytes32(0))));
        pad.accept(id, bytes32(0));
        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("submit", id, bytes32("x"))));
        pad.submit(id, bytes32("x"));
        uint256 before = _usdg(address(client));
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("decide", id, uint8(0), false, bytes32("off topic"))));
        pad.decide(id, false, bytes32("off topic"));
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Rejected));
        // Refund 4 USDG, plus the slash: no evaluator fee here, 10% of the budget = 0.4 USDG.
        assertEq(_usdg(address(client)) - before, 4e6 + 400_000);
        assertEq(pad.provider(address(providerVault)).bond, 3e6 - 400_000);
        assertEq(pad.provider(address(providerVault)).rejected, 0, "not a pool-judged job");
        assertEq(_usdg(address(pad)), 3e6 - 400_000, "only the remaining bond is held");
    }

    function test_cancelBeforeAccept() public {
        deal(USDG, address(client), 10e6);
        (bytes32 id,) = _vaultJob(address(providerVault), address(client), 2e6, bytes32(0));
        vm.expectRevert(OstraPad.NotAuthorized.selector);
        pad.cancel(id);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("cancel", id)));
        pad.cancel(id);
        assertEq(_usdg(address(client)), 10e6);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Cancelled));
        vm.expectRevert(abi.encodeWithSelector(OstraPad.WrongStatus.selector, OstraPad.Status.Cancelled));
        pad.accept(id, bytes32(0));
    }

    function test_createNeedsTheClient() public {
        // Funds in the box are not enough: someone else cannot open a job in the client's name.
        OstraPad.Terms memory t = _terms(address(client), address(providerVault), address(client), 1e6, bytes32(0), bytes32("s"));
        bytes32 id = pad.jobId(t);
        deal(USDG, pad.jobBox(id), 1e6);
        vm.expectRevert(OstraPad.NotAuthorized.selector);
        pad.create(t);
        // A plain client pays by transferFrom.
        address eoa = makeAddr("eoa client");
        deal(USDG, eoa, 2e6);
        OstraPad.Terms memory t2 = _terms(eoa, address(providerVault), eoa, 2e6, bytes32(0), bytes32("s2"));
        vm.startPrank(eoa);
        IERC20(USDG).approve(address(pad), 2e6);
        pad.create(t2);
        vm.stopPrank();
        assertEq(_usdg(eoa), 0);
        // Without funds, the vault's approval alone is not enough.
        OstraPad.Terms memory t3 = _terms(address(client), address(providerVault), address(client), 1e6, bytes32(0), bytes32("s3"));
        bytes32 id3 = pad.jobId(t3);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("create", id3)));
        vm.expectRevert(abi.encodeWithSelector(OstraPad.NotFunded.selector, uint256(1e6)));
        pad.create(t3);
    }

    function test_badTerms() public {
        address eoa = makeAddr("eoa client");
        vm.startPrank(eoa);
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.create(_terms(eoa, eoa, address(0), 1e6, bytes32("c"), 0));
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.create(_terms(eoa, address(1), address(0), 99_999, bytes32("c"), 0));
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.create(_terms(eoa, address(1), address(0), 500_000_001, bytes32("c"), 0));
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.create(_terms(eoa, address(1), address(0), 1e6, bytes32(0), 0)); // pool mode needs a commit
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.create(_terms(eoa, address(1), address(1), 1e6, bytes32(0), 0)); // the provider cannot judge itself
        vm.stopPrank();
    }

    function test_providerLimitAndBond() public {
        deal(USDG, address(client), 20e6);
        (bytes32 id,) = _vaultJob(address(providerVault), address(client), 6e6, bytes32(0));
        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("accept", id, bytes32(0))));
        vm.expectRevert(abi.encodeWithSelector(OstraPad.OverLimit.selector, uint256(5e6)));
        pad.accept(id, bytes32(0));
        assertEq(pad.limitOf(address(providerVault)), 5e6);
        deal(USDG, address(providerVault), 10e6);
        _transfer(providerVault, PROVIDER_KEYS, pad.bondBox(address(providerVault), false), 10e6);
        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("bond", address(providerVault), uint256(10e6), uint256(0))));
        pad.depositProviderBond(address(providerVault), 10e6);
        assertEq(pad.limitOf(address(providerVault)), 10e6);
        pad.accept(id, bytes32(0)); // the earlier approval still holds
        // The bond cannot leave while a job is active.
        _approve(providerVault, PROVIDER_KEYS, keccak256(abi.encode("withdraw", address(providerVault), false, uint256(1))));
        vm.expectRevert(OstraPad.Busy.selector);
        pad.withdrawProviderBond(address(providerVault));
    }

    // ---------------------------------------------------------------------------------------------
    // The evaluator pool
    // ---------------------------------------------------------------------------------------------

    function test_poolTooSmallForAccept() public {
        deal(USDG, address(client), 10e6);
        for (uint256 i = 0; i < 3; i++) {
            deal(USDG, evals[i], 50e6);
            vm.startPrank(evals[i]);
            IERC20(USDG).approve(address(pad), 50e6);
            pad.joinPool(evals[i], 50e6);
            vm.stopPrank();
        }
        address p = makeAddr("provider");
        (bytes32 id,) = _vaultJob(p, address(0), 2e6, keccak256(abi.encode(bytes32("c"))));
        vm.prank(p);
        vm.expectRevert(OstraPad.PoolTooSmall.selector);
        pad.accept(id, keccak256(abi.encode(bytes32("p"))));
    }

    function test_joinNeedsTheMinimumBond() public {
        deal(USDG, evals[0], 49e6);
        vm.startPrank(evals[0]);
        IERC20(USDG).approve(address(pad), 49e6);
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.joinPool(evals[0], 49e6);
        vm.stopPrank();
    }

    function test_vaultEvaluatorJoinsByBoxAndApproval() public {
        deal(USDG, address(evalVault), 60e6);
        _transfer(evalVault, EVAL_KEYS, pad.bondBox(address(evalVault), true), 60e6);
        _approve(evalVault, EVAL_KEYS, keccak256(abi.encode("join", address(evalVault), uint256(60e6), uint256(0))));
        vm.prank(relayer);
        pad.joinPool(address(evalVault), 60e6);
        assertEq(pad.evaluator(address(evalVault)).bond, 60e6);
        assertTrue(pad.evaluator(address(evalVault)).inPool);
        assertEq(pad.pool().length, 1);
        // A replay of the same approval is refused: the nonce moved.
        vm.expectRevert(OstraPad.NotAuthorized.selector);
        pad.joinPool(address(evalVault), 60e6);
    }

    function test_poolJobCompletesAfterTheAppealWindow() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(4e6, p);
        assertTrue(e != address(client) && e != p);
        assertEq(pad.evaluator(e).active, 1);
        assertEq(_usdg(address(pad)), 500e6 + 4e6 + 50_000, "bonds, budget and the 0.05 USDG evaluator fee");

        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));
        assertEq(_usdg(e), 50_000, "the evaluator is paid at once");
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Decided));
        vm.expectRevert(abi.encodeWithSelector(OstraPad.TooEarly.selector, block.timestamp + 48 hours));
        pad.settle(id);
        vm.warp(block.timestamp + 48 hours);
        pad.settle(id);
        assertEq(_usdg(p), 4e6 - 20_000);
        assertEq(_usdg(address(pad)), 500e6, "only the bonds are left");
        assertEq(pad.evaluator(e).active, 0);
    }

    function test_appealOverturnsAndSlashesTheEvaluator() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));

        uint256 fee = pad.appealFeeFor(5e6);
        assertEq(fee, 250_000);
        uint256 clientBefore = _usdg(address(client));
        _transfer(client, CLIENT_KEYS, pad.appealBox(id, 1, address(client)), fee);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("appeal", id, uint8(1))));
        pad.openAppeal(id);
        vm.roll(block.number + 1);
        pad.drawPanel(id);
        address[3] memory panel = pad.appeal(id).panel;
        for (uint256 k = 0; k < 3; k++) {
            assertTrue(panel[k] != e && panel[k] != p && panel[k] != address(client));
            for (uint256 x = 0; x < k; x++) assertTrue(panel[k] != panel[x]);
        }
        vm.prank(panel[0]);
        pad.vote(id, 0, false);
        vm.prank(panel[1]);
        pad.vote(id, 1, false);
        vm.prank(panel[2]);
        pad.vote(id, 2, true);

        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Rejected));
        // Slash max(20% of 5 USDG, 1 USDG) = 1 USDG: 0.5 to the client, 0.25 to each member who disagreed.
        assertEq(_usdg(address(client)) - clientBefore, 5e6 + 500_000, "refund and half the slash; the appeal fee came back");
        assertEq(_usdg(panel[0]), 250_000);
        assertEq(_usdg(panel[1]), 250_000);
        assertEq(_usdg(panel[2]), 0);
        assertEq(pad.evaluator(e).bond, 99e6);
        assertEq(_usdg(p), 0);
        assertEq(_usdg(address(pad)), 499e6);
    }

    function test_appealUpheldPaysTheAgreeingMembers() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, false, bytes32("bad"));
        // The provider appeals the rejection, paying by transferFrom.
        deal(USDG, p, 1e6);
        vm.startPrank(p);
        IERC20(USDG).approve(address(pad), 250_000);
        pad.openAppeal(id);
        vm.stopPrank();
        vm.roll(block.number + 1);
        pad.drawPanel(id);
        address[3] memory panel = pad.appeal(id).panel;
        vm.prank(panel[0]);
        pad.vote(id, 0, true);
        vm.prank(panel[1]);
        pad.vote(id, 1, true);
        // panel[2] never votes.
        vm.warp(block.timestamp + 48 hours);
        pad.settle(id);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Rejected));
        assertEq(_usdg(panel[0]), 125_000);
        assertEq(_usdg(panel[1]), 125_000);
        assertFalse(pad.evaluator(panel[2]).inPool, "a member who did not vote leaves the pool");
        assertEq(pad.evaluator(panel[2]).bond, 99e6, "and is slashed");
        assertEq(_usdg(p), 1e6 - 250_000, "the slash does not go to the appellant");
        assertEq(_usdg(treasury), 1e6, "it goes to the treasury");
        assertEq(pad.provider(p).rejected, 1);
    }

    function test_silentEvaluatorIsReplaced() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.expectRevert();
        pad.draw(id);
        vm.warp(block.timestamp + 48 hours);
        uint256 before = _usdg(address(client));
        pad.draw(id); // slashes the silent one and re-arms the draw
        assertEq(_usdg(address(client)) - before, 1e6);
        assertFalse(pad.evaluator(e).inPool);
        assertEq(pad.job(id).evaluator, address(0));
        vm.roll(block.number + 1);
        pad.draw(id);
        address e2 = pad.job(id).evaluator;
        assertTrue(e2 != address(0) && e2 != e);
        assertEq(pad.job(id).round, 2);
        // The old evaluator's decision no longer counts; the new one decides.
        vm.prank(e);
        vm.expectRevert(OstraPad.NotAuthorized.selector);
        pad.decide(id, true, bytes32("late"));
        vm.prank(e2);
        pad.decide(id, true, bytes32("ok"));
        assertEq(_usdg(e2), 50_000);
    }

    function test_providerThatDoesNotRevealIsRejected() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        bytes32 cs = keccak256("client secret");
        (bytes32 id,) = _vaultJob(p, address(0), 3e6, keccak256(abi.encode(cs)));
        vm.prank(p);
        pad.accept(id, keccak256(abi.encode(bytes32("provider secret"))));
        pad.reveal(id, cs);
        vm.expectRevert(abi.encodeWithSelector(OstraPad.TooEarly.selector, block.timestamp + 24 hours));
        pad.lapseReveal(id);
        vm.warp(block.timestamp + 24 hours);
        uint256 before = _usdg(address(client));
        pad.lapseReveal(id);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Rejected));
        assertEq(_usdg(address(client)) - before, 3e6 + 50_000);
    }

    function test_clientThatDoesNotRevealDoesNotStopTheDraw() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id,) = _vaultJob(p, address(0), 3e6, keccak256(abi.encode(bytes32("hidden"))));
        bytes32 ps = keccak256("provider secret");
        vm.prank(p);
        pad.accept(id, keccak256(abi.encode(ps)));
        pad.reveal(id, ps);
        vm.warp(block.timestamp + 24 hours);
        pad.lapseReveal(id);
        vm.roll(block.number + 1);
        pad.draw(id);
        assertTrue(pad.job(id).evaluator != address(0));
    }

    function test_expiry() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id,) = _poolJobDrawn(3e6, p);
        vm.expectRevert();
        pad.settle(id);
        vm.warp(block.timestamp + 7 days);
        vm.prank(p);
        vm.expectRevert();
        pad.submit(id, bytes32("late"));
        uint256 before = _usdg(address(client));
        pad.settle(id);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Expired));
        assertEq(_usdg(address(client)) - before, 3e6 + 50_000);
        assertEq(pad.provider(p).expired, 1);
        assertEq(_usdg(address(pad)), 500e6);
    }

    function test_submittedJobWaitsForItsEvaluatorWindow() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(3e6, p);
        vm.warp(block.timestamp + 7 days - 1 hours);
        vm.prank(p);
        pad.submit(id, bytes32("just in time"));
        vm.warp(block.timestamp + 2 hours); // past expiry, inside the evaluator's window
        vm.expectRevert();
        pad.settle(id);
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));
        vm.warp(block.timestamp + 48 hours);
        pad.settle(id);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Completed));
    }

    function test_evaluatorLeavesAndWithdraws() public {
        _pool(100e6);
        vm.prank(evals[0]);
        pad.leavePool(evals[0]);
        assertFalse(pad.evaluator(evals[0]).inPool);
        vm.prank(evals[0]);
        vm.expectRevert();
        pad.withdrawEvaluatorBond(evals[0]);
        vm.warp(block.timestamp + 7 days);
        vm.prank(evals[0]);
        pad.withdrawEvaluatorBond(evals[0]);
        assertEq(_usdg(evals[0]), 100e6);
        assertEq(pad.pool().length, 4);
    }

    function test_sweepReturnsExtraFunds() public {
        deal(USDG, address(client), 10e6);
        (bytes32 id,) = _vaultJob(address(providerVault), address(client), 1e6, bytes32(0));
        assertEq(id, pad.jobId(_terms(address(client), address(providerVault), address(client), 1e6, bytes32(0), keccak256(abi.encode(address(providerVault), address(client), uint256(1e6), bytes32(0))))));
        address box = pad.jobBox(id);
        deal(USDG, address(this), 3e6);
        IERC20(USDG).transfer(box, 3e6); // sent there by mistake later
        uint256 before = _usdg(address(client));
        pad.sweepJobBox(_terms(address(client), address(providerVault), address(client), 1e6, bytes32(0), keccak256(abi.encode(address(providerVault), address(client), uint256(1e6), bytes32(0)))));
        assertEq(_usdg(address(client)) - before, 3e6);
        assertEq(_usdg(box), 0);
    }

    function test_excessInTheBoxGoesBackAtCreate() public {
        deal(USDG, address(client), 10e6);
        OstraPad.Terms memory t = _terms(address(client), address(providerVault), address(client), 1e6, bytes32(0), bytes32("x"));
        bytes32 id = pad.jobId(t);
        _transfer(client, CLIENT_KEYS, pad.jobBox(id), 1_500_000);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("create", id)));
        pad.create(t);
        assertEq(_usdg(address(client)), 10e6 - 1e6);
        assertEq(PadBox(pad.jobBox(id)).PAD(), address(pad));
    }

    // ---------------------------------------------------------------------------------------------
    // Review findings
    // ---------------------------------------------------------------------------------------------

    /// @dev C1: a dust top-up, a late join or a member leaving after the job was accepted cannot change who is drawn.
    function test_drawCannotBeGround() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        bytes32 cs = keccak256("client secret");
        bytes32 ps = keccak256("provider secret");
        (bytes32 id,) = _vaultJob(p, address(0), 4e6, keccak256(abi.encode(cs)));
        vm.prank(p);
        pad.accept(id, keccak256(abi.encode(ps)));
        pad.reveal(id, cs);
        pad.reveal(id, ps);
        vm.roll(block.number + 1);
        uint256 snap = vm.snapshotState();
        pad.draw(id);
        address honest = pad.job(id).evaluator;
        vm.revertToState(snap);
        // Every other member tops up by dust, a newcomer joins, and one non-winner leaves: the same evaluator.
        for (uint256 i = 0; i < 5; i++) {
            if (evals[i] == honest) continue;
            deal(USDG, evals[i], 1);
            vm.startPrank(evals[i]);
            IERC20(USDG).approve(address(pad), 1);
            pad.joinPool(evals[i], 1);
            vm.stopPrank();
        }
        address late = makeAddr("late evaluator");
        deal(USDG, late, 1000e6);
        vm.startPrank(late);
        IERC20(USDG).approve(address(pad), 1000e6);
        pad.joinPool(late, 1000e6);
        vm.stopPrank();
        address leaver = evals[0] == honest ? evals[1] : evals[0];
        vm.prank(leaver);
        pad.leavePool(leaver);
        pad.draw(id);
        assertEq(pad.job(id).evaluator, honest);
        assertEq(pad.stakeAt(late, pad.job(id).drawAt), 0, "a member that joined later does not count");
    }

    /// @dev A top-up counts only for jobs accepted after STAKE_DELAY.
    function test_topUpWaitsItsDelay() public {
        _pool(100e6);
        deal(USDG, evals[0], 400e6);
        vm.startPrank(evals[0]);
        IERC20(USDG).approve(address(pad), 400e6);
        pad.joinPool(evals[0], 400e6);
        vm.stopPrank();
        assertEq(pad.stakeAt(evals[0], block.timestamp), 100e6);
        assertEq(pad.stakeAt(evals[0], block.timestamp + 2 days - 1), 100e6);
        assertEq(pad.stakeAt(evals[0], block.timestamp + 2 days + 1), 500e6);
        assertEq(pad.evaluator(evals[0]).bond, 500e6);
    }

    /// @dev H1: a panel that cannot be drawn in time lets the job settle on the decision, the appeal fee back.
    function test_appealLapsesWhenNoPanelCanBeDrawn() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));
        _transfer(client, CLIENT_KEYS, pad.appealBox(id, 1, address(client)), 250_000);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("appeal", id, uint8(1))));
        pad.openAppeal(id);
        // Nobody draws the panel within PANEL_DRAW_WINDOW.
        vm.expectRevert();
        pad.settle(id);
        vm.warp(block.timestamp + 24 hours);
        vm.roll(block.number + 1);
        vm.expectRevert();
        pad.drawPanel(id);
        uint256 before = _usdg(address(client));
        pad.settle(id);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Completed));
        assertEq(_usdg(address(client)) - before, 250_000, "the appeal fee comes back");
        assertEq(_usdg(p), 5e6 - 25_000);
        assertEq(pad.provider(p).active, 0);
        assertEq(pad.evaluator(e).active, 0);
    }

    /// @dev M1: a job the provider never accepted does not touch its bond cooldown.
    function test_openJobExpiryLeavesTheProviderCooldown() public {
        address p = makeAddr("provider");
        deal(USDG, p, 10e6);
        vm.startPrank(p);
        IERC20(USDG).approve(address(pad), 10e6);
        pad.depositProviderBond(p, 10e6);
        vm.stopPrank();
        address other = makeAddr("someone");
        deal(USDG, other, 1e6);
        vm.startPrank(other);
        IERC20(USDG).approve(address(pad), 1e6);
        bytes32 id = pad.create(_terms(other, p, other, 1e6, bytes32(0), bytes32("grief")));
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        pad.settle(id);
        assertEq(pad.provider(p).lastEnd, 0);
        vm.prank(p);
        pad.withdrawProviderBond(p);
        assertEq(_usdg(p), 10e6);
    }

    /// @dev M2: replacing a silent evaluator after the expiry does not let the submitted job expire unjudged.
    function test_silentReplacementAfterExpiryStillGetsJudged() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.warp(block.timestamp + 7 days - 1 hours);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.warp(block.timestamp + 48 hours);
        pad.draw(id); // the silent evaluator is replaced, after the expiry
        assertFalse(pad.evaluator(e).inPool);
        vm.expectRevert();
        pad.settle(id);
        vm.roll(block.number + 1);
        pad.draw(id);
        address e2 = pad.job(id).evaluator;
        vm.prank(e2);
        pad.decide(id, true, bytes32("ok"));
        vm.warp(block.timestamp + 48 hours);
        pad.settle(id);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Completed));
    }

    function test_noAcceptTooLateForTheReveal() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id,) = _vaultJob(p, address(0), 3e6, keccak256(abi.encode(bytes32("c"))));
        vm.warp(block.timestamp + 6 days);
        vm.prank(p);
        vm.expectRevert();
        pad.accept(id, keccak256(abi.encode(bytes32("p"))));
    }

    /// @dev M3: an appeal fee sent for an appeal that never opened is returned once no appeal can open.
    function test_appealBoxReturnedAfterTheWindow() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));
        _transfer(client, CLIENT_KEYS, pad.appealBox(id, 1, address(client)), 250_000);
        vm.expectRevert(OstraPad.Busy.selector);
        pad.sweepAppealBox(id, 1, address(client));
        vm.warp(block.timestamp + 48 hours);
        pad.settle(id);
        uint256 before = _usdg(address(client));
        pad.sweepAppealBox(id, 1, address(client));
        assertEq(_usdg(address(client)) - before, 250_000);
    }

    /// @dev M3: a job box for terms never created is returned to the client, on its own call only.
    function test_uncreatedJobBoxReturnedToTheClient() public {
        deal(USDG, address(client), 10e6);
        OstraPad.Terms memory t = _terms(address(client), address(providerVault), address(client), 1e6, bytes32(0), bytes32("never"));
        bytes32 id = pad.jobId(t);
        _transfer(client, CLIENT_KEYS, pad.jobBox(id), 2e6);
        vm.expectRevert(OstraPad.NotAuthorized.selector);
        pad.sweepJobBox(t);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("sweep job", id, uint256(0))));
        pad.sweepJobBox(t);
        assertEq(_usdg(address(client)), 10e6);
    }

    /// @dev L1: nobody but its owner can empty a bond box.
    function test_bondBoxSweepNeedsItsOwner() public {
        deal(USDG, address(evalVault), 60e6);
        _transfer(evalVault, EVAL_KEYS, pad.bondBox(address(evalVault), true), 60e6);
        vm.expectRevert(OstraPad.NotAuthorized.selector);
        pad.sweepBondBox(address(evalVault), true);
        _approve(evalVault, EVAL_KEYS, keccak256(abi.encode("join", address(evalVault), uint256(60e6), uint256(0))));
        pad.joinPool(address(evalVault), 60e6);
        assertTrue(pad.evaluator(address(evalVault)).inPool);
    }

    /// @dev L2: the deciding evaluator stays bound (cannot withdraw) until its job settles.
    function test_decidingEvaluatorStaysBoundThroughTheAppealWindow() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));
        vm.prank(e);
        pad.leavePool(e);
        vm.warp(block.timestamp + 7 days);
        vm.prank(e);
        vm.expectRevert(OstraPad.Busy.selector);
        pad.withdrawEvaluatorBond(e);
        pad.settle(id);
        vm.prank(e);
        pad.withdrawEvaluatorBond(e);
        assertEq(_usdg(e), 100e6 + 50_000);
    }

    /// @dev L4: a full pool takes a larger newcomer in place of its smallest member.
    function test_fullPoolEvictsTheSmallest() public {
        for (uint256 i = 0; i < 128; i++) {
            address a = address(uint160(0x10000 + i));
            uint256 b = 50e6 + i;
            deal(USDG, a, b);
            vm.startPrank(a);
            IERC20(USDG).approve(address(pad), b);
            pad.joinPool(a, b);
            vm.stopPrank();
        }
        address big = makeAddr("big");
        deal(USDG, big, 60e6);
        vm.startPrank(big);
        IERC20(USDG).approve(address(pad), 60e6);
        vm.expectRevert(OstraPad.Busy.selector); // no membership has taken effect yet: none can be evicted
        pad.joinPool(big, 60e6);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days + 1);
        address small = makeAddr("small");
        deal(USDG, small, 50e6);
        vm.startPrank(small);
        IERC20(USDG).approve(address(pad), 50e6);
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.joinPool(small, 50e6);
        vm.stopPrank();
        vm.startPrank(big);
        pad.joinPool(big, 60e6);
        vm.stopPrank();
        assertEq(pad.pool().length, 128);
        assertFalse(pad.evaluator(address(uint160(0x10000))).inPool, "the smallest left");
        assertTrue(pad.evaluator(big).inPool);
    }

    /// @dev M4: pool-judged jobs of 1 USDG or more build the record; the first tier needs 10 completed, 5 clients and
    ///      100 USDG completed: 10 jobs of 5 USDG are not enough, 20 are.
    function test_recordAndTierFromPoolJobs() public {
        _pool(100e6);
        address p = makeAddr("provider");
        for (uint256 i = 0; i < 20; i++) {
            if (i == 10) {
                assertEq(pad.provider(p).completed, 10);
                assertEq(pad.provider(p).volume, 50e6);
                assertEq(pad.limitOf(p), 5e6, "10 jobs and 5 clients, but only 50 USDG completed");
            }
            address c = address(uint160(0x20000 + (i % 5)));
            deal(USDG, c, 6e6);
            bytes32 cs = keccak256(abi.encode("cs", i));
            bytes32 ps = keccak256(abi.encode("ps", i));
            vm.startPrank(c);
            IERC20(USDG).approve(address(pad), 6e6);
            bytes32 id = pad.create(_terms(c, p, address(0), 5e6, keccak256(abi.encode(cs)), bytes32(i)));
            vm.stopPrank();
            vm.prank(p);
            pad.accept(id, keccak256(abi.encode(ps)));
            pad.reveal(id, cs);
            pad.reveal(id, ps);
            vm.roll(block.number + 1);
            pad.draw(id);
            vm.prank(p);
            pad.submit(id, bytes32("w"));
            address e = pad.job(id).evaluator;
            vm.prank(e);
            pad.decide(id, true, bytes32("ok"));
            vm.warp(block.timestamp + 48 hours);
            pad.settle(id);
        }
        OstraPad.Provider memory r = pad.provider(p);
        assertEq(r.completed, 20);
        assertEq(r.clients, 5);
        assertEq(r.volume, 100e6);
        assertEq(pad.limitOf(p), 25e6);
    }

    /// @dev N2: a member that leaves after the snapshot is still drawn, and must act; one removed for misconduct is not.
    function test_leavingAfterTheSnapshotDoesNotShrinkThePool() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));
        _transfer(client, CLIENT_KEYS, pad.appealBox(id, 1, address(client)), 250_000);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("appeal", id, uint8(1))));
        pad.openAppeal(id);
        uint256 t = pad.appeal(id).openedAt;
        for (uint256 i = 0; i < 5; i++) {
            if (evals[i] == e) continue;
            vm.prank(evals[i]);
            pad.leavePool(evals[i]);
        }
        assertEq(pad.eligibleCount(5e6, t, address(client), p, e), 4, "the four others still count at the snapshot");
        vm.roll(block.number + 1);
        pad.drawPanel(id);
        address[3] memory panel = pad.appeal(id).panel;
        assertTrue(panel[0] != address(0) && panel[2] != address(0));
        assertEq(pad.evaluator(panel[0]).active, 1, "bound to vote though it left");
    }

    /// @dev N6: a fresh join waits STAKE_DELAY like a top-up.
    function test_joinWaitsItsDelay() public {
        deal(USDG, evals[0], 100e6);
        vm.startPrank(evals[0]);
        IERC20(USDG).approve(address(pad), 100e6);
        pad.joinPool(evals[0], 100e6);
        vm.stopPrank();
        assertEq(pad.stakeAt(evals[0], block.timestamp + 1), 0);
        assertEq(pad.stakeAt(evals[0], block.timestamp + 2 days + 1), 100e6);
    }

    /// @dev N3: a client's sweep approval for uncreated terms cannot be replayed.
    function test_sweepJobApprovalIsSingleUse() public {
        deal(USDG, address(client), 10e6);
        OstraPad.Terms memory t = _terms(address(client), address(providerVault), address(client), 1e6, bytes32(0), bytes32("again"));
        bytes32 id = pad.jobId(t);
        _transfer(client, CLIENT_KEYS, pad.jobBox(id), 1e6);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("sweep job", id, uint256(0))));
        pad.sweepJobBox(t);
        _transfer(client, CLIENT_KEYS, pad.jobBox(id), 1e6);
        vm.expectRevert(OstraPad.NotAuthorized.selector);
        pad.sweepJobBox(t);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("create", id)));
        pad.create(t);
        assertEq(uint8(pad.job(id).status), uint8(OstraPad.Status.Open));
    }

    // ---------------------------------------------------------------------------------------------
    // Round 3: bounded snapshots, the draw list, slashes
    // ---------------------------------------------------------------------------------------------

    function _join(address e, uint256 amount) internal {
        deal(USDG, e, amount);
        vm.startPrank(e);
        IERC20(USDG).approve(address(pad), amount);
        pad.joinPool(e, amount);
        vm.stopPrank();
    }

    /// @dev A member leaves only once its membership took effect.
    function test_leaveWaitsForItsMembership() public {
        _join(evals[0], 100e6);
        uint256 effective = block.timestamp + 2 days;
        vm.prank(evals[0]);
        vm.expectRevert(abi.encodeWithSelector(OstraPad.TooEarly.selector, effective));
        pad.leavePool(evals[0]);
        vm.warp(effective);
        vm.prank(evals[0]);
        pad.leavePool(evals[0]);
        assertFalse(pad.evaluator(evals[0]).inPool);
    }

    /// @dev Churn (128 members join and leave, 128 more join) cannot fill the draw list against a newcomer: members
    ///      gone longer than SNAPSHOT_TTL are pruned to make room, and a full pool still evicts its smallest.
    function test_churnNeverFillsTheDrawList() public {
        for (uint256 i = 0; i < 128; i++) _join(address(uint160(0x70000 + i)), 50e6);
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < 128; i++) {
            vm.prank(address(uint160(0x70000 + i)));
            pad.leavePool(address(uint160(0x70000 + i)));
        }
        for (uint256 i = 0; i < 128; i++) _join(address(uint160(0x80000 + i)), 50e6);
        assertEq(pad.members().length, 256);
        assertEq(pad.poolSize(), 128);
        vm.warp(block.timestamp + 2 days);
        address whale = makeAddr("whale");
        _join(whale, 500e6);
        assertTrue(pad.evaluator(whale).inPool);
        assertEq(pad.poolSize(), 128);
        assertEq(pad.members().length, 256, "one stale member pruned for the newcomer");
        // A stale member can be pruned by anyone; one gone within SNAPSHOT_TTL cannot.
        address gone = address(uint160(0x70001));
        if (pad.members()[0] == gone || pad.members()[1] == gone) gone = address(uint160(0x70002));
        pad.prune(gone);
        assertEq(pad.members().length, 255);
        address evicted;
        for (uint256 i = 0; i < 128; i++) {
            if (!pad.evaluator(address(uint160(0x80000 + i))).inPool) evicted = address(uint160(0x80000 + i));
        }
        assertTrue(evicted != address(0));
        vm.expectRevert(OstraPad.BadParams.selector);
        pad.prune(evicted);
        // Bonds of pruned members stay withdrawable.
        vm.warp(block.timestamp + 7 days);
        vm.prank(gone);
        pad.withdrawEvaluatorBond(gone);
        assertEq(_usdg(gone), 50e6);
    }

    /// @dev A draw whose snapshot is older than SNAPSHOT_TTL is re-armed with a new snapshot and block.
    function test_staleSnapshotIsRearmed() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        bytes32 cs = keccak256("client secret");
        bytes32 ps = keccak256("provider secret");
        (bytes32 id,) = _vaultJob(p, address(0), 5e6, keccak256(abi.encode(cs)));
        vm.prank(p);
        pad.accept(id, keccak256(abi.encode(ps)));
        pad.reveal(id, cs);
        pad.reveal(id, ps);
        uint256 armed = pad.job(id).drawAt;
        vm.roll(block.number + 1);
        vm.warp(armed + 24 hours + 1);
        pad.draw(id);
        assertEq(pad.job(id).evaluator, address(0), "re-armed, not drawn");
        assertEq(pad.job(id).drawAt, block.timestamp);
        vm.roll(block.number + 1);
        pad.draw(id);
        assertTrue(pad.job(id).evaluator != address(0));
    }

    /// @dev A top-up after a snapshot does not refill a slash at that snapshot.
    function test_topUpDoesNotRefillASlash() public {
        deal(USDG, address(client), 50e6);
        _pool(100e6);
        address p = makeAddr("provider");
        (bytes32 id, address e) = _poolJobDrawn(5e6, p);
        vm.prank(p);
        pad.submit(id, bytes32("work"));
        vm.prank(e);
        pad.decide(id, true, bytes32("ok"));
        _transfer(client, CLIENT_KEYS, pad.appealBox(id, 1, address(client)), 250_000);
        _approve(client, CLIENT_KEYS, keccak256(abi.encode("appeal", id, uint8(1))));
        pad.openAppeal(id);
        vm.roll(block.number + 1);
        pad.drawPanel(id);
        address[3] memory panel = pad.appeal(id).panel;
        for (uint256 k = 0; k < 3; k++) {
            vm.prank(panel[k]);
            pad.vote(id, uint8(k), false);
        }
        assertEq(pad.evaluator(e).bond, 99e6);
        assertTrue(pad.evaluator(e).inPool);
        vm.warp(block.timestamp + 10);
        uint256 t = block.timestamp;
        vm.warp(block.timestamp + 10);
        assertEq(pad.stakeAt(e, t), 99e6);
        _join(e, 1e6);
        assertEq(pad.stakeAt(e, t), 99e6, "the old snapshot keeps the slash");
        assertEq(pad.stakeAt(e, block.timestamp + 2 days), 100e6, "the top-up counts once it matures");
    }
}
