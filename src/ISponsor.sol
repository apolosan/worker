// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface ISponsor {
    function isOperationTypeFlipped() external returns (bool);
    function timeExchange() external returns (address);
    function timeToken() external returns (address);
    function tupToken() external returns (address);
    function administrator() external returns (address);
    function currentLeader() external returns (address);
    function firstParticipant() external returns (address);
    function lastParticipant() external returns (address);
    function TIME_BURNING_RATE() external returns (uint256);
    function MININUM_NUMBER_OF_PARTICIPANTS() external returns (uint256);
    function NUMBER_OF_SELECTED_WINNERS() external returns (uint256);
    function accumulatedPrize() external returns (uint256);
    function currentAdditionalPrize() external returns (uint256);
    function currentPrize() external returns (uint256);
    function currentRebate() external returns (uint256);
    function currentTarget() external returns (uint256);
    function currentValueMoved() external returns (uint256);
    function maxInteractionPoints() external returns (uint256);
    function minAmountToEarnPoints() external returns (uint256);
    function numberOfParticipants() external returns (uint256);
    function round() external returns (uint256);
    function lastBlock(address account) external returns (uint256);
    function prizeToClaim(address account) external returns (uint256);
    function remainingTime(address account) external returns (uint256);
    function roundWinners(uint256 round) external returns (address, address, address, address);
    function participants(address participant) external returns (bool, bool, address, address);
    function claimPrize() external;
    function checkParticipation(address participant) external view returns (bool);
    function depositPrize() external payable;
    function emergencyWithdraw() external;
    function extendParticipationPeriod(uint256 amountTime) external;
    function flipOperationType() external;
    function mint(uint256 amountTime) external payable;
    function queryAmountRemainingForPrize() external view returns (uint256);
    function queryCurrentTotalPrize() external view returns (uint256);
    function queryInteractionPoints(address participant) external view returns (uint256);
    function queryValuePoints(address participant) external view returns (uint256);
    function setAdministrator(address newAdministrator) external;
    function setCurrentFeesPercentage(uint256 newCurrentFeesPercentage) external;
    function setMinAmountToEarnPoints(uint256 newMinAmount) external;
    function setPercentageProfitTarget(uint256 newProfitTargetPercentage) external;
    function setRebatePercentage(uint256 newRebatePercentage) external;
    function swap(address tokenFrom, address tokenTo, uint256 amount) external payable;
    function withdrawFromAddressZeroPrizes() external;
}
