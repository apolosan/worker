// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { console } from "forge-std/console.sol";
import { stdStorage, StdStorage, StdCheats, Test } from "forge-std/Test.sol";
import { WorkerVault, IEmployer, InvestmentCoordinator, ITimeIsUp, ITimeToken, MinionCoordinator } from "../src/WorkerVault.sol";
import { TimeTokenVault } from "../src/TimeTokenVault.sol";

contract WorkerVaultTest is Test {
    uint256 public blockNumber = block.number;
    // POLYGON MAINNET
    address public constant EMPLOYER_ADDRESS = 0x496ebDb161a87FeDa58f7EFFf4b2B94E10a1b655;
    address public constant ORACLE_ADDRESS = 0xc907E116054Ad103354f2D350FD2514433D57F6f;
    address public constant TIME_EXCHANGE_ADDRESS = 0xb46F8A90492D0d03b8c3ab112179c56F89A6f3e0;
    address public constant TIME_TOKEN_ADDRESS = 0x1666Cf136d89Ba9071C476eaF23035Bccd7f3A36;
    address public constant TIME_IS_UP_ADDRESS = 0x57685Ddbc1498f7873963CEE5C186C7D95D91688;
    address public constant ROUTER_ADDRESS = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address public constant SPONSOR_ADDRESS = 0x4925784808cdcb23DA64BCbb7B5827ebc344B168;
    address public constant WBTC_ADDRESS = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    WorkerVault workerVault;
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

        uint256 amount = 1 ether;
        vm.deal(address(this), (timeToken.fee() + amount) * 100);
        workerVault = new WorkerVault(TIME_IS_UP_ADDRESS, TIME_TOKEN_ADDRESS, EMPLOYER_ADDRESS, address(this));
        tup.buy{ value: amount }();
        tup.approve(address(workerVault), tup.balanceOf(address(this)));
        workerVault.mint(tup.balanceOf(address(this)), address(this));
        workerVault.transfer(address(0xdead), workerVault.balanceOf(address(this)));
        vm.label(address(workerVault), "vWORK");

        InvestmentCoordinator(workerVault.investmentCoordinator()).addVault(address(new TimeTokenVault(TIME_TOKEN_ADDRESS, address(this))));

        vm.label(address(workerVault.investmentCoordinator()), "InvestmentCoordinator");
    }

    function _createMinionsOnDemand(uint256 amount) private returns (uint256 numberOfMinionsCreated) {
        vm.assume(amount > 0.01 ether && amount <= 100_000 ether);
        vm.deal(address(this), amount);
        vm.roll(++blockNumber);
        numberOfMinionsCreated = workerVault.createMinions{ value: amount }();
        emit log_named_uint("Number of Minions Created          ", numberOfMinionsCreated);
    }

    function _depositTupAndLock(uint256 amount) private {
        vm.assume(amount > 0.01 ether && amount <= 100_000 ether);
        vm.deal(address(this), amount);

        vm.roll(++blockNumber);
        tup.buy{ value: amount }();
        uint256 amountToDeposit = tup.balanceOf(address(this));
        tup.approve(address(workerVault), amountToDeposit);
        workerVault.deposit(amountToDeposit, address(this));

        emit log_named_uint("TUP Total Supply                   ", tup.totalSupply());
        emit log_named_uint("TUP Balance on WorkerVault         ", tup.balanceOf(address(workerVault)));
        emit log_named_uint("Total Shares               (vWORK) ", workerVault.totalSupply());
        emit log_named_uint("Deposited Shares           (vWORK) ", workerVault.balanceOf(address(this)));
        emit log_named_uint("Deposited Assets           (TUP)   ", amountToDeposit);
        emit log_named_uint("Deposited Assets on Vault  (TUP)   ", workerVault.previewRedeem(workerVault.balanceOf(address(this))));
        emit log_named_uint("Current Block                      ", block.number);
        emit log_named_uint("Block to Unlock                    ", workerVault.blockToUnlock(address(this)));
        emit log_named_uint("Locked Time                        ", workerVault.blockToUnlock(address(this)) - block.number);

        assertGt(workerVault.balanceOf(address(this)), 0);
        assertGt(workerVault.blockToUnlock(address(this)), 0);
        assertEq(workerVault.balanceOf(address(1)), 0);
        assertEq(workerVault.blockToUnlock(address(1)), 0);
    }

    function _testMintTupAsThirdParty(uint256 amount) private {
        workerVault.updateBatchSize(10);
        vm.deal(address(this), amount * 10);
        _createMinionsOnDemand(amount);
        blockNumber += 5_000_000;
        vm.roll(++blockNumber);
        uint256 availableTimeBefore = workerVault.availableTimeAsCaller(address(this));
        workerVault.callToProduction(address(this));
        uint256 availableTimeAfter = workerVault.availableTimeAsCaller(address(this));
        vm.roll(++blockNumber);
        uint256 balanceInTupBefore = tup.balanceOf(address(this));
        vm.deal(address(this), amount * 10);
        emit log_named_uint("Native Balance         ", address(this).balance);
        if (workerVault.balanceOf(address(this)) == 0) {
            workerVault.mintTupAsThirdParty{ value: amount }(address(this), false);
        }
        uint256 availableTimeFinal = workerVault.availableTimeAsCaller(address(this));
        uint256 balanceInTupAfter = tup.balanceOf(address(this));
        emit log_named_uint("Available TIME Before              ", availableTimeBefore);
        emit log_named_uint("Available TIME After               ", availableTimeAfter);
        emit log_named_uint("Available TIME Final               ", availableTimeFinal);
        emit log_named_uint("TUP Balance Before                 ", balanceInTupBefore);
        emit log_named_uint("TUP Balance After                  ", balanceInTupAfter);
        emit log_named_uint("WorkerVault Balance in TIME        ", timeToken.balanceOf(address(workerVault)));
        assertGt(balanceInTupAfter, balanceInTupBefore);
        assertGt(availableTimeAfter, availableTimeBefore);
        assertNotEq(availableTimeFinal, availableTimeAfter);
    }

    function _testTupMintAsDepositant(uint256 amount, bool reinvestTup) private {
        workerVault.updateBatchSize(10);
        vm.roll(++blockNumber);
        _createMinionsOnDemand(amount);
        blockNumber += 5_000_000;
        vm.roll(++blockNumber);
        _depositTupAndLock(amount);
        vm.roll(++blockNumber);
        workerVault.callToProduction(address(this));
        uint256 balanceInTime = timeToken.balanceOf(address(workerVault));
        vm.deal(address(this), amount);
        vm.roll(++blockNumber);
        uint256 balanceInTupBefore = tup.balanceOf(address(this));
        uint256 vaultBalanceBefore = workerVault.balanceOf(address(this));
        workerVault.mintTupAsDepositant{ value: amount }(reinvestTup);
        uint256 vaultBalanceAfter = workerVault.balanceOf(address(this));
        uint256 balanceInTupAfter = tup.balanceOf(address(this));
        emit log_named_uint("WorkerVault Balance in TIME        ", balanceInTime);
        emit log_named_uint("TUP Balance Before                 ", balanceInTupBefore);
        emit log_named_uint("TUP Balance After                  ", balanceInTupAfter);
        emit log_named_uint("Vault Balance Before (vWORK)       ", vaultBalanceBefore);
        emit log_named_uint("Vault Balance After  (vWORK)       ", vaultBalanceAfter);
        if (!reinvestTup) {
            assertGt(balanceInTupAfter, balanceInTupBefore);
        } else {
            assertGt(vaultBalanceAfter, vaultBalanceBefore);
        }
    }

    function _testInvestmentWithNoCapital(uint256 amount) private {
        workerVault.updateBatchSize(10);
        vm.deal(address(this), amount * 100);
        _createMinionsOnDemand(amount);
        blockNumber += 50_000;
        vm.roll(++blockNumber);
        uint256 balanceOnVaultBefore = workerVault.balanceOf(address(this));
        vm.deal(address(this), amount * 100);
        payable(address(workerVault)).call{ value: amount * 10 }("");
        workerVault.investWithNoCapital();
        vm.roll(++blockNumber);
        vm.deal(address(this), amount * 10);
        uint256 balanceOnVaultAfter = workerVault.balanceOf(address(this));
        emit log_named_uint("Balance on Vault Before (vWORK)    ", balanceOnVaultBefore);
        emit log_named_uint("Balance on Vault After  (vWORK)    ", balanceOnVaultAfter);
        assertEq(balanceOnVaultBefore, 0);
        assertGt(balanceOnVaultAfter, balanceOnVaultBefore);
    }

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
        address(workerVault.minionCoordinator()).call{ value: 10 ether }("");
        _depositTupAndLock(10 ether);
        emit log_named_uint("Active Minions ", MinionCoordinator(workerVault.minionCoordinator()).activeMinions());
        assertGt(MinionCoordinator(workerVault.minionCoordinator()).activeMinions(), 0);
    }

    function testTimeProduction() public {
        _createMinionsOnDemand(5 ether);
        uint256 balanceInTimeBefore = timeToken.balanceOf(address(workerVault));
        blockNumber += 500_000;
        vm.roll(++blockNumber);
        workerVault.callToProduction(address(this));
        uint256 balanceInTimeAfter = timeToken.balanceOf(address(workerVault));
        emit log_named_uint("Balance in TIME after production ", balanceInTimeAfter);
        assertGt(balanceInTimeAfter, balanceInTimeBefore);
    }

    function testTupMintAsThirdParty() public {
        _testMintTupAsThirdParty(1 ether);
    }

    function testFuzzTupMintAsThirdParty(uint256 amount) public {
        vm.assume(amount >= 0.01 ether && amount < 4 ether);
        _testMintTupAsThirdParty(amount);
    }

    function testTupMintAsDepositantNoReinvestment() public {
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

    function testFuzzInvestmentWithNoCapital(uint256 amount) public {
        vm.assume(amount >= 0.01 ether && amount < 4 ether);
        _testInvestmentWithNoCapital(amount);
    }
}
