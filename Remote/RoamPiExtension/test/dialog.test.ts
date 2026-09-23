import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { createConnection } from "node:net";
import { Bridge } from "../src/bridge.ts";
import { frame, Framer } from "../src/protocol.ts";

test("cooperative select and input validate answers and never broadcast dialog payloads", async () => {
  const dir = await mkdtemp("/tmp/roampi-dialog-");
  const bridge = new Bridge({ sendUserMessage() {} } as any, dir);
  const ctx: any = { cwd: dir, mode: "rpc", sessionManager: { getSessionId: () => "s", getSessionFile: () => undefined, getSessionName: () => undefined }, isIdle: () => true };
  await bridge.start(ctx);
  const control = createConnection(bridge.socketPath);
  const observer = createConnection(bridge.socketPath);
  const frames = new Framer(), seen: any[] = [];
  const observed = new Framer(), passive: any[] = [];
  control.on("data", (bytes) => seen.push(...frames.push(bytes)));
  observer.on("data", (bytes) => passive.push(...observed.push(bytes)));
  const waitFor = async (items: any[], predicate: (x: any) => boolean) => {
    for (let i = 0; i < 150; i++) {
      const found = items.find(predicate);
      if (found) return found;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw Error("response timeout");
  };
  const send = (socket: typeof control, id: string, type: string, extra: object = {}) => socket.write(frame({ version: 1, id, type, ...extra }));
  try {
    send(control, "s1", "subscribe"); send(observer, "s2", "subscribe");
    await waitFor(seen, (x) => x.id === "s1"); await waitFor(passive, (x) => x.id === "s2");
    send(control, "a", "acquire");
    const { token } = await waitFor(seen, (x) => x.id === "a");
    send(control, "r", "renew", { token });
    assert.equal((await waitFor(seen, (x) => x.id === "r")).ok, true);
    const selection = bridge.relayDialog("select", "Choose", ["A", "B"]);
    const request = await waitFor(seen, (x) => x.type === "dialog" && x.kind === "select");
    send(control, "invalid", "answer", { token, dialogId: request.id, value: "C" });
    assert.equal((await waitFor(seen, (x) => x.id === "invalid")).code, "invalid_answer");
    send(control, "valid", "answer", { token, dialogId: request.id, value: "B" });
    assert.equal(await selection, "B");
    const input = bridge.relayDialog("input", "Enter text", "Placeholder");
    const prompt = await waitFor(seen, (x) => x.type === "dialog" && x.kind === "input");
    send(control, "text", "answer", { token, dialogId: prompt.id, value: "typed" });
    assert.equal(await input, "typed");
    assert.equal(passive.some((x) => x.type === "dialog" || JSON.stringify(x).includes("Placeholder") || JSON.stringify(x).includes("typed")), false);
    send(control, "release", "release", { token });
    assert.equal((await waitFor(seen, (x) => x.id === "release")).ok, true);
    assert.equal(await bridge.relayDialog("confirm", "No controller", "Deny"), false);
  } finally {
    control.destroy(); observer.destroy(); await bridge.close(); await rm(dir, { recursive: true, force: true });
  }
});
