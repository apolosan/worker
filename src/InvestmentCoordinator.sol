// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IWorker } from "./IWorker.sol";

/// @title InvestmentCoordinator contract
/// @author Einar Cesar - TIME Token Finance - https://timetoken.finance
/// @notice Coordinates the allocation of resources coming from the Worker vault and returns the profit in terms of TUP and TIME tokens
/// @dev It is attached and managed by the WorkerVault
contract InvestmentCoordinator is Ownable {
    using Math for uint256;

    error AddressNotAllowed(address sender);

    IWorker public worker;

    ERC4626[] public vaults;

    mapping(address => uint256) private _amountOnVault;
    mapping(address => uint256) private _assetCount;
    mapping(address => uint256) private _assetAmountPerVault;

    /// @notice Instantiates the contract
    /// @dev It is automatically instantiated by the WorkerVault contract
    /// @param _worker The address of the WorkerVault contract main instance
    /// @param _owner The address of the admin
    constructor(address _worker, address _owner) Ownable(_owner) {
        worker = IWorker(payable(_worker));
    }

    /// @notice Modifier used to allow function calling only by IWorker contract
    modifier onlyWorker() {
        _checkWorker();
        _;
    }

    /// @notice Verifies if the sender of a call is the WorkerVault contract
    function _checkWorker() private view {
        if (_msgSender() != address(worker)) {
            revert AddressNotAllowed(_msgSender());
        }
    }

    /// @notice Withdraw all the funds from an informed vault registered
    /// @dev It redeems all shares from the vault passed as parameter
    /// @param vault The instance of the vault contract
    /// @param receiver The address of the receiver of funds
    function _withdrawAllFromVault(ERC4626 vault, address receiver) private {
        try vault.redeem(vault.balanceOf(address(this)), receiver, address(this)) {
            _amountOnVault[address(vault)] = 0;
        } catch { }
    }

    /// @notice Add a new vault onto the InvestmentCoordinator
    /// @dev It pushes the new vault into the vault stack
    /// @param newVault The address of the new vault contract
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

    /// @notice Verifies if vaults have profit and withdraw assets to the Worker vault
    /// @dev It iterates over the vaults stack, check if each has profit, and then withdraw to the WorkerVault address
    function checkProfitAndWithdraw() external {
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            uint256 updatedAmount = vaults[i].previewRedeem(vaults[i].balanceOf(address(this)));
            if (_amountOnVault[address(vaults[i])] < updatedAmount) {
                vaults[i].withdraw(updatedAmount - _amountOnVault[address(vaults[i])], address(worker), address(this));
            }
        }
    }

    /// @notice Sometimes, the Investor coordinator has most than one vault which operates with the same asset. In this case, this function distributes the asset equally among these vaults
    /// @dev Check which vaults operates in the asset informed and deposit what it has in balance
    /// @param asset The address of asset informed to be deposited
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

    /// @notice Deposit all assets in all registered vaults
    /// @dev It iterates over all vaults and all assets in order to deposit everything it has as balance
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

    /// @notice Informs the number of vaults registered in the contract
    /// @dev It just returns the length/size of the vaults stack
    function numberOfVaults() public view returns (uint256) {
        return vaults.length;
    }

    /// @notice Query the total amount invested for a given asset
    /// @dev It just query for the amount registered for the informed asset address
    /// @param asset The address of the asset
    /// @return totalAmount The total amount returned after query
    function queryTotalInvestedAmountForAsset(address asset) external view onlyWorker returns (uint256 totalAmount) {
        for (uint256 i = 0; i < numberOfVaults(); i++) {
            if (vaults[i].asset() == asset) {
                totalAmount += _amountOnVault[address(vaults[i])];
            }
        }
    }

    /// @notice Removes an ERC-4626 vault from the Investment coordinator contract
    /// @dev It pushes part of the stack away when it founds the correct index of the contract
    /// @param vaultToRemove The address of the vault which will be removed
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
