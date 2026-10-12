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
