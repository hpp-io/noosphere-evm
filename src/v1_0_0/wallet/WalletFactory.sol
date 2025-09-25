// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Routable} from "../utility/Routable.sol";
import {Wallet} from "./Wallet.sol";

/// @title WalletFactory
/// @notice Minimal factory for deploying `Wallet` contracts and proving provenance of wallets created by this factory.
/// @dev The factory is routable (holds a Router reference via `Routable`). Keep the storage layout stable if this
///      contract is used behind a proxy. Creation is intentionally simple: deploy a Wallet, register it, and emit an event.
contract WalletFactory is Routable {
    /*//////////////////////////////////////////////////////////////
                                  STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Tracks whether an address was deployed by this factory.
    /// @dev `true` means the factory created and registered this Wallet address.
    mapping(address => bool) private createdWallets;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new Wallet contract is deployed by this factory.
    /// @param operator The account that called `createWallet`.
    /// @param owner The initial owner/client that was set on the deployed Wallet.
    /// @param walletAddress The address of the deployed Wallet contract.
    event WalletCreated(address indexed operator, address indexed owner, address walletAddress);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct a WalletFactory bound to a Router.
    /// @param router Address of the Router contract used by created Wallets to resolve protocol services.
    constructor(address router) Routable(router) {}

    /*//////////////////////////////////////////////////////////////
                               PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new Wallet instance and register it as factory-created.
    /// @dev The Wallet constructor receives the Router address resolved via `Routable`.
    ///      The factory records the created wallet address in `createdWallets` for later verification.
    /// @param initialOwner Address that will be set as the initial owner/client of the new Wallet.
    /// @return walletAddr Address of the newly deployed Wallet contract.
    function createWallet(address initialOwner) external returns (address walletAddr) {
        require(initialOwner != address(0), "WalletFactory: zero owner");

        // Deploy wallet with the Router address known to this factory (Routable provides `_getRouter()`).
        Wallet deployed = new Wallet(address(_getRouter()), initialOwner);
        walletAddr = address(deployed);

        // Register the deployed wallet for provenance checks.
        createdWallets[walletAddr] = true;

        emit WalletCreated(msg.sender, initialOwner, walletAddr);
    }

    /// @notice Check whether a given address was created by this factory.
    /// @param walletAddr Candidate wallet address to validate.
    /// @return isCreated True if `walletAddr` was deployed and registered by this factory; otherwise false.
    function isValidWallet(address walletAddr) external view returns (bool isCreated) {
        return createdWallets[walletAddr];
    }

    /*//////////////////////////////////////////////////////////////
                            TYPE & VERSION
    //////////////////////////////////////////////////////////////*/
    function typeAndVersion() external pure override returns (string memory) {
        return "WalletFactory 1.0.0";
    }
}
