// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { TicketComboTrackerTester } from "../../contracts/mocks/TicketComboTrackerTester.sol";

/// Differential fuzz: tracker tier counts (unique + dup) vs brute force over the inserted tickets.
contract ComboFuzzTest is Test {
    function _pick(uint256 seed, uint8 n) internal pure returns (uint8[] memory s) {
        s = new uint8[](5);
        uint256 used;
        uint256 c;
        uint256 nonce;
        while (c < 5) {
            uint8 v = uint8(1 + uint256(keccak256(abi.encode(seed, nonce++))) % n);
            if (used & (1 << v) == 0) { used |= 1 << v; s[c++] = v; }
        }
    }

    function testFuzz_tierCountsMatchBruteForce(uint256 seed, uint8 nRaw, uint8 bRaw, uint8 countRaw) public {
        uint8 n = uint8(bound(nRaw, 6, 12));     // small range -> many overlaps and duplicates
        uint8 b = uint8(bound(bRaw, 1, 4));
        uint256 count = bound(countRaw, 1, 40);
        TicketComboTrackerTester t = new TicketComboTrackerTester();
        t.init(n, b, 5);

        uint8[][] memory tn = new uint8[][](count);
        uint8[] memory tb = new uint8[](count);
        uint256[] memory masks = new uint256[](count);
        for (uint256 i; i < count; i++) {
            tn[i] = _pick(uint256(keccak256(abi.encode(seed, i))), n);
            tb[i] = uint8(1 + uint256(keccak256(abi.encode(seed, i, "b"))) % b);
            t.insert(tn[i], tb[i]);
            for (uint256 k; k < 5; k++) masks[i] |= 1 << tn[i][k];
        }
        uint8[] memory w = _pick(uint256(keccak256(abi.encode(seed, "w"))), n);
        uint8 wb = uint8(1 + uint256(keccak256(abi.encode(seed, "wb"))) % b);
        uint256 wm;
        for (uint256 k; k < 5; k++) wm |= 1 << w[k];

        (, uint256[] memory u, uint256[] memory d) = t.countTierMatchesWithBonusball(w, wb);

        uint256[12] memory expected;
        for (uint256 i; i < count; i++) {
            uint256 m = _popcount(masks[i] & wm);
            uint256 tier = 2 * m + (tb[i] == wb ? 1 : 0);
            expected[tier]++;
        }
        // tier 0 is not computed by the tracker (never paid); compare tiers 1..11
        for (uint256 tier = 1; tier < 12; tier++) {
            assertEq(u[tier] + d[tier], expected[tier], "tier count mismatch");
        }
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) { c += x & 1; x >>= 1; }
    }
}
