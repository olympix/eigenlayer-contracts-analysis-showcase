pragma solidity ^0.8.12;

import "src/*";

contract Mainnet_PEPE_0_4_2 is DeploymentUtils {

    function deploy() public virtual {
        // Deploy EigenPod
        eigenPodImplementation = new EigenPod(
            IETHPOSDeposit(ETHPOSDepositAddress),
            eigenPodManager,
            EIGENPOD_GENESIS_TIME
        );

        // Deploy EigenPodManager
        eigenPodManagerImplementation = new EigenPodManager(
            IETHPOSDeposit(ETHPOSDepositAddress),
            eigenPodBeacon,
            strategyManager,
            slasher,
            delegationManager
        );

        cfg.setDeploy(EIGENPOD, address(eigenPodImplementation));
        cfg.setDeploy(EIGENPOD_MANAGER, address(eigenPodManagerImplementation));
    }

    function queueUpgrade() public virtual {

    }

    function executeQueued() public virtual {
        
    }

    // Executor multisig calls proxyAdmin/beacon proxies and upgrades
    // (or calls contracts and sets values)
    function doUpgrade() public virtual {
        return executorMultisig.startBroadcast()
            .upgrade(eigenPodBeacon, newEigenPodImpl)
            .upgrade(eigenPodManager, newEigenPodManagerImpl)
            .stopBroadcast();
    }
}