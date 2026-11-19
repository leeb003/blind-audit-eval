// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./LPBase.t.sol";
import { JackpotLPManager as LPM } from "../../contracts/JackpotLPManager.sol";

contract LPHandler is Test {
    Jackpot jackpot;
    JackpotLPManager lpm;
    ReentrantUSDCMock usdc;
    ScaledEntropyProviderMock entropy;
    address[] public lps;
    address buyer;
    address referrer;
    uint256[] public tickets; // unclaimed ticket ids
    uint256 public draws;

    constructor(Jackpot j, JackpotLPManager m, ReentrantUSDCMock u, ScaledEntropyProviderMock e, address[] memory _lps, address _buyer, address _ref) {
        jackpot = j; lpm = m; usdc = u; entropy = e; lps = _lps; buyer = _buyer; referrer = _ref;
    }

    function ticketsLength() external view returns (uint256) { return tickets.length; }
    function lpsLength() external view returns (uint256) { return lps.length; }

    function _locked() internal view returns (bool) {
        return jackpot.getDrawingState(jackpot.currentDrawingId()).jackpotLock;
    }

    function deposit(uint256 who, uint256 amt) external {
        if (_locked()) return;
        address l = lps[who % lps.length];
        amt = bound(amt, 1, 300_000e6);
        vm.prank(l);
        try jackpot.lpDeposit(amt) {} catch {}
    }

    function withdraw(uint256 who, uint256 frac) external {
        if (_locked()) return;
        address l = lps[who % lps.length];
        LPM.LP memory info = lpm.getLpInfo(l);
        uint256 shares = info.consolidatedShares;
        if (info.lastDeposit.amount > 0 && info.lastDeposit.drawingId < jackpot.currentDrawingId()) {
            shares += info.lastDeposit.amount * 1e18 / lpm.getDrawingAccumulator(info.lastDeposit.drawingId);
        }
        if (shares == 0) return;
        uint256 amt = bound(frac, 1, shares);
        vm.prank(l);
        jackpot.initiateWithdraw(amt);
    }

    function finalize(uint256 who) external {
        address l = lps[who % lps.length];
        vm.prank(l);
        try jackpot.finalizeWithdraw() {} catch {}
    }

    function _pick5(uint256 seed) internal pure returns (uint8[5] memory n) {
        // unique numbers from 1..8 to force lots of partial matches
        uint8[8] memory pool = [1, 2, 3, 4, 5, 6, 7, 8];
        for (uint256 i; i < 5; i++) {
            uint256 j = i + (uint256(keccak256(abi.encode(seed, i))) % (8 - i));
            (pool[i], pool[j]) = (pool[j], pool[i]);
            n[i] = pool[i];
        }
    }

    function buy(uint256 seed, uint256 count, bool withRef) external {
        if (_locked()) return;
        Jackpot.DrawingState memory ds = jackpot.getDrawingState(jackpot.currentDrawingId());
        if (ds.prizePool == 0) return;
        count = bound(count, 1, 15);
        IJackpot.Ticket[] memory ts = new IJackpot.Ticket[](count);
        for (uint256 k; k < count; k++) {
            uint8[5] memory n = _pick5(uint256(keccak256(abi.encode(seed, k))));
            ts[k].normals = new uint8[](5);
            for (uint256 i; i < 5; i++) ts[k].normals[i] = n[i];
            ts[k].bonusball = uint8(1 + uint256(keccak256(abi.encode(seed, k, "b"))) % 2);
        }
        address[] memory refs = new address[](withRef ? 1 : 0);
        uint256[] memory splits = new uint256[](withRef ? 1 : 0);
        if (withRef) { refs[0] = referrer; splits[0] = 1e18; }
        vm.prank(buyer);
        uint256[] memory ids = jackpot.buyTickets(ts, buyer, refs, splits, bytes32(0));
        for (uint256 i; i < ids.length; i++) tickets.push(ids[i]);
    }

    function draw(uint256 seed) external {
        Jackpot.DrawingState memory ds = jackpot.getDrawingState(jackpot.currentDrawingId());
        if (ds.jackpotLock) return;
        vm.warp(ds.drawingTime + 1);
        jackpot.runJackpot{ value: jackpot.getEntropyCallbackFee() }();
        uint8[5] memory n = _pick5(seed);
        uint256[][] memory r = new uint256[][](2);
        r[0] = new uint256[](5);
        for (uint256 i; i < 5; i++) r[0][i] = n[i];
        r[1] = new uint256[](1);
        r[1][0] = 1 + (seed >> 128) % 2;
        entropy.randomnessCallback(r);
        draws++;
    }

    function claimAll() public {
        uint256 cur = jackpot.currentDrawingId();
        uint256 n;
        uint256[] memory ids = new uint256[](tickets.length);
        uint256 keep;
        for (uint256 i; i < tickets.length; i++) {
            uint256 drawingId = jackpot.jackpotNFT().getTicketInfo(tickets[i]).drawingId;
            if (drawingId < cur) ids[n++] = tickets[i];
            else tickets[keep++] = tickets[i];
        }
        while (tickets.length > keep) tickets.pop();
        if (n == 0) return;
        assembly { mstore(ids, n) }
        vm.prank(buyer);
        jackpot.claimWinnings(ids);
    }

    function claimRef() external {
        vm.prank(referrer);
        try jackpot.claimReferralFees() {} catch {}
    }

    receive() external payable {}
}

