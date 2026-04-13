// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GHSFIAT} from "../src/tokens/GHSFIAT.sol";
import {MobileNumberNFT} from "../src/identity/MobileNumberNFT.sol";
import {Withdrawals} from "../src/payments/Withdrawals.sol";
import {FiatsendGateway} from "../src/payments/FiatsendGateway.sol";
import {PaymentRouter} from "../src/payments/PaymentRouter.sol";
import {PayoutEscrow} from "../src/payments/PayoutEscrow.sol";
import {P2PExchange} from "../src/payments/P2PExchange.sol";
import {LiquidityPool} from "../src/liquidity/LiquidityPool.sol";
import {VaultController} from "../src/liquidity/VaultController.sol";

/// @title DeployTestnet
/// @notice Testnet deployment with relaxed configs and test token minting.
///         Uses the deployer address as treasury and dispute resolver for convenience.
contract DeployTestnet is Script {
    // -------------------------------------------------------------------------
    // Testnet configuration
    // -------------------------------------------------------------------------

    uint256 internal constant PROTOCOL_FEE_RATE = 100; // 1% — slightly higher for testnet visibility
    uint256 internal constant LP_MIN_DEPOSIT = 1 * 10 ** 18; // 1 token minimum
    uint256 internal constant LP_LOCK_PERIOD = 1 hours; // short lock for testing
    uint256 internal constant VAULT_ANNUAL_YIELD = 1000; // 10% APY for testnet
    uint256 internal constant VAULT_MIN_DEPOSIT = 1 * 10 ** 18;
    uint256 internal constant PAYOUT_EXPIRY_DURATION = 1 days; // short for testnet

    uint256 internal constant TESTNET_MINT_AMOUNT = 100_000 * 10 ** 18; // 100k tokens per test user

    string internal constant NFT_BASE_URI = "https://testnet-api.fiatsend.com/identity/";

    // -------------------------------------------------------------------------
    // Run
    // -------------------------------------------------------------------------

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // On testnet, deployer IS the treasury and dispute resolver
        address treasury = deployer;
        address disputeResolver = deployer;

        vm.startBroadcast(deployerKey);

        // 1. Deploy GHSFIAT
        console.log("[Testnet] Deploying GHSFIAT...");
        GHSFIAT ghsFiat = new GHSFIAT(deployer);

        // 2. Deploy MobileNumberNFT
        console.log("[Testnet] Deploying MobileNumberNFT...");
        MobileNumberNFT mobileNFT = new MobileNumberNFT(NFT_BASE_URI);

        // 3. Deploy Withdrawals
        console.log("[Testnet] Deploying Withdrawals...");
        Withdrawals withdrawals = new Withdrawals();

        // 4. Deploy FiatsendGateway via UUPS proxy
        console.log("[Testnet] Deploying FiatsendGateway (UUPS proxy)...");
        FiatsendGateway gatewayImpl = new FiatsendGateway();
        bytes memory gatewayInit = abi.encodeWithSelector(
            FiatsendGateway.initialize.selector, address(ghsFiat), address(mobileNFT), treasury, PROTOCOL_FEE_RATE
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayInit);
        FiatsendGateway gateway = FiatsendGateway(address(gatewayProxy));

        // 5. Deploy PayoutEscrow — core B2B inbound payout contract
        console.log("[Testnet] Deploying PayoutEscrow...");
        PayoutEscrow payoutEscrow = new PayoutEscrow(address(mobileNFT), address(gateway), PAYOUT_EXPIRY_DURATION);

        // 6. Deploy P2PExchange
        console.log("[Testnet] Deploying P2PExchange...");
        P2PExchange p2pExchange = new P2PExchange(disputeResolver);

        // 7. Deploy PaymentRouter
        console.log("[Testnet] Deploying PaymentRouter...");
        PaymentRouter paymentRouter = new PaymentRouter(address(mobileNFT), treasury);

        // 8. Deploy LiquidityPool
        console.log("[Testnet] Deploying LiquidityPool...");
        LiquidityPool liquidityPool =
            new LiquidityPool(address(ghsFiat), address(gateway), LP_MIN_DEPOSIT, LP_LOCK_PERIOD);

        // 9. Deploy VaultController
        console.log("[Testnet] Deploying VaultController...");
        VaultController vaultController = new VaultController(address(ghsFiat), VAULT_ANNUAL_YIELD, VAULT_MIN_DEPOSIT);

        // -------------------------------------------------------------------------
        // Wire contracts
        // -------------------------------------------------------------------------

        withdrawals.setGateway(address(gateway));
        gateway.setWithdrawalsContract(address(withdrawals));
        ghsFiat.grantRole(ghsFiat.MINTER_ROLE(), address(gateway));
        gateway.addSupportedToken(address(ghsFiat));

        // Authorize PayoutEscrow to call offrampFor
        gateway.setAuthorizedContract(address(payoutEscrow), true);

        // Wire PayoutEscrow into PaymentRouter
        paymentRouter.setPayoutEscrow(address(payoutEscrow));

        // Testnet: relaxed limits
        gateway.setDailyLimit(1_000_000 * 10 ** 18);
        gateway.setMinWithdrawAmount(1 * 10 ** 18);

        // Testnet: authorize deployer as both onramper and authorized B2B sender
        gateway.setAuthorizedOnramper(deployer, true);
        payoutEscrow.setAuthorizedSender(deployer, true);

        // -------------------------------------------------------------------------
        // Testnet: Mint test tokens and seed vault
        // -------------------------------------------------------------------------

        ghsFiat.grantRole(ghsFiat.MINTER_ROLE(), deployer);
        ghsFiat.mint(deployer, TESTNET_MINT_AMOUNT);
        console.log("[Testnet] Minted", TESTNET_MINT_AMOUNT / 10 ** 18, "GHSFIAT to deployer");

        // Seed vault with yield reserve
        require(
            ghsFiat.transfer(address(vaultController), TESTNET_MINT_AMOUNT / 10),
            "GHSFIAT transfer to vault failed"
        );
        console.log("[Testnet] Funded vault with", (TESTNET_MINT_AMOUNT / 10) / 10 ** 18, "GHSFIAT for yield");

        vm.stopBroadcast();

        // -------------------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------------------

        console.log("");
        console.log("=== TESTNET DEPLOYMENT COMPLETE ===");
        console.log("ChainId:          ", block.chainid);
        console.log("Deployer/Treasury:", deployer);
        console.log("");
        console.log("--- Contract Addresses ---");
        console.log("GHSFIAT:          ", address(ghsFiat));
        console.log("MobileNumberNFT:  ", address(mobileNFT));
        console.log("Withdrawals:      ", address(withdrawals));
        console.log("Gateway (impl):   ", address(gatewayImpl));
        console.log("Gateway (proxy):  ", address(gateway));
        console.log("PayoutEscrow:     ", address(payoutEscrow));
        console.log("P2PExchange:      ", address(p2pExchange));
        console.log("PaymentRouter:    ", address(paymentRouter));
        console.log("LiquidityPool:    ", address(liquidityPool));
        console.log("VaultController:  ", address(vaultController));
        console.log("");
        console.log("--- Testnet Config ---");
        console.log("Protocol fee:     ", PROTOCOL_FEE_RATE, "bps");
        console.log("Vault APY:        ", VAULT_ANNUAL_YIELD, "bps");
        console.log("LP lock period:   ", LP_LOCK_PERIOD / 3600, "hours");
        console.log("Payout expiry:    ", PAYOUT_EXPIRY_DURATION / 3600, "hours");
    }
}
