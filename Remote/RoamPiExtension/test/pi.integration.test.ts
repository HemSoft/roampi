import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { createConnection } from "node:net";
import { discover, frame, Framer } from "../src/protocol.ts";

const root = resolve(import.meta.dirname, "..");
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

test("disposable Pi RPC process survives socket disconnect and accepts new controller", { timeout: 40_000 }, async () => {
  const agentDir = await mkdtemp("/tmp/roampi-pi-");
  const install = spawn(process.execPath, [join(root, "install.mjs"), "--apply", "--agent-dir", agentDir], { stdio: "ignore" });
  assert.equal(await new Promise((resolve) => install.once("exit", resolve)), 0);
  const child = spawn("pi", ["--mode", "rpc", "--offline", "--no-context-files", "--no-approve",
    "--extension", join(root, "test/fixtures/scripted-provider/index.ts"),
    "--model", "roampi-fixture/scripted"], {
    cwd: agentDir, env: { ...process.env, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1" }, stdio: ["pipe", "pipe", "pipe"],
  });
  let errors = "", output = "";
  child.stderr.on("data", (data) => { errors = (errors + data.toString()).slice(-4000); });
  child.stdout.on("data", (data) => { output = (output + data.toString()).slice(-8000); });
  const connect = (path: string) => new Promise<import("node:net").Socket>((resolve, reject) => {
    const socket = createConnection(path); socket.once("connect", () => resolve(socket)); socket.once("error", reject);
  });
  async function exchange(socket: import("node:net").Socket, type: string, fields: Record<string, unknown> = {}) {
    const parser = new Framer();
    return new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(Error("socket response timeout")), 3000);
      socket.once("data", (bytes) => {
        clearTimeout(timer);
        const response = parser.push(bytes).find((item: any) => item.type === "response");
        if (response) resolve(response); else reject(Error("no response"));
      });
      socket.write(frame({ version: 1, type, id: type, ...fields }));
    });
  }
  try {
    let records: Awaited<ReturnType<typeof discover>> = [];
    for (let attempts = 0; attempts < 100 && !records.length && child.exitCode === null; attempts++) {
      await wait(100);
      try { records = await discover(join(agentDir, "roampi")); } catch { /* Pi is starting. */ }
    }
    assert.equal(records.length, 1, `Pi did not publish bridge; stderr (redacted): ${errors.replaceAll(agentDir, "[fixture]")}`);
    const entry = records[0];
    const first = await connect(entry.socket);
    assert.equal((await exchange(first, "snapshot")).metadata.sessionId, entry.sessionId);
    const lease = await exchange(first, "acquire");
    assert.equal(lease.ok, true);
    assert.equal((await exchange(first, "prompt", { token: lease.token, delivery: "immediate", text: "fixture hello" })).ok, true);
    first.destroy();
    child.stdin.write(JSON.stringify({ type: "get_state", id: "state" }) + "\n");
    await wait(3500);
    const second = await connect(entry.socket);
    assert.equal((await exchange(second, "snapshot")).metadata.sessionId, entry.sessionId);
    const next = await exchange(second, "acquire");
    assert.equal(next.ok, true);
    second.destroy();
    assert.equal(child.exitCode, null);
    assert.ok(output.includes('"id":"state"'), "Pi RPC state request must still work");
    const history = await readFile(entry.sessionFile!, "utf8");
    assert.ok(history.includes("fixture hello"), "Pi received the socket prompt in its own session file");
    assert.ok(history.includes("echo: fixture hello"), "The credential-free provider responded to the socket prompt");
    child.stdin.write(JSON.stringify({ type: "new_session", id: "replacement" }) + "\n");
    let replacement: Awaited<ReturnType<typeof discover>> = [];
    for (let attempt = 0; attempt < 50; attempt++) {
      await wait(100);
      try { replacement = await discover(join(agentDir, "roampi")); } catch { /* replacement in progress */ }
      if (replacement.length === 1 && replacement[0].sessionId !== entry.sessionId) break;
    }
    assert.equal(replacement.length, 1, "session replacement must leave one live socket");
    assert.notEqual(replacement[0].sessionId, entry.sessionId, "Pi session identity must change");
    assert.equal(replacement[0].pid, entry.pid, "Pi process must survive session replacement");
    assert.ok((await readFile(entry.sessionFile!, "utf8")).includes("fixture hello"), "replacement preserves prior Pi history");
    child.kill("SIGKILL");
    await new Promise((resolve) => child.once("exit", resolve));
    assert.equal((await discover(join(agentDir, "roampi"))).length, 0, "discovery rejects the crashed process");
    assert.ok((await readFile(entry.sessionFile!, "utf8")).includes("fixture hello"), "crash keeps Pi history");
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
      await new Promise((resolve) => child.once("exit", resolve));
    }
    await rm(agentDir, { recursive: true, force: true });
  }
});
