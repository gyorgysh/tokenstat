// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("../cli-bridge/opencode-plugin.js", import.meta.url), "utf8");
const { default: gate } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
process.env.TOKENSTAT_CHAT_HOOK_PATH = "/fixture path/helper";
let allowDiagnostics;
const diagnosticsRead = new Promise(resolve => { allowDiagnostics = resolve; });
globalThis.Bun = {
  spawn(argv) {
    assert.deepEqual(argv, ["/fixture path/helper", "hook", "opencode", "pre"]);
    return {
      stdin: { write() {}, end() {} },
      stdout: new ReadableStream({ async pull(controller) {
        await diagnosticsRead;
        controller.enqueue(new TextEncoder().encode('{"decision":"allow"}'));
        controller.close();
      } }, { highWaterMark: 0 }),
      stderr: new ReadableStream({ pull(controller) {
        allowDiagnostics();
        controller.enqueue(new TextEncoder().encode("diagnostic"));
        controller.close();
      } }, { highWaterMark: 0 }),
      exited: diagnosticsRead.then(() => 0),
    };
  },
};
const plugin = await gate();
const timeout = setTimeout(() => { console.error("hook pipes deadlocked"); process.exit(1); }, 2000);
try {
  await plugin["tool.execute.before"]({ tool: "fixture", callID: "one" }, { args: {} });
  console.log("OpenCode gate drains both output pipes before waiting for exit.");
} finally {
  clearTimeout(timeout);
}

// The v2 package uses the same bounded host protocol with a different plugin API.
const v2Source = (await readFile(new URL('../cli-bridge/opencode-plugin-v2.js', import.meta.url), 'utf8'))
  .replace('./opencode-plugin.js', `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const { default: v2 } = await import(`data:text/javascript;base64,${Buffer.from(v2Source).toString('base64')}`);
let reply = '{"decision":"allow"}';
let exitCode = 0;
const calls = [];
globalThis.Bun.spawn = (argv) => {
  const call = { phase: argv.at(-1) };
  calls.push(call);
  return {
    stdin: { write(body) { call.payload = JSON.parse(body); }, end() {} },
    stdout: new Response(reply).body,
    stderr: new Response('diagnostic').body,
    exited: Promise.resolve(exitCode),
  };
};
const hooks = new Map();
await v2.setup({
  tool: { async hook(name, callback) { hooks.set(`tool.${name}`, callback); } },
  permission: { async hook(name, callback) { hooks.set(`permission.${name}`, callback); } },
});
const before = hooks.get('tool.execute.before');
const permission = hooks.get('permission.evaluate');
const after = hooks.get('tool.execute.after');
const event = { sessionID: 'session-a', id: 'call-a', tool: 'shell', input: { command: 'git status' } };
const request = () => ({ sessionID: event.sessionID, source: { type: 'tool', id: event.id }, effect: 'ask' });
let check = request();
permission(check);
assert.equal(check.effect, 'deny', 'a native request cannot bypass the host gate');
await before(event);
assert.deepEqual(calls.at(-1), { phase: 'pre', payload: { tool_name: 'shell', tool_use_id: 'call-a', tool_input: { command: 'git status' } } });
check = request(); permission(check); assert.equal(check.effect, 'allow');
check = { ...request(), sessionID: 'session-b' }; permission(check); assert.equal(check.effect, 'deny');
check = { ...request(), source: undefined }; permission(check); assert.equal(check.effect, 'deny');
await after({ ...event, status: 'error', error: { message: 'Tool failed' } });
assert.equal(calls.at(-1).payload.success, false);
assert.equal(calls.at(-1).payload.result, 'Tool failed');
check = request(); permission(check); assert.equal(check.effect, 'deny', 'approval expires with the tool result');
for (const [body, code] of [['{"decision":"deny","reason":"Declined"}', 0], ['not json', 0], ['{"decision":"allow"}', 1]]) {
  reply = body; exitCode = code;
  await assert.rejects(() => before(event));
  check = request(); permission(check); assert.equal(check.effect, 'deny');
}
reply = '{"decision":"allow"}'; exitCode = 0;
delete process.env.TOKENSTAT_CHAT_HOOK_PATH;
await assert.rejects(() => before(event), /no host hook/);
await assert.doesNotReject(() => after({ ...event, status: 'completed', result: { content: 'already done' } }));
console.log('OpenCode v2 gate enforces allow, deny, malformed decisions, helper failure, session scope and cleanup.');
