import { test } from "node:test";
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtemp, lstat, readFile, rm, writeFile } from "node:fs/promises";
import { createConnection, type Socket } from "node:net";
import { Bridge } from "../src/bridge.ts";
import { discover, frame, Framer, live, MAX_FRAME, privateDirectory, processStart, publishRegistry } from "../src/protocol.ts";

async function fixture() {
  const root = await mkdtemp(join("/tmp", "roampi-"));
  const delivered: { text: string; delivery?: string }[] = [];
  let idle = true;
  let sessionId = "session-one";
  const pi = { sendUserMessage(text: string, options?: { deliverAs?: string }) { delivered.push({ text, delivery: options?.deliverAs }); } };
  const ctx: any = {
    cwd: root, mode: "tui", model: { provider: "fixture", id: "scripted" }, thinkingLevel: "low",
    sessionManager: { getSessionId: () => sessionId, getSessionFile: () => join(root, "history.jsonl"), getSessionName: () => "test" },
    isIdle: () => idle, abort: () => { idle = true; },
  };
  const bridge = new Bridge(pi as any, root);
  await bridge.start(ctx);
  return { root, bridge, delivered, ctx, setIdle(value: boolean) { idle = value; }, setSession(value: string) { sessionId = value; } };
}

class Client {
  readonly socket: Socket;
  private pending: unknown[] = [];
  private waiters: ((value: any) => void)[] = [];
  private framer = new Framer();
  constructor(path: string) {
    this.socket = createConnection(path);
    this.socket.on("data", (bytes) => {
      for (const value of this.framer.push(bytes)) {
        const waiter = this.waiters.shift();
        if (waiter) waiter(value); else this.pending.push(value);
      }
    });
  }
  next(): Promise<any> {
    if (this.pending.length) return Promise.resolve(this.pending.shift());
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error("client timed out")), 1500);
      this.waiters.push((value) => { clearTimeout(timer); resolve(value); });
    });
  }
  async send(type: string, fields: Record<string, unknown> = {}) {
    this.socket.write(frame({ version: 1, id: type, type, ...fields }));
    const earlier: unknown[] = [];
    let response: any;
    do { response = await this.next(); if (response.type !== "response") earlier.push(response); }
    while (response.type !== "response");
    this.pending.unshift(...earlier);
    return response;
  }
  close() { this.socket.destroy(); }
}

test("strict LF JSONL rejects CR, malformed UTF-8, oversized, and partial frames", () => {
  const f = new Framer();
  assert.deepEqual(f.push(Buffer.from('{"a":1')), []);
  assert.deepEqual(f.push(Buffer.from('}\n')), [{ a: 1 }]);
  assert.throws(() => new Framer().push(Buffer.from('{}\r\n')), /invalid_frame/);
  assert.throws(() => new Framer().push(Buffer.from([0xff, 10])), /invalid_json/);
  assert.throws(() => new Framer().push(Buffer.alloc(MAX_FRAME + 1)), /frame_too_large/);
});

test("registry is private, bounded, excludes transcript and credentials, and rejects reused PID", async () => {
  const f = await fixture();
  try {
    const stat = await lstat(f.bridge.dir);
    assert.equal(stat.mode & 0o777, 0o700);
    assert.equal((await lstat(f.bridge.socketPath)).mode & 0o777, 0o600);
    const records = await discover(f.bridge.dir);
    assert.equal(records.length, 1);
    assert.equal(records[0].sessionId, "session-one");
    assert.equal(records[0].processStart, processStart(process.pid));
    assert.equal(live({ ...records[0], processStart: "old birth" }), false);
    const bytes = await readFile(join(f.bridge.dir, `${f.bridge.runId}.json`), "utf8");
    assert.ok(!bytes.includes("privateKey") && !bytes.includes("transcript"));
    f.setSession("session-two"); await f.bridge.update(f.ctx);
    assert.equal((await discover(f.bridge.dir))[0].sessionId, "session-two");
    await writeFile(join(f.bridge.dir, "attacker.json"), "{}", { mode: 0o600 });
    assert.equal((await discover(f.bridge.dir)).length, 1);
  } finally { await f.bridge.close(); await rm(f.root, { recursive: true, force: true }); }
});

