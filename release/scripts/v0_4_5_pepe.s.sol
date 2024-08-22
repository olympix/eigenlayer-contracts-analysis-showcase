// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.12;

import "@compound/contracts/Timelock.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import "../../utils/EncodeSafeTransactionMainnet.sol";
import "../../utils/Multisend.sol";
import "../../utils/ProxyInterfaces.sol";

contract v0_4_5_pepe is EncodeSafeTransactionMainnet, Script {

    function deploy() public {
        // Deploy EigenPod
        EigenPod newEigenPodImpl = new EigenPod(
            cfg.ETHPOSDepositAddress,
            cfg.eigenPodManager.proxy,
            cfg.EIGENPOD_GENESIS_TIME
        );

        // Deploy EigenPodManager
        EigenPodManager newEigenPodManagerImpl = new EigenPodManager(
            cfg.ETHPOSDepositAddress,
            cfg.eigenPodBeacon.proxy,
            cfg.strategyManager.proxy,
            cfg.slasher.proxy,
            cfg.delegationManager.proxy
        );

        // Updates `config/$network.json` with a "pendingImpl" for both of these contracts
        cfg.eigenPodBeacon.setPending(address(newEigenPodImpl));
        cfg.eigenPodManager.setPending(address(newEigenPodManagerImpl));
    }

    function test_Deploy() public {
        deploy();

        // Check constants/immutables set on deployment
        require(EigenPod(cfg.eigenPodBeacon.pendingImpl).activeValidatorCount() == 0);
    }

    // Mock out the upgrade flow as if you were pranking the executor multisig
    //
    // Depending on the network you're using, this will resolve to:
    // - (local) pranking the executor multisig and running the calls
    // - (preprod) multicall via the gigawhale private key
    // - (holesky) multicall via the community multisig
    // - (mainnet) queue + execute via ops and timelock
    function execute() public {
        executorMultisig.startBroadcast()                              // start building txn
            .upgrade(eigenPodBeacon, cfg.eigenPodBeacon.pendingImpl)   // create call to BeaconProxy
            .upgrade(eigenPodManager, cfg.eigenPodManager.pendingImpl) // create call to ProxyAdmin
            .stopBroadcast();                                          // finish txn as multicall
    }

    function test_Execute() public {
        // do some initial checks here
        vm.expectRevert();
        IEigenPod(cfg.eigenPodBeacon.impl).activeValidatorCount();

        // run the upgrade
        execute();

        // do some final checks here
        require(IEigenPod(cfg.eigenPodBeacon.impl).activeValidatorCount() == 0);
    }
}