// // require('dotenv').config();
// import "dotenv/config";
// // import { modules } from "@nomicfoundation/hardhat-ignition-ethers";
// import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
// // import IEntryPoint from "../../artifacts/@account-abstraction/contracts/interfaces/IEntryPoint.sol";
// // import DeviceWallet from "../../artifacts/contracts/wallet/DeviceWallet.sol/DeviceWallet.json";
// // import DeviceWalletFactory from "../../artifacts/contracts/wallet/DeviceWalletFactory.sol/DeviceWalletFactory.json";

// // TODO: change to sepolia address
// const EntryPointModule = buildModule("EntryPointModule", (m) => {
//     const entryPoint = m.contractAt(
//         "EntryPoint",
//         IEntryPoint,
//         "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
//     );

//     return { entryPoint };
// });

// // const P256VerifierModule = buildModule("P256VerifierModule", (m) => {
// //     const webAuthnLib = m.library("WebAuthn");
// //     const p256Verifier = m.contract("P256Verifier", [], {
// //         libraries: {
// //             WebAuthn: webAuthnLib
// //         }
// //     });

// //     return { p256Verifier };
// // });

// const DeviceWalletImplModule = buildModule("DeviceWalletImpl", (m) => {
//     const deviceWalletImpl = m.contract("DeviceWallet", DeviceWallet);

//     return { deviceWalletImpl };
// });

// const DeviceWalletFactoryModule = buildModule("DeviceWalletFactoryModule", (m) => {
//     const { p256Verifier } = m.useModule(P256VerifierModule);
//     const { entryPoint } = m.useModule(EntryPointModule);
//     const { deviceWalletImpl } = m.useModule(DeviceWalletImplModule);

//     const deviceWalletFactoryImpl = m.contract("DeviceWalletFactory");
//     // const deviceWalletFactoryProxy = m.contract("ERC1967Proxy", [
//     //     deviceWalletFactoryImpl,
//     //     "0x"
//     // ]);
//     const deviceWalletFactory = m.contract("ERC1967Proxy", [
//         deviceWalletFactoryImpl,
//         abi.encodeCall(
//             deviceWalletFactoryImpl.initialize,
//             (
//                 deviceWalletImpl,
//                 process.env.ESIM_WALLET_ADMIN,
//                 process.env.VAULT,
//                 process.env.UPGRADE_MANAGER,
//                 entryPoint,
//                 p256Verifier
//             )
//         )
//     ]);

//     // const deviceWalletFactory = m.contract(
//     //     "DeviceWalletFactory", {
//     //         artifact: DeviceWalletFactory,
//     //         proxy: {
//     //             kind: "uups"
//     //         },
//     //         args: [
//     //             deviceWalletImpl,
//     //             process.env.ESIM_WALLET_ADMIN,
//     //             process.env.VAULT,
//     //             process.env.UPGRADE_MANAGER,
//     //             entryPoint,
//     //             p256Verifier
//     //         ]
//     //     }
//     // );

//     return { deviceWalletFactory };
// });

// const DeployModule = buildModule("DeployModule", (m) => {

//     let ESIM_WALLET_ADMIN = process.env.ESIM_WALLET_ADMIN;
//     let UPGRADE_MANAGER = process.env.UPGRADE_MANAGER;
//     let VAULT = process.env.VAULT;

//     const { deviceWalletFactory } = m.useModule(DeviceWalletFactoryModule);

//     return { deviceWalletFactory };
// });

// export default {
//     // P256VerifierModule,
//     DeployModule
// };
