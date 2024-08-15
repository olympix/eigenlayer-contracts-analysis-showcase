pragma solidity ^0.8.12;

import "src/*";

contract preprod_jjfgg2_enigma is DeploymentUtils {

    string constant STRATEGY_FACTORY = "strategyFactory";

    // Deploying a new contract and adding it to config
    function deploy() external {
        // Deploy proxy and impl for StrategyFactory
        StrategyFactory factoryImpl = new StrategyFactory(cfg.strategyManager.proxy);
        TransparentUpgradeableProxy factoryProxy = new TransparentUpgradeableProxy(
            address(factoryImpl),
            cfg.proxyAdmin,
            abi.encodeWithSelector(
                StrategyFactory.initialize.selector,
                cfg.
            );
        );



        cfg.newImpl(STRATEGY_FACTORY);
        cfg.setImpl(STRATEGY_FACTORY, address(factoryImpl));
        cfg.setProxy(STRATEGY_FACTORY, address(factoryProxy));
        cfg.setConfig(STRATEGY_FACTORY)
            .value("initialOwner", cfg.executorMultisig)
            .value("pauserRegistry", )
        

        // Update preprod cfg
        cfg.setImpl(EIGENPOD, address(newPodImpl));
        cfg.setImpl(EIGENPODMANAGER, address(newPodManagerImpl));
    }

    function upgrade() external {
        sys.as()
        cfg.upgradeImpl(EIGENPOD);
    }
}