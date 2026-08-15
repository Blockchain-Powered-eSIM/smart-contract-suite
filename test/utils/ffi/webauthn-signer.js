// Offchain WebAuthn assertion signer for Foundry tests, invoked through vm.ffi.
//
// The onchain verifier checks a P256 signature over
// sha256(authenticatorData || sha256(clientDataJSON)), and the challenge it compares against lives
// base64url encoded inside clientDataJSON. That makes a captured assertion unusable for any
// challenge other than the one it was made for, so a test that changes the challenge has to
// produce a new signature rather than edit a fixture.
//
// Usage:
//   node test/utils/ffi/webauthn-signer.js pubkey
//     -> abi.encode(bytes32 x, bytes32 y)
//
//   node test/utils/ffi/webauthn-signer.js sign <challengeHex> [origin]
//     -> abi.encode(WebAuthnSignature)
//
// Output is a 0x-prefixed hex string, which forge decodes to bytes.

const crypto = require("crypto");
const { AbiCoder } = require("ethers");

// Fixed test key pair. Hardcoded rather than generated per run so a failing test can be reproduced
// from the arguments alone, and so the public key a wallet is deployed with is a constant.
// It has no counterpart anywhere outside this repo and signs nothing but test fixtures.
const TEST_KEY_JWK = {
    kty: "EC",
    crv: "P-256",
    d: "KL7Cr6Ld8Lu_IukOLF8COJ0zpKMnPwJszfilaKLqSXc",
    x: "NPRJRWBMjLQdl2mQhX_3UbV4ThkjHkDYf_zSWpvI_eg",
    y: "p4vgUuAUwkz4JBoEHaraBXjdK5prl5GkM1yWDEv-p_I"
};

// Order of the P256 curve. WebAuthn.sol rejects s > n/2 as malleable, and OpenSSL emits either
// half, so every signature has to be normalised before it is handed to the verifier.
const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

const DEFAULT_ORIGIN = "android:apk-key-hash:SDxRUHQ5YWt-duegDSzGfQ_GWE_AF1EVynm-ksTNGGU";

// User Present (bit 0) and User Verified (bit 2). The verifier is called with
// requireUserVerification true, so both have to be set.
const AUTH_DATA_FLAGS = 0x05;

const coder = AbiCoder.defaultAbiCoder();

function publicKeyCoordinates() {
    return {
        x: Buffer.from(TEST_KEY_JWK.x, "base64url"),
        y: Buffer.from(TEST_KEY_JWK.y, "base64url")
    };
}

function buildAuthenticatorData() {
    const rpIdHash = crypto.createHash("sha256").update("app.kokio").digest();
    const counter = Buffer.alloc(4); // signature counter, not checked onchain
    return Buffer.concat([rpIdHash, Buffer.from([AUTH_DATA_FLAGS]), counter]);
}

function buildClientDataJSON(challenge, origin) {
    // Field order matters: the indices returned below are byte offsets into this exact string.
    return (
        '{"type":"webauthn.get","challenge":"' +
        challenge.toString("base64url") +
        '","origin":"' +
        origin +
        '","androidPackageName":"app.kokio"}'
    );
}

function sign(message) {
    const key = crypto.createPrivateKey({ key: TEST_KEY_JWK, format: "jwk" });
    // ieee-p1363 gives the raw r||s pair the verifier wants, rather than a DER wrapper.
    const raw = crypto.sign("sha256", message, { key, dsaEncoding: "ieee-p1363" });

    const r = BigInt("0x" + raw.subarray(0, 32).toString("hex"));
    let s = BigInt("0x" + raw.subarray(32, 64).toString("hex"));
    if (s > P256_N / 2n) {
        s = P256_N - s;
    }
    return { r, s };
}

function commandPubkey() {
    const { x, y } = publicKeyCoordinates();
    return coder.encode(["bytes32", "bytes32"], ["0x" + x.toString("hex"), "0x" + y.toString("hex")]);
}

function commandSign(challengeHex, origin) {
    const challenge = Buffer.from(String(challengeHex).replace(/^0x/, ""), "hex");
    if (challenge.length === 0) {
        throw new Error("challenge is empty");
    }

    const clientDataJSON = buildClientDataJSON(challenge, origin || DEFAULT_ORIGIN);
    const authenticatorData = buildAuthenticatorData();

    const typeIndex = clientDataJSON.indexOf('"type":"webauthn.get"');
    const challengeIndex = clientDataJSON.indexOf('"challenge":"');
    if (typeIndex < 0 || challengeIndex < 0) {
        throw new Error("built client data is missing a required field");
    }

    const clientDataJSONHash = crypto.createHash("sha256").update(clientDataJSON).digest();
    const { r, s } = sign(Buffer.concat([authenticatorData, clientDataJSONHash]));

    return coder.encode(
        ["tuple(bytes,string,uint256,uint256,uint256,uint256)"],
        [["0x" + authenticatorData.toString("hex"), clientDataJSON, challengeIndex, typeIndex, r, s]]
    );
}

function main() {
    const [command, ...args] = process.argv.slice(2);

    switch (command) {
        case "pubkey":
            return commandPubkey();
        case "sign":
            return commandSign(args[0], args[1]);
        default:
            throw new Error(`unknown command: ${command}`);
    }
}

try {
    process.stdout.write(main());
} catch (error) {
    process.stderr.write(`webauthn-signer: ${error.message}\n`);
    process.exit(1);
}
