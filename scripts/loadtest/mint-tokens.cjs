// Forge de JWT RS256 pour les comptes de charge (campagnes k6).
// Prérequis : ./jwk.json = JWK Set de signature identity (secret de prod, NE PAS COMMITER) :
//   kubectl -n quizup-prod get secret quizup-identity-secret -o jsonpath="{.data.QUIZUP_IDENTITY_JWK}" | base64 -d > jwk.json
// Usage : node mint-tokens.cjs  ->  ./tokens.json (1000 users seedés + compte système, TTL 4 h)

const crypto = require("crypto");
const fs = require("fs");

const AUTHORITY = "https://identity.quizup.cnadjim.fr";
const SYSTEM_USER_ID = "0ada9a20-2198-4014-9ed0-57d0cc82fb42";
const COUNT = 1000;

const jwk = JSON.parse(fs.readFileSync("./jwk.json", "utf8")).keys[0];
const privateKey = crypto.createPrivateKey({ key: jwk, format: "jwk" });

const b64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);

function mint(userId) {
  const header = { alg: "RS256", kid: jwk.kid, typ: "JWT" };
  const payload = {
    iss: AUTHORITY,
    sub: userId,
    user_id: userId,
    aud: "web",
    iat: now,
    exp: now + 14400,
    scope: "openid profile email",
  };
  const input = `${b64url(header)}.${b64url(payload)}`;
  const signature = crypto
    .sign("RSA-SHA256", Buffer.from(input), privateKey)
    .toString("base64url");
  return `${input}.${signature}`;
}

const pad = (i) => String(i).padStart(12, "0");
const users = Array.from({ length: COUNT }, (_, index) => {
  const userId = `00000000-0000-4000-8000-${pad(index + 1)}`;
  return { userId, token: mint(userId) };
});

const system = { userId: SYSTEM_USER_ID, token: mint(SYSTEM_USER_ID) };

fs.writeFileSync(
  "./tokens.json",
  JSON.stringify({ system, users }),
);
console.log(`tokens: ${users.length} users + system (${SYSTEM_USER_ID})`);
