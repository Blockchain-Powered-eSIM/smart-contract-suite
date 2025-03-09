require('dotenv').config();
const {buildModule} = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("P256VerifierModule", (m) => {
    // const webAuthnLib = m.library("WebAuthn");
    // const p256Verifier = m.contract("P256Verifier", [], {
    //     libraries: {
    //         WebAuthn: webAuthnLib
    //     }
    // });

    const p256Verifier = m.contract("P256Verifier", []);

    return { p256Verifier };
});