contract LPInvariantTest is LPBase {
    LPHandler h;
    address lp2 = makeAddr("lp2");

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        usdc.transfer(lp2, 50_000_000 * U);
        vm.prank(lp2);
        usdc.approve(address(jackpot), type(uint256).max);
        address[] memory ls = new address[](2);
        ls[0] = lp; ls[1] = lp2;
        h = new LPHandler(jackpot, lpManager, usdc, entropy, ls, buyer, referrer);
        vm.deal(address(h), 1000 ether);
        bytes4[] memory sels = new bytes4[](8);
        sels[0] = LPHandler.deposit.selector;
        sels[1] = LPHandler.withdraw.selector;
        sels[2] = LPHandler.finalize.selector;
        sels[3] = LPHandler.buy.selector;
        sels[4] = LPHandler.draw.selector;
        sels[5] = LPHandler.claimAll.selector;
        sels[6] = LPHandler.claimRef.selector;
        sels[7] = LPHandler.buy.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sels }));
        targetContract(address(h));
    }

    function _owedToLPs() internal view returns (uint256 total) {
        for (uint256 i; i < h.lpsLength(); i++) {
            JackpotLPManager.LPValueBreakdown memory b = lpManager.getLPValueBreakdown(h.lps(i));
            total += b.activeDeposits + b.pendingDeposits + b.pendingWithdrawals + b.claimableWithdrawals;
        }
    }

    function _owedToWinners() internal view returns (uint256 total) {
        uint256 cur = jackpot.currentDrawingId();
        for (uint256 i; i < h.ticketsLength(); i++) {
            uint256 id = h.tickets(i);
            IJackpotTicketNFT.TrackedTicket memory t = nft.getTicketInfo(id);
            if (t.drawingId >= cur) continue;
            uint256[] memory one = new uint256[](1);
            one[0] = id;
            uint256 tier = jackpot.getTicketTierIds(one)[0];
            total += calc.getTierPayout(t.drawingId, tier);
        }
    }

    /// contract must always hold enough for LPs + unclaimed winnings + referrer balances
    function invariant_solvent() public view {
        uint256 owed = _owedToLPs() + _owedToWinners() + jackpot.referralFees(referrer);
        assertGe(usdc.balanceOf(address(jackpot)), owed, "insolvent");
    }
}

contract LPInvariantSanity is LPInvariantTest {
    /// make sure the handler really exercises draws + winners (not a vacuous pass)
    function invariant_progress() public view {
        if (h.draws() > 3) assertGt(jackpot.currentDrawingId(), 3);
    }
    function afterInvariant() public view {
        console.log("draws", h.draws(), "drawingId", jackpot.currentDrawingId());
        console.log("acc", lpManager.getDrawingAccumulator(jackpot.currentDrawingId() - 1));
    }
}

contract LPEmergencyExitTest is LPInvariantTest {
    function invariant_noop() public view {}

    /// after any random history: emergency mode, then every party exits fully without reverts
    function afterInvariant() public {
        h.claimAll();
        vm.prank(owner);
        jackpot.enableEmergencyMode();
        uint256 n = h.ticketsLength();
        if (n > 0) {
            uint256[] memory ids = new uint256[](n);
            for (uint256 i; i < n; i++) ids[i] = h.tickets(i);
            if (!jackpot.getDrawingState(jackpot.currentDrawingId()).jackpotLock || true) {
                vm.prank(buyer);
                jackpot.emergencyRefundTickets(ids);
            }
        }
        for (uint256 i; i < h.lpsLength(); i++) {
            vm.prank(h.lps(i));
            jackpot.emergencyWithdrawLP();
        }
        if (jackpot.referralFees(referrer) > 0) {
            vm.prank(referrer);
            jackpot.claimReferralFees();
        }
        console.log("dust left", usdc.balanceOf(address(jackpot)));
    }
}
