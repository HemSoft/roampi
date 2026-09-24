// Test-only Pi extension. It registers a credential-free scripted provider and
// one approval tool so integration tests can drive real Pi turns without a
// model service. Never install it outside a disposable agent directory.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import { Type } from "typebox";

const API = "roampi-scripted";

function lastUserText(messages: any[]): string {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message?.role !== "user") continue;
    if (typeof message.content === "string") return message.content;
    return message.content
      .filter((part: any) => part.type === "text")
      .map((part: any) => part.text)
      .join("\n");
  }
  return "";
}

function emptyUsage() {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });
}

function streamScripted(model: any, context: any, options?: any) {
  const stream = createAssistantMessageEventStream();
  const signal: AbortSignal | undefined = options?.signal;
  (async () => {
    const output: any = {
      role: "assistant",
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: emptyUsage(),
      stopReason: "stop",
      timestamp: Date.now(),
    };
    stream.push({ type: "start", partial: output });
    const messages = context.messages ?? [];
    const last = messages[messages.length - 1];
    const text = lastUserText(messages);

    if (last?.role !== "toolResult" && text.startsWith("approval")) {
      const toolCall = { type: "toolCall" as const, id: `call-${Date.now()}`, name: "fixture_confirm", arguments: {} };
      output.content.push(toolCall);
      stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
      stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: output });
      output.stopReason = "toolUse";
      stream.push({ type: "done", reason: "toolUse", message: output });
      stream.end();
      return;
    }

    let reply = `echo: ${text}`;
    let chunks = 1;
    let delayMs = 0;
    const slow = /^slow (\d+)/.exec(text);
    if (last?.role === "toolResult") {
      const resultText = (last.content ?? []).map((part: any) => part.text ?? "").join("");
      reply = `tool: ${resultText}`;
    } else if (slow) {
      chunks = 10;
      delayMs = Math.max(1, Math.floor(Number(slow[1]) / chunks));
    }

    output.content.push({ type: "text", text: "" });
    stream.push({ type: "text_start", contentIndex: 0, partial: output });
    for (let chunk = 0; chunk < chunks; chunk += 1) {
      if (signal?.aborted) break;
      const delta = chunks === 1 ? reply : `${chunk === 0 ? reply : ""}.`;
      output.content[0].text += delta;
      stream.push({ type: "text_delta", contentIndex: 0, delta, partial: output });
      if (delayMs > 0) await sleep(delayMs, signal);
    }
    stream.push({ type: "text_end", contentIndex: 0, content: output.content[0].text, partial: output });
    if (signal?.aborted) {
      output.stopReason = "aborted";
      stream.push({ type: "error", reason: "aborted", error: output });
    } else {
      stream.push({ type: "done", reason: "stop", message: output });
    }
    stream.end();
  })();
  return stream;
}

export default function (pi: any) {
  pi.registerProvider("roampi-fixture", {
    baseUrl: "http://127.0.0.1:9",
    apiKey: "fixture-not-a-secret",
    api: API,
    models: [
      {
        id: "scripted",
        name: "RoamPi scripted fixture",
        reasoning: true,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 32000,
        maxTokens: 4096,
      },
    ],
    streamSimple: streamScripted,
  });

  pi.registerTool({
    name: "fixture_confirm",
    label: "Fixture confirm",
    description: "Ask the user to confirm a fixture action.",
    parameters: Type.Object({}),
    async execute(_id: string, _params: unknown, _signal: unknown, _onUpdate: unknown, _ctx: any) {
      const confirmed = await new Promise<boolean>((resolve) => {
        pi.events.emit("roampi:dialog:v1", {
          kind: "confirm", title: "Fixture approval", detail: "Allow the fixture action?", respond: resolve,
        });
      });
      return { content: [{ type: "text", text: confirmed ? "confirmed" : "declined" }], details: undefined };
    },
  });

  pi.registerCommand("fixture-reload", {
    description: "Reload the extension runtime",
    handler: async (_args: string, ctx: any) => {
      await ctx.reload();
    },
  });
}
