// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Per-turn OpenCode safety bridge. It is loaded only from Tokenstat's private
// configuration; it is never placed in a project or a person's OpenCode home.

async function hostHook(phase, payload) {
  const helper = process.env.TOKENSTAT_CHAT_HOOK_COMMAND;
  if (!helper) throw new Error("Tokenstat approval channel is unavailable");

  const child = Bun.spawn([helper, "hook", "opencode", phase], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  child.stdin.write(JSON.stringify(payload));
  child.stdin.end();
  const code = await child.exited;
  if (code !== 0) {
    const reason = (await new Response(child.stderr).text()).trim();
    throw new Error(reason || "Tokenstat denied this tool request");
  }
}

export default async function tokenstatGate() {
  return {
    "tool.execute.before": async (input, output) => {
      await hostHook("pre", {
        tool_name: input.tool,
        tool_use_id: input.callID,
        tool_input: output.args,
      });
    },
    "tool.execute.after": async (input, output) => {
      // The action has already happened. Keep its true result even if the
      // post-tool telemetry channel is temporarily unavailable.
      try {
        await hostHook("post", {
          tool_name: input.tool,
          tool_use_id: input.callID,
          success: true,
          result: output.output,
        });
      } catch (_) {}
    },
  };
}
