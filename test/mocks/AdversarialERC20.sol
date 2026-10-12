// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Local token fault injection, not a proposed launch dependency.
contract AdversarialERC20 is ERC20 {
    enum Behavior {
        Normal,
        ReturnFalse,
        RevertTransfer,
        NoReturn,
        Fee,
        Reenter
    }
    error TokenTransferRejected();

    Behavior public behavior;
    address public matchFrom;
    address public matchTo;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbackCount;
    bool private callingBack;

    constructor() ERC20("Adversarial test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(Behavior value, address from, address to) external {
        behavior = value;
        matchFrom = from;
        matchTo = to;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackSucceeded = false;
        delete callbackResult;
        callbackCount = 0;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        bool selected = from == matchFrom && to == matchTo;
        Behavior active = selected ? behavior : Behavior.Normal;
        if (active == Behavior.ReturnFalse) return false;
        if (active == Behavior.RevertTransfer) revert TokenTransferRejected();
        if (active == Behavior.Fee) {
            uint256 fee = amount / 100;
            _burn(from, fee);
            _transfer(from, to, amount - fee);
        } else {
            _transfer(from, to, amount);
        }
        if (active == Behavior.Reenter && !callingBack) {
            callingBack = true;
            callbackCount++;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
            callingBack = false;
        }
        if (active == Behavior.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}
