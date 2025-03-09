require('dotenv').config();
const {buildModule} = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("DeviceWalletImplModule", (m) => {
    const entryPoint = m.getParameter("entryPoint");
    const p256Verifier = m.getParameter("p256Verifier");
    
    const deviceWalletImpl = m.contract("DeviceWallet", [
        entryPoint,
        p256Verifier
    ]);

    return { deviceWalletImpl };
});
