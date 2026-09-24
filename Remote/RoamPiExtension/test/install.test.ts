import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, lstat, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";

const script = join(import.meta.dirname, "../install.mjs");
const run = (dir: string, apply = false) => spawnSync(process.execPath,
  [script, "--agent-dir", dir, ...(apply ? ["--apply"] : [])], { encoding: "utf8" });

test("preview makes no changes; repeated approved install repairs identical-file permissions", async () => {
  const dir = await mkdtemp("/tmp/roampi-install-");
  try {
    assert.equal(run(dir).status, 0);
    await assert.rejects(lstat(join(dir, "extensions")), { code: "ENOENT" });
    assert.equal(run(dir, true).status, 0);
    const path = join(dir, "extensions", "roampi", "index.ts");
    assert.equal((await lstat(path)).mode & 0o777, 0o600);
    const destination = join(dir, "extensions", "roampi");
    await chmod(path, 0o666);
    await chmod(destination, 0o500);
    assert.equal(run(dir, true).status, 0);
    assert.equal((await lstat(destination)).mode & 0o777, 0o700);
    assert.equal((await lstat(path)).mode & 0o777, 0o600);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
