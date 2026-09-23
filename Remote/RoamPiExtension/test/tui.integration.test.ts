import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { createConnection } from "node:net";
import { discover, frame, Framer } from "../src/protocol.ts";

// BSD script supplies a disposable PTY without opening the developer's Pi UI.
test("interactive Pi publishes the same owner-only bridge on macOS", { skip: process.platform !== "darwin", timeout: 20_000 }, async () => {
  const agentDir = await mkdtemp("/tmp/roampi-tui-");
  const installer = spawn(process.execPath, [join(import.meta.dirname, "../install.mjs"), "--apply", "--agent-dir", agentDir], { stdio: "ignore" });
  assert.equal(await new Promise((resolve) => installer.once("exit", resolve)), 0);
  const child = spawn("python3", [join(import.meta.dirname, "fixtures/spawn_tui.py"), "pi", "--offline", "--no-context-files", "--no-approve", "--no-session",
    "--extension", join(import.meta.dirname, "fixtures/scripted-provider/index.ts"), "--model", "roampi-fixture/scripted"], {
    cwd: agentDir, env: { ...process.env, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1", TERM: "xterm-256color" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let diagnostic = "";
  child.stderr.on("data", (bytes) => { diagnostic = (diagnostic + bytes.toString()).slice(-1200); });
  let pid: number | undefined;
  try {
    let records: Awaited<ReturnType<typeof discover>> = [];
    for (let i = 0; i < 100 && !records.length && child.exitCode === null; i++) {
      await new Promise((resolve) => setTimeout(resolve, 100));
      try { records = await discover(join(agentDir, "roampi")); } catch { /* startup */ }
    }
    assert.equal(records.length, 1, `Pi interactive bridge did not start: ${diagnostic.replaceAll(agentDir, "[fixture]")}`);
    const entry = records[0]; pid = entry.pid;
    assert.equal(entry.mode, "tui");
    const socket = createConnection(entry.socket);
    const response = await new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(Error("socket response timeout")), 2000);
      socket.once("data", (bytes) => { clearTimeout(timer); resolve(new Framer().push(bytes)[0]); });
      socket.once("connect", () => socket.write(frame({ version: 1, type: "snapshot", id: "tui" })));
      socket.once("error", reject);
    });
    assert.equal(response.metadata.sessionId, entry.sessionId);
    socket.destroy();
  } finally {
    if (pid) { try { process.kill(pid, "SIGKILL"); } catch { /* already exited */ } }
    child.kill("SIGTERM");
    await Promise.race([
      new Promise((resolve) => { if (child.exitCode !== null || child.signalCode !== null) resolve(null); else child.once("exit", resolve); }),
      new Promise((resolve) => setTimeout(() => { child.kill("SIGKILL"); resolve(null); }, 1500)),
    ]);
    await rm(agentDir, { recursive: true, force: true });
  }
});
