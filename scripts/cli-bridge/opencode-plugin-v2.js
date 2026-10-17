// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import { hostHook } from "./opencode-plugin.js";

// V2 loads an id/setup object, not the V1 function returning named hooks.
// Native permissions stay at `ask` until this plugin approves the exact
// tool call. If the plugin is missing or fails to load, headless execution
// cannot auto-approve the action.
export default {
  id: "tokenstat.gate",
  async setup(ctx) {
    const approved = new Set();
    const key = (session, call) => JSON.stringify([session, call]);
    await ctx.tool.hook("execute.before", async (event) => {
      approved.delete(key(event.sessionID, event.id));
      await hostHook("pre", {
        tool_name: event.tool,
        tool_use_id: event.id,
        tool_input: event.input,
      });
      approved.add(key(event.sessionID, event.id));
    });
    await ctx.permission.hook("evaluate", (event) => {
      if (event.source?.type === "tool" && approved.has(key(event.sessionID, event.source.id))) {
        event.effect = "allow";
      } else {
        event.effect = "deny";
        event.message = "Tokenstat has not approved this tool call.";
      }
    });
    await ctx.tool.hook("execute.after", async (event) => {
      approved.delete(key(event.sessionID, event.id));
      try {
        await hostHook("post", {
          tool_name: event.tool,
          tool_use_id: event.id,
          success: event.status === "completed",
          result: event.status === "completed" ? event.result : event.error?.message,
        });
      } catch (_) {
        // Telemetry cannot change the result of an action already taken.
      }
    });
  },
};
