// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal factory = makeAddr("factory");

    function setUp() public {
        vm.prank(factory);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Dead Drop");
        assertEq(token.symbol(), "DROP");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(factory), token.totalSupply());
    }

    function test_transferMovesExactlyTheAmount() public {
        address alice = makeAddr("alice");
        vm.prank(factory);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(factory), 1_000_000_000e18 - 1_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_transferMoreThanBalanceReverts() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(factory, 1);
    }

    function test_hasNoMintOrAdminFunctions() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setFee(uint256)",
            "burnFrom(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(factory);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], factory, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
