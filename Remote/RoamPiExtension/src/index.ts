import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Bridge } from "./bridge.ts";

const CHANNEL = "roampi:dialog:v1";
type DialogKind = "confirm" | "select" | "input";

/** Opt-in dialog relay via Pi's public cross-extension event bus. */
export function relayRoamPiDialog(pi: Pick<ExtensionAPI, "events">, kind: DialogKind, title: string, detail: string | string[]): Promise<string | boolean | undefined> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value: string | boolean | undefined) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => finish(kind === "confirm" ? false : undefined), 61_000);
    pi.events.emit(CHANNEL, { kind, title, detail, respond: finish });
  });
}

export default function (pi: ExtensionAPI): void {
  let bridge: Bridge | undefined;
  pi.events.on(CHANNEL, (request) => {
    if (!request || typeof request !== "object") return;
    const value = request as { kind?: unknown; title?: unknown; detail?: unknown; respond?: unknown };
    if (typeof value.respond !== "function") return;
    const kind = value.kind;
    if ((kind !== "confirm" && kind !== "select" && kind !== "input") || typeof value.title !== "string" ||
        (typeof value.detail !== "string" && !Array.isArray(value.detail))) {
      value.respond(kind === "confirm" ? false : undefined);
      return;
    }
    if (!bridge) { value.respond(kind === "confirm" ? false : undefined); return; }
    void bridge.relayDialog(kind, value.title, value.detail as string | string[])
      .then(value.respond as (result: string | boolean | undefined) => void)
      .catch(() => (value.respond as (result: boolean | undefined) => void)(kind === "confirm" ? false : undefined));
  });
  const current = () => bridge;
  pi.on("session_start", async (_event, ctx) => {
    // Reload constructs a new runtime. Never keep a stale ExtensionContext.
    if (bridge) await bridge.close();
    bridge = new Bridge(pi);
    await bridge.start(ctx);
  });
  pi.on("session_shutdown", async () => {
    if (bridge) await bridge.close();
    bridge = undefined;
  });
  pi.on("session_info_changed", async (_event, ctx) => { await current()?.update(ctx); });
  pi.on("model_select", async (_event, ctx) => { await current()?.update(ctx); current()?.emit("model"); });
  pi.on("thinking_level_select", async (_event, ctx) => { await current()?.update(ctx); current()?.emit("thinkingLevel"); });
  pi.on("agent_start", (_event, ctx) => { current()?.setState("working"); void current()?.update(ctx, "working"); });
  pi.on("agent_settled", (_event, ctx) => { current()?.setState("idle"); void current()?.update(ctx, "idle"); });
  pi.on("ui_prompt_start", (event) => { current()?.setState("waitingForApproval"); current()?.emit("approval", { waiting: true, kind: event.kind }); });
  pi.on("ui_prompt_end", (_event, ctx) => { current()?.setState(ctx.isIdle() ? "idle" : "working"); current()?.emit("approval", { completed: true }); });
  pi.on("message_start", (event) => { current()?.emit("message", { phase: "start", role: event.message.role }); });
  pi.on("message_update", (event) => {
    const update = event.assistantMessageEvent;
    if (update.type === "text_delta" || update.type === "thinking_delta") {
      // Live delivery only. Large deltas are split or dropped by the bounded socket writer.
      const delta = update.delta.slice(0, 4096);
      current()?.emit("message", { phase: "delta", kind: update.type, delta });
    }
  });
  pi.on("message_end", (event) => { current()?.emit("message", { phase: "end", role: event.message.role }); });
  pi.on("tool_execution_start", (event) => { current()?.emit("tool", { phase: "start", name: event.toolName }); });
  pi.on("tool_execution_end", (event) => { current()?.emit("tool", { phase: "end", name: event.toolName, error: event.isError }); });
}
