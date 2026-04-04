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

/// @title DeployAll
/// @notice Deploys the complete Fiatsend B2B protocol in the correct order and wires all contracts.
///         Architecture: Business API → PayoutEscrow → Recipient claims → Hold / Yield / P2P / CashOut
contract DeployAll is Script {
    // -------------------------------------------------------------------------
    // Configuration — override via environment variables
    // -------------------------------------------------------------------------

    function _treasury() internal view returns (address) {
        address t = vm.envOr("TREASURY_ADDRESS", address(0));
        if (t == address(0)) revert("DeployAll: TREASURY_ADDRESS not set");
        return t;
    }

    function _disputeResolver() internal view returns (address) {
        address d = vm.envOr("DISPUTE_RESOLVER_ADDRESS", address(0));
        if (d == address(0)) revert("DeployAll: DISPUTE_RESOLVER_ADDRESS not set");
        return d;
    }

    uint256 internal constant PROTOCOL_FEE_RATE = 50; // 0.5% in basis points
    uint256 internal constant LP_MIN_DEPOSIT = 10 * 10 ** 18;
    uint256 internal constant LP_LOCK_PERIOD = 7 days;
    uint256 internal constant VAULT_ANNUAL_YIELD = 500; // 5% APY
    uint256 internal constant VAULT_MIN_DEPOSIT = 10 * 10 ** 18;
    uint256 internal constant PAYOUT_EXPIRY_DURATION = 30 days;

    string internal constant NFT_BASE_URI = "https://api.fiatsend.com/identity/";

    // -------------------------------------------------------------------------
    // Run
    // -------------------------------------------------------------------------

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = _treasury();
        address disputeResolver = _disputeResolver();

        vm.startBroadcast(deployerKey);

        // 1. Deploy GHSFIAT stablecoin
        console.log("Deploying GHSFIAT...");
        GHSFIAT ghsFiat = new GHSFIAT(deployer);
        console.log("  GHSFIAT:", address(ghsFiat));

        // 2. Deploy MobileNumberNFT (on-chain phone-number identity)
        console.log("Deploying MobileNumberNFT...");
        MobileNumberNFT mobileNFT = new MobileNumberNFT(NFT_BASE_URI);
        console.log("  MobileNumberNFT:", address(mobileNFT));

        // 3. Deploy Withdrawals
        console.log("Deploying Withdrawals...");
        Withdrawals withdrawals = new Withdrawals();
        console.log("  Withdrawals:", address(withdrawals));

        // 4. Deploy FiatsendGateway via UUPS proxy
        console.log("Deploying FiatsendGateway (UUPS proxy)...");
        FiatsendGateway gatewayImpl = new FiatsendGateway();
        bytes memory gatewayInit = abi.encodeWithSelector(
            FiatsendGateway.initialize.selector, address(ghsFiat), address(mobileNFT), treasury, PROTOCOL_FEE_RATE
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayInit);
        FiatsendGateway gateway = FiatsendGateway(address(gatewayProxy));
        console.log("  FiatsendGateway (impl):", address(gatewayImpl));
        console.log("  FiatsendGateway (proxy):", address(gateway));

        // 5. Deploy PayoutEscrow — core B2B inbound payout contract
        console.log("Deploying PayoutEscrow...");
        PayoutEscrow payoutEscrow = new PayoutEscrow(address(mobileNFT), address(gateway), PAYOUT_EXPIRY_DURATION);
        console.log("  PayoutEscrow:", address(payoutEscrow));

        // 6. Deploy P2PExchange
        console.log("Deploying P2PExchange...");
        P2PExchange p2pExchange = new P2PExchange(disputeResolver);
        console.log("  P2PExchange:", address(p2pExchange));

        // 7. Deploy PaymentRouter
        console.log("Deploying PaymentRouter...");
        PaymentRouter paymentRouter = new PaymentRouter(address(mobileNFT), treasury);
        console.log("  PaymentRouter:", address(paymentRouter));

        // 8. Deploy LiquidityPool
        console.log("Deploying LiquidityPool...");
        LiquidityPool liquidityPool =
            new LiquidityPool(address(ghsFiat), address(gateway), LP_MIN_DEPOSIT, LP_LOCK_PERIOD);
        console.log("  LiquidityPool:", address(liquidityPool));

        // 9. Deploy VaultController
        console.log("Deploying VaultController...");
        VaultController vaultController = new VaultController(address(ghsFiat), VAULT_ANNUAL_YIELD, VAULT_MIN_DEPOSIT);
        console.log("  VaultController:", address(vaultController));

        // -------------------------------------------------------------------------
        // Wire contracts
        // -------------------------------------------------------------------------

        // Gateway ↔ Withdrawals
        console.log("Wiring: Withdrawals.setGateway...");
        withdrawals.setGateway(address(gateway));
        console.log("Wiring: Gateway.setWithdrawalsContract...");
        gateway.setWithdrawalsContract(address(withdrawals));

        // GHSFIAT minting rights to Gateway (for onramp)
        console.log("Wiring: GHSFIAT.grantRole(MINTER_ROLE, gateway)...");
        ghsFiat.grantRole(ghsFiat.MINTER_ROLE(), address(gateway));

        // Register supported tokens on Gateway
        console.log("Wiring: Gateway.addSupportedToken(GHSFIAT)...");
        gateway.addSupportedToken(address(ghsFiat));

        // Authorize PayoutEscrow to call offrampFor on Gateway
        console.log("Wiring: Gateway.setAuthorizedContract(payoutEscrow)...");
        gateway.setAuthorizedContract(address(payoutEscrow), true);

        // Wire PayoutEscrow into PaymentRouter (for pending payout discovery)
        console.log("Wiring: PaymentRouter.setPayoutEscrow...");
        paymentRouter.setPayoutEscrow(address(payoutEscrow));

        vm.stopBroadcast();

        // -------------------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------------------

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Network:          ", block.chainid);
        console.log("Deployer:         ", deployer);
        console.log("Treasury:         ", treasury);
        console.log("DisputeResolver:  ", disputeResolver);
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
        console.log("--- B2B Flow ---");
        console.log("Business API sends stablecoins -> PayoutEscrow -> Recipient claims");
        console.log("Recipient options: Hold / Earn in Vault / P2P / CashOut via Gateway");
    }
}
