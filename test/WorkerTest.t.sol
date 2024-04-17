// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { console } from "forge-std/console.sol";
import { stdStorage, StdStorage, StdCheats, Test } from "forge-std/Test.sol";
import { Worker, ITimeToken, ITimeIsUp, IEmployer, MinionCoordinator } from "../src/Worker.sol";

contract WorkerTest is Test {
    // POLYGON MAINNET
    address public constant EMPLOYER_ADDRESS = 0x496ebDb161a87FeDa58f7EFFf4b2B94E10a1b655;
    address public constant TIME_EXCHANGE_ADDRESS = 0xb46F8A90492D0d03b8c3ab112179c56F89A6f3e0;
    address public constant TIME_TOKEN_ADDRESS = 0x1666Cf136d89Ba9071C476eaF23035Bccd7f3A36;
    address public constant TIME_IS_UP_ADDRESS = 0x57685Ddbc1498f7873963CEE5C186C7D95D91688;
    address public constant SPONSOR_ADDRESS = 0x4925784808cdcb23DA64BCbb7B5827ebc344B168;

    // address public constant VAULT_ADDRESS = ;

    Worker worker;
    ITimeToken timeToken;
    ITimeIsUp tup;
    IEmployer employer;

    receive() external payable { }

    fallback() external payable { }

    function setUp() public {
        vm.label(EMPLOYER_ADDRESS, "Employer");
        vm.label(TIME_EXCHANGE_ADDRESS, "TimeExchange");
        vm.label(TIME_TOKEN_ADDRESS, "TIME");
        vm.label(TIME_IS_UP_ADDRESS, "TUP");
        vm.label(SPONSOR_ADDRESS, "Sponsor");

        timeToken = ITimeToken(payable(TIME_TOKEN_ADDRESS));
        tup = ITimeIsUp(payable(TIME_IS_UP_ADDRESS));
        employer = IEmployer(payable(EMPLOYER_ADDRESS));
        worker = new Worker(TIME_TOKEN_ADDRESS, TIME_IS_UP_ADDRESS, EMPLOYER_ADDRESS, SPONSOR_ADDRESS);
    }

    function _createMinionsOnDemand(uint256 amount) private returns (uint256 numberOfMinionsCreated) {
        vm.assume(amount > 0.01 ether && amount <= 100_000 ether);
        vm.deal(address(this), amount);
        numberOfMinionsCreated = worker.createMinions{ value: amount }();
        emit log_named_uint("Number of Minions Created ", numberOfMinionsCreated);
    }

    function _depositTupAndLock(uint256 amount) private {
        vm.assume(amount > 0.01 ether && amount <= 100_000 ether);
        vm.deal(address(this), amount);

        tup.buy{ value: amount }();
        tup.approve(address(worker), tup.balanceOf(address(this)));
        worker.depositTup(tup.balanceOf(address(this)));

        emit log_named_uint("TUP Total Supply   ", tup.totalSupply());
        emit log_named_uint("Deposited in TUP   ", worker.depositedTup(address(this)));
        emit log_named_uint("Current Block      ", block.number);
        emit log_named_uint("Block to Unlock    ", worker.blockToUnlock(address(this)));
        emit log_named_uint("Locked Time        ", worker.blockToUnlock(address(this)) - block.number);

        assertGt(worker.depositedTup(address(this)), 0);
        assertGt(worker.blockToUnlock(address(this)), 0);
        assertEq(worker.depositedTup(address(1)), 0);
        assertEq(worker.blockToUnlock(address(1)), 0);
    }

    function _forwardTupToInvestor(uint256 amount) private {
        _depositTupAndLock(amount);
        vm.roll(block.number + 1);
        vm.deal(address(this), amount * 100);
        tup.receiveProfit{ value: amount * 20 }();
        tup.splitSharesWithReward();
        vm.roll(block.number + 2);
        worker.callToProduction(address(this));
    }

    function _testMintTupAsThirdParty(uint256 amount) private {
        worker.updateBatchSize(10);
        vm.deal(address(this), amount * 10);
        _createMinionsOnDemand(amount);
        vm.roll(block.number + 5_000_000);
        worker.callToProduction(address(this));
        vm.roll(block.number + 5_000_001);
        uint256 balanceInTupBefore = tup.balanceOf(address(this));
        vm.deal(address(this), amount * 10);
        emit log_named_uint("Native Balance         ", address(this).balance);
        if (worker.depositedTup(address(this)) == 0) {
            worker.mintTupAsThirdParty{ value: amount }(address(this), false);
        }
        uint256 balanceInTupAfter = tup.balanceOf(address(this));
        emit log_named_uint("TUP Balance Before     ", balanceInTupBefore);
        emit log_named_uint("TUP Balance After      ", balanceInTupAfter);
        emit log_named_uint("Worker Balance in TIME ", timeToken.balanceOf(address(worker)));
        assertGt(balanceInTupAfter, balanceInTupBefore);
    }

    function _testTimeAsReward(uint256 amount) private {
        worker.updateBatchSize(5);
        vm.deal(address(this), amount * 100);
        _createMinionsOnDemand(amount);
        uint256 availableTimeBefore = worker.availableTimeAsCaller(address(this));
        vm.roll(block.number + 5_000_000);
        worker.callToProduction(address(this));
        uint256 availableTimeAfter = worker.availableTimeAsCaller(address(this));
        vm.roll(block.number + 5_000_010);
        vm.deal(address(this), amount * 100);
        worker.mintTupAsThirdParty{ value: amount }(address(this), false);
        uint256 rewardedTime = timeToken.balanceOf(address(this));
        emit log_named_uint("TIME Rewarded          ", rewardedTime);
        emit log_named_uint("Available TIME Before  ", availableTimeBefore);
        emit log_named_uint("Available TIME After   ", availableTimeAfter);
        assertGt(availableTimeAfter, availableTimeBefore);
        assertGt(rewardedTime, 0);
    }

    function _testTupMintAsDepositant(uint256 amount, bool reinvestTup) private {
        worker.updateBatchSize(2);
        vm.roll(block.number + 1);
        _createMinionsOnDemand(amount);
        vm.roll(block.number + 5_000_000);
        _depositTupAndLock(amount);
        vm.roll(block.number + 5_000_001);
        worker.callToProduction(address(this));
        uint256 balanceInTime = timeToken.balanceOf(address(worker));
        vm.deal(address(this), amount);
        vm.roll(block.number + 5_000_010);
        uint256 balanceInTupBefore = tup.balanceOf(address(this));
        uint256 depositedTupBefore = worker.depositedTup(address(this));
        worker.mintTupAsDepositant{ value: amount }(reinvestTup);
        uint256 depositedTupAfter = worker.depositedTup(address(this));
        uint256 balanceInTupAfter = tup.balanceOf(address(this));
        emit log_named_uint("Worker Balance in TIME ", balanceInTime);
        emit log_named_uint("TUP Balance Before     ", balanceInTupBefore);
        emit log_named_uint("TUP Balance After      ", balanceInTupAfter);
        emit log_named_uint("Deposited TUP Before   ", depositedTupBefore);
        emit log_named_uint("Deposited TUP After    ", depositedTupAfter);
        if (!reinvestTup) {
            assertGt(balanceInTupAfter, balanceInTupBefore);
        } else {
            assertGt(depositedTupAfter, depositedTupBefore);
        }
    }

    function _testInvestmentWithNoCapital(uint256 amount) private {
        worker.updateBatchSize(10);
        vm.deal(address(this), amount * 100);
        _createMinionsOnDemand(amount);
        vm.roll(block.number + 5_000_000);
        uint256 depositedTupBefore = worker.depositedTup(address(this));
        vm.deal(address(this), amount * 100);
        payable(address(worker)).call{ value: amount * 10 }("");
        worker.investWithNoCapital();
        vm.roll(block.number + 5_000_001);
        vm.deal(address(this), amount * 10);
        uint256 depositedTupAfter = worker.depositedTup(address(this));
        emit log_named_uint("Deposited TUP Before   ", depositedTupBefore);
        emit log_named_uint("Deposited TUP After    ", depositedTupAfter);
        assertEq(depositedTupBefore, 0);
        assertGt(depositedTupAfter, depositedTupBefore);
    }

    // function _testTupForwardingToInvestor(uint256 amount) private {
    //     _depositTupAndLock(amount);
    //     vm.roll(block.number + 1);
    //     vm.deal(address(this), amount * 100);
    //     tup.receiveProfit{ value: amount * 20 }();
    //     uint256 investorBalanceInTupBefore = tup.balanceOf(address(worker.investor()));
    //     uint256 investorSharesBefore = worker.investor().balanceOf(address(worker));
    //     tup.splitSharesWithReward();
    //     vm.roll(block.number + 2);
    //     worker.callToProduction(address(this));
    //     uint256 investorBalanceInTupAfter = tup.balanceOf(address(worker.investor()));
    //     uint256 investorSharesAfter = worker.investor().balanceOf(address(worker));
    //     emit log_named_uint("Investor Balance in TUP Before     ", investorBalanceInTupBefore);
    //     emit log_named_uint("Investor Balance in TUP After      ", investorBalanceInTupAfter);
    //     emit log_named_uint("Investor Shares for Woker Before   ", investorSharesBefore);
    //     emit log_named_uint("Investor Shares for Woker After    ", investorSharesAfter);
    //     assertGt(investorBalanceInTupAfter, investorBalanceInTupBefore);
    //     assertGt(investorSharesAfter, investorSharesBefore);
    // }

    function testTupDepositAndLock() public {
        _depositTupAndLock(1000 ether);
    }

    function testFuzzTupDepositAndLock(uint256 amount) public {
        _depositTupAndLock(amount);
    }

    function testMinionCreation() public {
        uint256 numberOfMinions = _createMinionsOnDemand(5 ether);
        assertGt(numberOfMinions, 0);
    }

    function testFuzzMinionCreation(uint256 amount) public {
        uint256 numberOfMinions = _createMinionsOnDemand(amount);
        assertGt(numberOfMinions, 0);
    }

    function testMinionCreationOutOfDemand() public {
        vm.deal(address(this), 10 ether);
        address(worker.minionCoordinator()).call{ value: 10 ether }("");
        _depositTupAndLock(10 ether);
        emit log_named_uint("Active Minions ", MinionCoordinator(worker.minionCoordinator()).activeMinions());
        assertGt(MinionCoordinator(worker.minionCoordinator()).activeMinions(), 0);
    }

    function testTimeProduction() public {
        _createMinionsOnDemand(5 ether);
        uint256 balanceInTimeBefore = timeToken.balanceOf(address(worker));
        vm.roll(block.number + 500_000);
        worker.callToProduction(address(this));
        uint256 balanceInTimeAfter = timeToken.balanceOf(address(worker));
        emit log_named_uint("Balance in TIME after production ", balanceInTimeAfter);
        assertGt(balanceInTimeAfter, balanceInTimeBefore);
    }

    function testTimeAsReward() public {
        _testTimeAsReward(1 ether);
    }

    function testFuzzTimeAsReward(uint256 amount) public {
        vm.assume(amount >= 0.01 ether && amount <= 4 ether);
        _testTimeAsReward(amount);
    }

    function testTupMintAsThirdParty() public {
        _testMintTupAsThirdParty(1 ether);
    }

    function testFuzzTupMintAsThirdParty(uint256 amount) public {
        vm.assume(amount >= 0.01 ether && amount < 4 ether);
        _testMintTupAsThirdParty(amount);
    }

    function testTupMintAsDepositant() public {
        _testTupMintAsDepositant(1 ether, false);
    }

    function testFuzzTupMintAsDepositant(uint256 amount, bool reinvestTup) public {
        vm.assume(amount >= 0.01 ether && amount < 4 ether);
        _testTupMintAsDepositant(amount, reinvestTup);
    }

    function testTupMintAsDepositantWithReinvestment() public {
        _testTupMintAsDepositant(1 ether, true);
    }

    function testInvestmentWithNoCapital() public {
        _testInvestmentWithNoCapital(1 ether);
    }

    // function testTupForwardingToInvestor() public {
    //     uint256 amount = 1 ether;
    //     _testTupForwardingToInvestor(amount);
    // }

    // function testFuzzTupForwardingToInvestor(uint256 amount) public {
    //     vm.assume(amount >= 0.01 ether && amount < 10 ether);
    //     _testTupForwardingToInvestor(amount);
    // }

    // function testAllocationOfInvestments() public {
    //     uint256 amount = 10 ether;
    //     _forwardTupToInvestor(amount);
    //     Investor(worker.investor()).addVaultFromOwner();
    // }
}
