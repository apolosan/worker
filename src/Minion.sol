// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ITimeToken } from "./ITimeToken.sol";

/// @title Minion contract
/// @author Einar Cesar - TIME Token Finance - https://timetoken.finance
/// @notice Has the ability to produce TIME tokens for any contract which extends its behavior
/// @dev It should have being enabled to produce TIME before or it will not work as desired. Sometimes, the coordinator address is the contract itself
contract Minion {
    ITimeToken internal immutable _timeToken;
    address internal _coordinator;

    constructor(address coordinatorAddress, ITimeToken timeToken) {
        _coordinator = coordinatorAddress;
        _timeToken = timeToken;
    }

    /// @notice Produce TIME tokens and transfer them to the registered coordinator, if it has one
    /// @dev If the coordinator is an external contract, it maintains a fraction of the produced TIME as incentive for the protocol (which increases the number of token holders)
    function _produceTime() internal {
        _timeToken.mining();
        if (_coordinator != address(this)) {
            uint256 amountToTransfer = (_timeToken.balanceOf(address(this)) * 9_999) / 10_000;
            if (amountToTransfer > 0) {
                _timeToken.transfer(_coordinator, amountToTransfer);
            }
        }
    }

    /// @notice Enables the contract to produce TIME tokens
    /// @dev It should be called right after the creation of the contract
    /// @return success Informs if the operation was carried correctly
    function enableMining() external payable returns (bool success) {
        require(msg.value > 0);
        try _timeToken.enableMining{ value: msg.value }() {
            success = true;
        } catch { }
        return success;
    }

    /// @notice External call for the _produceTime() function
    /// @dev Sometimes, when the Minion contract is inherited from another contract, it can calls the private function. Otherwise, the external function should exist in order to produce TIME for the contract
    function produceTime() external {
        _produceTime();
    }

    /// @notice Alters the coordinator address
    /// @dev Depending on the strategy, a new coordinator may be necessary for the Minion... Only the old coordinator must be responsible to designate the new one
    /// @param newCoordinator The new coordinator address
    function updateCoordinator(address newCoordinator) external {
        require(msg.sender == _coordinator, "Minion: only coordinator can call this function");
        _coordinator = newCoordinator;
    }
}
