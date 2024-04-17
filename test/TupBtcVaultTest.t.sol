// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { console } from "forge-std/console.sol";
import { stdStorage, StdStorage, StdCheats, Test } from "forge-std/Test.sol";
import { TupBtcVault, IERC20, ITimeIsUp, ITimeToken } from "../src/TupBtcVault.sol";
import { OracleMock } from "../src/mock/OracleMock.sol";

import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { FixedPoint96 } from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";

import { ISponsor } from "../src/ISponsor.sol";
import { IUniswapV2Router02 } from "../src/IUniswapV2Router02.sol";
import { IWETH } from "../src/IWETH.sol";

// forge test --match-contract TupBtcVaultTest --rpc-url "polygon" --block-gas-limit 5000000000000000000 -vvv
contract TupBtcVaultTest is Test {
    using Math for uint256;

    uint256 public constant CURRENT_BLOCK_NUMBER = 55822515;

    uint256 public blockNumber = 55822515;
    uint256 public counterForFuzzMultipleDeposit;
    uint256 public counterForFuzzMultipleWithdrawals;
    // POLYGON MAINNET
    // address public constant EMPLOYER_ADDRESS = 0x496ebDb161a87FeDa58f7EFFf4b2B94E10a1b655;
    // address public constant ORACLE_ADDRESS = 0xc907E116054Ad103354f2D350FD2514433D57F6f;
    // address public constant TIME_EXCHANGE_ADDRESS = 0xb46F8A90492D0d03b8c3ab112179c56F89A6f3e0;
    address public constant TIME_TOKEN_ADDRESS = 0x1666Cf136d89Ba9071C476eaF23035Bccd7f3A36;
    address public constant TIME_IS_UP_ADDRESS = 0x57685Ddbc1498f7873963CEE5C186C7D95D91688;
    address public constant ROUTER_V2_ADDRESS = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address public constant ROUTER_V3_ADDRESS = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant SPONSOR_ADDRESS = 0x4925784808cdcb23DA64BCbb7B5827ebc344B168;
    address public constant WBTC_ADDRESS = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address public wETH;

    uint24[] private UNISWAP_FEES = [500, 3_000, 10_000, 100];

    OracleMock oracleMock;
    ITimeToken timeToken;
    ITimeIsUp tup;
    TupBtcVault tupBtcVault;
    IUniswapV2Router02 routerV2;
    ISwapRouter routerV3;
    ISponsor sponsor;
    IERC20 wBTC;

    receive() external payable { }

    fallback() external payable { }

    function setUp() public {
        vm.roll(CURRENT_BLOCK_NUMBER);
        vm.label(TIME_TOKEN_ADDRESS, "TIME");
        vm.label(TIME_IS_UP_ADDRESS, "TUP");
        vm.label(SPONSOR_ADDRESS, "Sponsor");
        vm.label(WBTC_ADDRESS, "wBTC");
        vm.label(ROUTER_V2_ADDRESS, "RouterV2");
        vm.label(ROUTER_V3_ADDRESS, "RouterV3");

        oracleMock = new OracleMock();
        tup = ITimeIsUp(TIME_IS_UP_ADDRESS);

        tupBtcVault = new TupBtcVault(
            TIME_IS_UP_ADDRESS, WBTC_ADDRESS, TIME_TOKEN_ADDRESS, SPONSOR_ADDRESS, ROUTER_V2_ADDRESS, ROUTER_V3_ADDRESS, address(this)
        );
        timeToken = ITimeToken(payable(TIME_TOKEN_ADDRESS));
        tupBtcVault.enableMining{ value: timeToken.fee() }();

        routerV2 = IUniswapV2Router02(payable(ROUTER_V2_ADDRESS));
        routerV3 = ISwapRouter(payable(ROUTER_V3_ADDRESS));
        sponsor = ISponsor(payable(SPONSOR_ADDRESS));
        wBTC = IERC20(WBTC_ADDRESS);
        wETH = routerV2.WETH();
    }

    /*
        [X] Depósito de TUP, obtenção de shares e token wBTC convertido na vault
        [X] Múltiplos depositos de diferentes depositantes
        [X] Retirada de TUP, converter wBTC de volta p/ TUP e 'zerar' shares
        [X] Múltiplas retiradas de diferentes depositantes
        [X] Verificar rendimentos da vault após valorização do BTC (comprar BTC antecipadamente)
        [ ] Verificar rendimentos da vault c/ dividendos de TUP
        [ ] Verificar update dos contratos utilizados pela vault
    */

    function _exchangeFromEthToBtc(uint256 amount) private returns (bool success) {
        address[] memory path_ETH_BTC = new address[](2);
        path_ETH_BTC[0] = wETH;
        path_ETH_BTC[1] = WBTC_ADDRESS;
        vm.deal(address(this), amount * 100);
        if (IERC20(wETH).balanceOf(address(this)) > 0) {
            IWETH(wETH).withdraw(IERC20(wETH).balanceOf(address(this)));
        }
        if (amount > 0) {
            for (uint256 i = 0; i < UNISWAP_FEES.length; i++) {
                bytes memory path = abi.encodePacked(wETH, UNISWAP_FEES[i], WBTC_ADDRESS);
                ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams(path, address(this), block.timestamp + 300, amount, 0);
                vm.roll(++blockNumber);
                try routerV3.exactInput{ value: amount }(params) {
                    success = true;
                    break;
                } catch {
                    continue;
                }
            }
        }
    }

    function _firstMintAndBurn(address depositant) private {
        vm.startPrank(depositant);
        vm.deal(depositant, 30 ether);
        vm.roll(++blockNumber);
        tup.buy{ value: 10 ether }();
        tup.approve(address(tupBtcVault), tup.balanceOf(depositant));
        vm.roll(++blockNumber);
        tupBtcVault.mint(tup.balanceOf(depositant).mulDiv(10, 100), depositant);
        vm.roll(++blockNumber);
        tupBtcVault.transfer(address(0xdead), tupBtcVault.balanceOf(depositant));
        vm.stopPrank();
    }

    function _testTupDeposit(uint256 amount, address depositant) private {
        vm.startPrank(depositant);
        vm.assume(amount > 0.01 ether && amount <= 100 ether);
        vm.deal(depositant, amount * 100);
        vm.roll(++blockNumber);
        tup.buy{ value: amount }();
        uint256 amountToDeposit = tup.balanceOf(depositant);
        vm.roll(++blockNumber);
        tup.approve(address(tupBtcVault), amountToDeposit);
        uint256 tupBalanceInVaultBefore = tup.balanceOf(address(tupBtcVault));
        uint256 totalAssetsBefore = tupBtcVault.totalAssets();
        uint256 assetValueBefore = tupBtcVault.convertToAssets(tupBtcVault.balanceOf(depositant));
        uint256 shareBalanceBefore = tupBtcVault.balanceOf(depositant);
        uint256 balanceInBtcBefore = IERC20(WBTC_ADDRESS).balanceOf(address(tupBtcVault));
        vm.roll(++blockNumber);
        tupBtcVault.deposit(amountToDeposit, depositant);
        uint256 tupBalanceInVaultAfter = tup.balanceOf(address(tupBtcVault));
        uint256 totalAssetsAfter = tupBtcVault.totalAssets();
        uint256 assetValueAfter = tupBtcVault.convertToAssets(tupBtcVault.balanceOf(depositant));
        uint256 shareBalanceAfter = tupBtcVault.balanceOf(depositant);
        uint256 balanceInBtcAfter = IERC20(WBTC_ADDRESS).balanceOf(address(tupBtcVault));
        uint256 amountToCheck = tup.balanceOf(depositant);
        emit log_named_uint("TUP Balance from Depositant Before     ", amountToDeposit);
        emit log_named_uint("TUP Balance from Depositant After      ", amountToCheck);
        emit log_named_uint("vTUP Balance from Depositant Before    ", shareBalanceBefore);
        emit log_named_uint("vTUP Balance from Depositant After     ", shareBalanceAfter);
        emit log_named_uint("TUP Amount from vTUP Before            ", assetValueBefore);
        emit log_named_uint("TUP Amount from vTUP After             ", assetValueAfter);
        emit log_named_uint("totalAssets() Before                   ", totalAssetsBefore);
        emit log_named_uint("totalAssets() After                    ", totalAssetsAfter);
        emit log_named_uint("TUP in Vault Before                    ", tupBalanceInVaultBefore);
        emit log_named_uint("TUP in Vault After                     ", tupBalanceInVaultAfter);
        emit log_named_uint("Balance in wBTC Before                 ", balanceInBtcBefore);
        emit log_named_uint("Balance in wBTC After                  ", balanceInBtcAfter);
        emit log_named_address("END OF DEPOSIT -- ", depositant);
        emit log("------------------------------------------------------------------------------------------------");
        // assertGt(tupBalanceInVaultAfter, tupBalanceInVaultBefore);
        assertGt(totalAssetsAfter, totalAssetsBefore);
        assertGt(assetValueAfter, assetValueBefore);
        assertGt(shareBalanceAfter, shareBalanceBefore);
        assertGt(balanceInBtcAfter, balanceInBtcBefore);
        vm.stopPrank();
    }

    function _testTupWithdraw(uint256 percentage, address depositant) private {
        vm.startPrank(depositant);
        uint256 amount;
        vm.assume(percentage > 1 && percentage <= 100);
        if (percentage != 100) {
            amount = tupBtcVault.balanceOf(depositant).mulDiv(percentage, 100);
        } else {
            amount = tupBtcVault.balanceOf(depositant);
        }
        uint256 tupAmountBefore = tup.balanceOf(depositant);
        uint256 shareBalanceBefore = tupBtcVault.balanceOf(depositant);
        uint256 tupBalanceInVaultBefore = tup.balanceOf(address(tupBtcVault));
        uint256 balanceInBtcBefore = IERC20(WBTC_ADDRESS).balanceOf(address(tupBtcVault));
        uint256 tupAmountEstimated = tupBtcVault.totalAssets();
        uint256 estimatedTupBefore = tupBtcVault.previewRedeem(amount);
        vm.roll(++blockNumber);
        tupBtcVault.redeem(amount, depositant, depositant);
        uint256 shareBalanceAfter = tupBtcVault.balanceOf(depositant);
        uint256 tupBalanceInVaultAfter = tup.balanceOf(address(tupBtcVault));
        uint256 balanceInBtcAfter = IERC20(WBTC_ADDRESS).balanceOf(address(tupBtcVault));
        uint256 tupAmountAfter = tup.balanceOf(depositant);
        uint256 estimatedTupAfter = tupBtcVault.previewRedeem(shareBalanceAfter);
        emit log_named_uint("TUP Balance from Withdrawer Before     ", tupAmountBefore);
        emit log_named_uint("TUP Balance from Withdrawer After      ", tupAmountAfter);
        emit log_named_uint("vTUP Balance from Withdrawer Before    ", shareBalanceBefore);
        emit log_named_uint("vTUP Balance from Withdrawer After     ", shareBalanceAfter);
        emit log_named_uint("vTUP Balance Burned                    ", amount);
        emit log_named_uint("TUP Amount from vTUP Balance Before    ", estimatedTupBefore);
        emit log_named_uint("TUP Amount from vTUP Balance After     ", estimatedTupAfter);
        emit log_named_uint("totalAssets() Before                   ", tupAmountEstimated);
        emit log_named_uint("totalAssets() After                    ", tupBtcVault.totalAssets());
        emit log_named_uint("TUP Amount in Vault Before             ", tupBalanceInVaultBefore);
        emit log_named_uint("TUP Amount in Vault After              ", tupBalanceInVaultAfter);
        emit log_named_uint("Balance in wBTC Before                 ", balanceInBtcBefore);
        emit log_named_uint("Balance in wBTC After                  ", balanceInBtcAfter);
        emit log_named_address("END OF WITHDRAW -- ", depositant);
        emit log("------------------------------------------------------------------------------------------------");
        assertGt(shareBalanceBefore, shareBalanceAfter);
        assertGt(tupBalanceInVaultBefore, tupBalanceInVaultAfter);
        assertGt(balanceInBtcBefore, balanceInBtcAfter);
        vm.stopPrank();
    }

    function testTupDeposit() public {
        _firstMintAndBurn(address(this));
        _testTupDeposit(5 ether, address(this));
    }

    function testFuzzTupDeposit(uint256 amount) public {
        _firstMintAndBurn(address(this));
        _testTupDeposit(amount, address(this));
    }

    function testTupWithdraw() public {
        _firstMintAndBurn(address(this));
        _testTupDeposit(5 ether, address(this));
        _testTupWithdraw(100, address(this));
    }

    function testFuzzTupWithdraw(uint256 percentage) public {
        _firstMintAndBurn(address(this));
        _testTupDeposit(5 ether, address(this));
        _testTupWithdraw(percentage, address(this));
    }

    function testMultipleDeposits() public {
        uint160 amountOfWallets = 5;
        _firstMintAndBurn(address(this));
        for (uint160 i = 0; i < amountOfWallets; i++) {
            _testTupDeposit(5 ether, address(uint160(20 + i)));
        }
    }

    function testFuzzMultipleDeposits(uint16 amountOfWallets, uint16 amount) public {
        vm.assume(amountOfWallets > 1 && amountOfWallets < 30);
        vm.assume(amount > 1 && amount < 19);
        if (counterForFuzzMultipleDeposit == 0) {
            emit log_named_uint("Running first mint     ", counterForFuzzMultipleDeposit++);
            _firstMintAndBurn(address(this));
        }
        for (uint16 i = 0; i < amountOfWallets; i++) {
            _testTupDeposit(uint256(amount * 1 ether), address(uint160(20 + i)));
        }
    }

    function testMultipleWithdrawals() public {
        uint160 amountOfWallets = 5;
        _firstMintAndBurn(address(this));
        for (uint160 i = 0; i < amountOfWallets; i++) {
            _testTupDeposit(5 ether, address(uint160(20 + i)));
            _testTupWithdraw(100, address(uint160(20 + i)));
        }
    }

    function testFuzzMultipleWithdrawals(uint16 amountOfWallets, uint16 amount) public {
        vm.assume(amountOfWallets > 1 && amountOfWallets < 30);
        vm.assume(amount > 1 && amount < 19);
        if (counterForFuzzMultipleWithdrawals == 0) {
            emit log_named_uint("Running first mint     ", counterForFuzzMultipleWithdrawals++);
            _firstMintAndBurn(address(this));
        }
        for (uint16 i = 0; i < amountOfWallets; i++) {
            _testTupDeposit(uint256(amount * 1 ether), address(uint160(20 + i)));
            _testTupWithdraw(100, address(uint160(20 + i)));
        }
    }

    // TODO: verificar...
    function testProfit() public {
        _firstMintAndBurn(address(this));
        // uint160 amountOfWallets = 5;
        // for (uint160 i = 0; i < amountOfWallets; i++) {
        //     _testTupDeposit(5 ether, address(uint160(20+i)));
        // }
        _testTupDeposit(5 ether, address(this));
        uint256 estimatedTupAmount = tupBtcVault.convertToAssets(tupBtcVault.balanceOf(address(this)));
        _exchangeFromEthToBtc(100_000 ether);
        vm.roll(++blockNumber);
        _testTupWithdraw(100, address(this));
        uint256 realTupAfter = tup.balanceOf(address(this));
        emit log_named_uint("Estimated TUP from Vault               ", estimatedTupAmount);
        emit log_named_uint("Real TUP after Withdraw with Profit    ", realTupAfter);
        assertGt(realTupAfter, estimatedTupAmount);
    }
}
