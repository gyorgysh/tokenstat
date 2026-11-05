// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Chat history through the production relay and host. Run with Node 22+.
// TOKENSTAT_WEBSITE_DIR may point to the sibling website repository.
// All accounts, keys and sockets are disposable and use only loopback.
process.env.ENV_FILE = "/dev/null";
process.env.SITE = "tokenstat";
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { DatabaseSync } = require("node:sqlite");
const tokenstat = path.resolve(__dirname, "../..");
const website = path.resolve(process.env.TOKENSTAT_WEBSITE_DIR || path.join(tokenstat, "../www"));
const db = require(path.join(website, "lib/db"));
const ledger = new DatabaseSync(":memory:");
ledger.exec("PRAGMA foreign_keys=ON");
for (const sql of db.MIGRATIONS) ledger.exec(sql);
db.run = (sql, ...args) => ledger.prepare(sql).run(...args);
db.get = (sql, ...args) => ledger.prepare(sql).get(...args) || null;
db.all = (sql, ...args) => ledger.prepare(sql).all(...args);
db.tx = fn => { ledger.exec("BEGIN"); try { const result = fn(); ledger.exec("COMMIT"); return result; } catch (error) { ledger.exec("ROLLBACK"); throw error; } };
const sync = require(path.join(website, "lib/sync"));
const usage = require(path.join(website, "tunnel/usage"));
const { createTunnelServer, makeAuthenticator, makeEntitlementRecheck } = require(path.join(website, "tunnel/server"));

// PKCS#8 X25519 private-key prefix; the seeds match the Rust fixture.
function publicKey(byte) {
  const der = Buffer.concat([Buffer.from("302e020100300506032b656e04220420", "hex"), Buffer.alloc(32, byte)]);
  const key = crypto.createPrivateKey({ key: der, format: "der", type: "pkcs8" });
  return crypto.createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
}

async function main() {
  // Exercise the account bootstrap the native clients need, using only
  // this in-memory database. Pairing must bind authentication to its user.
  const bootstrapAccount = "u_native_history_bootstrap";
  const bootstrapMachine = "m_0123456789abcde0";
  db.run("INSERT INTO users (id,tier,created_at) VALUES (?,'free',?)", bootstrapAccount, new Date().toISOString());
  const pairing = sync.createPairingCode(bootstrapAccount);
  assert.ok(pairing.code);
  const { createAccountServer } = require('../qa/chat-history/account-server.cjs');
  const api = await createAccountServer(sync, bootstrapAccount);
  try {
    const call = async (method, route, body, token) => {
      const response = await fetch(api.origin + route, { method,
        headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(10000) });
      return { status: response.status, body: await response.json() };
    };
    assert.equal((await call('GET', '/api/v1/schema')).status, 200);
    assert.equal((await call('GET', '/api/v1/me')).status, 401);
    const redeemed = await call('POST', '/api/v1/device/redeem', { code: pairing.code, machine: bootstrapMachine });
    assert.equal(redeemed.status, 200);
    const token = redeemed.body.token;
    const auth = sync.authToken({ headers: { authorization: `Bearer ${token}` } });
    assert.equal(auth.user?.id, bootstrapAccount);
    assert.equal((await call('POST', '/api/v1/device/redeem', { code: pairing.code, machine: bootstrapMachine })).status, 400);
    assert.equal((await call('GET', '/api/v1/me', null, token)).status, 200);
    assert.equal((await call('PUT', '/api/v1/machines/me', { machine: bootstrapMachine,
      public_identity: publicKey(63), label: 'Native history bootstrap', kind: 'client' }, token)).status, 200);
    assert.equal((await call('POST', '/api/v1/tunnel/token', { machine: bootstrapMachine }, token)).status, 200);
    console.log('Loopback account HTTP pairing, authentication, registration and relay mint passed.');
  } finally { await api.close(); }

  const account = "u_chat_history_fixture";
  db.run("INSERT INTO users (id,tier,created_at) VALUES (?,'free',?)", account, new Date().toISOString());
  const tokens = [];
  for (const [id, byte] of [["m_0123456789abcde1", 60], ["m_0123456789abcde2", 61], ["m_0123456789abcde3", 62]]) {
    db.run("INSERT INTO machines (id,user_id,first_seen_at,public_identity) VALUES (?,?,?,?)", id, account, new Date().toISOString(), publicKey(byte));
    const result = sync.mintTunnelToken(account, id);
    assert.equal(result.status, 200, result.body?.message);
    tokens.push(result.body.token);
  }
  const relay = createTunnelServer({ port: 0, authenticate: makeAuthenticator({ db }),
    recheckEntitlement: makeEntitlementRecheck({ db }), logger: { info() {}, log() {}, error() {}, warn() {} } });
  await new Promise((resolve, reject) => { relay.server.once("error", reject); relay.server.listen(0, "127.0.0.1", resolve); });
  try {
    const child = spawn("cargo", ["test", "-p", "tokenstat-host", "--lib", "remote::history_tests::encrypted_history_readers_keep_independent_cursors_across_reconnect", "--", "--exact", "--nocapture"], {
      cwd: tokenstat,
      env: { ...process.env, TOKENSTAT_HISTORY_TEST_RELAY: `ws://127.0.0.1:${relay.server.address().port}`,
        TOKENSTAT_HISTORY_TEST_TOKEN_HOST: tokens[0], TOKENSTAT_HISTORY_TEST_TOKEN_PHONE: tokens[1], TOKENSTAT_HISTORY_TEST_TOKEN_DESKTOP: tokens[2] },
      stdio: "inherit",
    });
    const timeout = setTimeout(() => child.kill("SIGKILL"), 300000);
    let code;
    try { code = await new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", resolve); }); }
    finally { clearTimeout(timeout); }
    assert.equal(code, 0, "Encrypted chat history fixture failed");
    assert.ok(usage.sharedUsedBytes(account) > 0, "encrypted payload must be metered to the free account");
    console.log("Two chat readers, reconnects, encrypted history and relay metering passed.");
  } finally {
    relay.close();
    ledger.close();
  }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
