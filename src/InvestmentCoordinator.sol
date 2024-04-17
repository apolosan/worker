// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IWorker } from "./IWorker.sol";

contract InvestmentCoordinator is Ownable {
    using Math for uint256;

    error AddressNotAllowed(address sender);

    IWorker public worker;

    ERC4626[] public vaults;

    mapping(address => uint256) private _amountOnVault;
    mapping(address => uint256) private _assetCount;
    mapping(address => uint256) private _assetAmountPerVault;

    constructor(address _worker, address _owner) Ownable(_owner) {
        worker = IWorker(payable(_worker));
    }

    modifier onlyWorker() {
        _checkWorker();
        _;
    }

    function _checkWorker() private view {
        if (_msgSender() != address(worker)) {
            revert AddressNotAllowed(_msgSender());
        }
    }

    function _withdrawAllFromVault(ERC4626 vault, address receiver) private {
        try vault.redeem(vault.balanceOf(address(this)), receiver, address(this)) {
            _amountOnVault[address(vault)] = 0;
        } catch { }
    }

    function addVault(address newVault) external onlyOwner {
        bool found;
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            if (newVault == address(vaults[i])) {
                found = true;
                break;
            }
        }
        if (!found) {
            vaults.push(ERC4626(newVault));
        }
    }

    function checkProfitAndWithdraw() external {
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            uint256 updatedAmount = vaults[i].previewRedeem(vaults[i].balanceOf(address(this)));
            if (_amountOnVault[address(vaults[i])] < updatedAmount) {
                vaults[i].withdraw(updatedAmount - _amountOnVault[address(vaults[i])], address(worker), address(this));
            }
        }
    }

    function depositAssetOnVault(address asset) public onlyWorker {
        uint256 numberOfVaultsFound;
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            if (vaults[i].asset() == asset) {
                numberOfVaultsFound++;
            }
        }
        if (numberOfVaultsFound > 0) {
            IERC20 token = IERC20(asset);
            uint256 shares = token.balanceOf(address(this)) / numberOfVaultsFound;
            for (uint256 i = 0; i < numberOfVaults(); i++) {
                if (vaults[i].asset() == asset) {
                    if (token.allowance(address(this), address(vaults[i])) < shares) {
                        token.approve(address(vaults[i]), shares);
                    }
                    vaults[i].deposit(shares, address(this));
                    _amountOnVault[address(vaults[i])] += shares;
                }
            }
        }
    }

    function depositOnAllVaults() public {
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            _assetCount[vaults[i].asset()]++;
        }
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            if (_assetAmountPerVault[vaults[i].asset()] == 0 && _assetCount[vaults[i].asset()] > 0) {
                uint256 tokenBalance = IERC20(vaults[i].asset()).balanceOf(address(this));
                if (tokenBalance > 0) {
                    _assetAmountPerVault[vaults[i].asset()] = tokenBalance / _assetCount[vaults[i].asset()];
                }
            }
        }
        bool[] memory isDeposited = new bool[](numberOfVaults());
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            if (_assetAmountPerVault[vaults[i].asset()] > 0) {
                if (IERC20(vaults[i].asset()).allowance(address(this), address(vaults[i])) < _assetAmountPerVault[vaults[i].asset()]) {
                    IERC20(vaults[i].asset()).approve(address(vaults[i]), _assetAmountPerVault[vaults[i].asset()]);
                }
                try vaults[i].deposit(_assetAmountPerVault[vaults[i].asset()], address(this)) {
                    _amountOnVault[address(vaults[i])] += _assetAmountPerVault[vaults[i].asset()];
                    isDeposited[i] = true;
                } catch { }
            }
        }
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            _assetCount[vaults[i].asset()] = 0;
            if (_assetAmountPerVault[vaults[i].asset()] > 0 && isDeposited[i]) {
                _assetAmountPerVault[vaults[i].asset()] = 0;
            }
        }
    }

    function numberOfVaults() public view returns (uint256) {
        return vaults.length;
    }

    function queryTotalInvestedAmountForAsset(address asset) external view onlyWorker returns (uint256 totalAmount) {
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            if (vaults[i].asset() == asset) {
                totalAmount += _amountOnVault[address(vaults[i])];
            }
        }
    }

    function removeVault(address vaultToRemove) external onlyOwner {
        bool found;
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            if (vaultToRemove == address(vaults[i])) {
                for (uint256 j = i; j < numberOfVaults() - 1; j++) {
                    vaults[j] = vaults[j + 1];
                }
                _withdrawAllFromVault(vaults[i], address(this));
                found = true;
                break;
            }
        }
        if (found) {
            vaults.pop();
        }
    }
}