test("observers receive events but only renewable controller sends prompts, answers dialogs and interrupts", async () => {
  const f = await fixture();
  const owner = new Client(f.bridge.socketPath), observer = new Client(f.bridge.socketPath);
  try {
    assert.equal((await owner.send("subscribe")).metadata.state, "idle");
    assert.equal((await observer.send("subscribe")).metadata.state, "idle");
    const acquired = await owner.send("acquire"); const token = acquired.token;
    assert.equal(acquired.ok, true);
    assert.equal((await owner.next()).kind, "control");
    assert.equal((await observer.next()).kind, "control");
    assert.equal((await observer.send("prompt", { token, text: "secret", delivery: "immediate" })).code, "not_controller");
    assert.equal((await owner.send("prompt", { token, text: "hello", delivery: "immediate" })).ok, true);
    f.setIdle(false);
    assert.equal((await owner.send("prompt", { token, text: "later", delivery: "followUp" })).ok, true);
    assert.equal((await owner.send("prompt", { token, text: "now", delivery: "steer" })).ok, true);
    assert.equal((await owner.send("prompt", { token, text: "wrong", delivery: "immediate" })).code, "wrong_delivery_state");
    assert.deepEqual(f.delivered, [{ text: "hello", delivery: undefined }, { text: "later", delivery: "followUp" }, { text: "now", delivery: "steer" }]);
    const decision = f.bridge.relayDialog("confirm", "Fixture approval", "Allow?");
    assert.equal((await owner.next()).kind, "session");
    const dialog = await owner.next();
    assert.equal(dialog.type, "dialog");
    const observerState = await observer.next();
    assert.equal(observerState.state, "waitingForApproval");
    assert.equal((await observer.send("answer", { token, dialogId: dialog.id, value: true })).ok, false);
    assert.equal((await owner.send("answer", { token, dialogId: dialog.id, value: true })).ok, true);
    assert.equal(await decision, true);
    // Drain status events, then verify disconnect fails a second request closed.
    const second = f.bridge.relayDialog("confirm", "Second", "Allow?");
    owner.close();
    assert.equal(await second, false);
    assert.equal((await observer.send("acquire")).code, "lease_held");
    await new Promise((resolve) => setTimeout(resolve, 3200));
    // Pending completion events can arrive before the response.
    let result; do { result = await observer.send("acquire"); } while (result.type === "event");
    assert.equal(result.ok, true);
    assert.equal((await observer.send("interrupt", { token: result.token })).ok, true);
  } finally { owner.close(); observer.close(); await f.bridge.close(); await rm(f.root, { recursive: true, force: true }); }
});

test("malformed and unsupported requests cannot mutate state; shutdown removes only owned artifacts", async () => {
  const f = await fixture(); const c = new Client(f.bridge.socketPath);
  try {
    assert.equal((await c.send("prompt", { text: "unleased", delivery: "immediate" })).ok, false);
    c.socket.write(frame({ version: 999, id: "unsupported", type: "snapshot" }));
    assert.equal((await c.next()).code, "unsupported_or_invalid");
    assert.deepEqual(f.delivered, []);
  } finally { c.close(); await f.bridge.close(); }
  assert.equal((await discover(f.bridge.dir)).length, 0);
  await rm(f.root, { recursive: true, force: true });
});

test("discovery without an installed bridge never changes the remote filesystem", async () => {
  const root = await mkdtemp(join("/tmp", "roampi-readonly-"));
  const missing = join(root, "agent", "roampi");
  try {
    assert.deepEqual(await discover(missing), []);
    await assert.rejects(lstat(join(root, "agent")), { code: "ENOENT" });
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("insecure runtime directory and oversized registry fail closed", async () => {
  const root = await mkdtemp(join(tmpdir(), "roampi-perm-"));
  try {
    const dir = join(root, "roampi");
    await import("node:fs/promises").then((fs) => fs.mkdir(dir, { mode: 0o755 }));
    await assert.rejects(privateDirectory(dir), /owner-only/);
    await assert.rejects(publishRegistry(root, { runId: "test", cwd: "x".repeat(9000) } as any), /exceeds limit/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
