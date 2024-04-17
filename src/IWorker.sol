// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ITimeToken } from "./ITimeToken.sol";
import { MinionCoordinator } from "./MinionCoordinator.sol";

interface IWorker {
    function minionCoordinator() external view returns (MinionCoordinator);
    function timeToken() external view returns (ITimeToken);
    function DONATION_ADDRESS() external view returns (address);
    function DONATION_FEE() external view returns (uint256);
    function CALLER_FEE() external view returns (uint256);
    function FACTOR() external view returns (uint256);
    function INVESTMENT_FEE() external view returns (uint256);
    function MAX_PERCENTAGE_ALLOCATION_OF_TIME() external view returns (uint256);
    function MINION_CREATION_FEE() external view returns (uint256);
    function baseTimeFrame() external view returns (uint256);
    function earnedAmount() external view returns (uint256);
    function availableTimeAsCaller(address depositant) external view returns (uint256);
    function blockToUnlock(address depositant) external view returns (uint256);
    function calculateTimeToLock(uint256 amountTup) external view returns (uint256);
    function callToProduction(address callerAddress) external;
    function createMinions() external payable returns (uint256);
    function investWithNoCapital() external;
    function mintTupAsDepositant(bool reinvestTup) external payable;
    function mintTupAsThirdParty(address minter, bool reinvestTup) external payable;
    function queryAvailableTimeForDepositant(address depositant) external view returns (uint256);
    function queryAvailableTimeForTupMint(uint256 amountNative) external view returns (uint256);
    function queryFeeAmountToActivateMinions(uint256 numberOfMinions) external view returns (uint256);
    function queryMinNativeAmountToMintTup() external view returns (uint256);
    function queryNumberOfMinionsToActivateFromAmount(uint256 amount) external view returns (uint256);
    function updateBatchSize(uint256 newBatchSize) external;
    function updateBaseTimeFrame(uint256 newBaseTimeFrame) external;
    function updateMinionCoordinator(MinionCoordinator newMinionCoordinator) external;
}
