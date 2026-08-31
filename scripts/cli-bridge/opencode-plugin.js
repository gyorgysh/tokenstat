// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Per-turn OpenCode safety bridge. It is loaded only from tokenstat's private
// configuration; it is never placed in a project or a person's OpenCode home.
//
// Unlike the other five backends, OpenCode has no shell-hook contract, so this
// file is the gate. Two rules it must not break:
//
//   1. The helper is spawned as **argv**, so it takes the raw path. Every other
//      backend gets a shell-quoted command line from `chat_gate::hook_command`;
//      handing that string to `Bun.spawn` would try to execute a file whose
//      name contains quotes and spaces. Hence a separate environment variable
//      whose name says which of the two it carries.
//   2. The decision is on **stdout**, not in the exit code. The helper always
//      exits 0 and prints a decision document, because an exit code is not a
//      denial to any of these CLIs and treating it as one here would make this
//      plugin the only place that disagrees about what a refusal looks like.

const HELPER = "TOKENSTAT_CHAT_HOOK_PATH";

async function hostHook(phase, payload) {
  const helper = process.env[HELPER];
  if (!helper) throw new Error("tokenstat cannot approve this: no host hook");

  const child = Bun.spawn([helper, "hook", "opencode", phase], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  child.stdin.write(JSON.stringify(payload));
  child.stdin.end();
  const body = await new Response(child.stdout).text();
  const code = await child.exited;

  // Fail closed on anything unexpected. A gate that cannot say what it decided
  // has not decided anything, and letting the tool run on that basis is the
  // failure mode this whole channel exists to prevent.
  if (code !== 0) {
    const reason = (await new Response(child.stderr).text()).trim();
    throw new Error(reason || "tokenstat cannot approve this: the host hook failed");
  }
  let decision;
  try {
    decision = JSON.parse(body.trim().split("\n").pop() || "{}");
  } catch (_) {
    throw new Error("tokenstat cannot approve this: unreadable decision");
  }
  const verdict =
    decision?.hookSpecificOutput?.permissionDecision ?? decision?.decision;
  if (verdict === "allow") return;
  throw new Error(
    decision?.hookSpecificOutput?.permissionDecisionReason ??
      decision?.reason ??
      "The person declined this in tokenstat. Do not retry it."
  );
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
