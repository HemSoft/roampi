import { randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, readFile, readdir, rename, unlink, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";
import { createConnection } from "node:net";

export const VERSION = 1;
export const MAX_FRAME = 32 * 1024;
export const MAX_REGISTRY = 8 * 1024;
export const MAX_CLIENTS = 16;
export const MAX_PENDING_BYTES = 256 * 1024;

export type Phase = "idle" | "working" | "waitingForApproval";
export type Mode = "tui" | "rpc" | "json" | "print";
export interface Registry {
  version: 1;
  runId: string;
  pid: number;
  processStart: string;
  sessionId: string;
  sessionFile: string | null;
  cwd: string;
  sessionName: string | null;
  mode: Mode;
  model: string | null;
  thinkingLevel: string | null;
  state: Phase;
  socket: string;
  updatedAt: string;
}

export function runtimeDir(agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent")): string {
  return join(agentDir, "roampi");
}

// ps reports the OS process birth time rather than the extension load time. PID alone is never identity.
export function processStart(pid: number): string | null {
  if (!Number.isSafeInteger(pid) || pid < 1) return null;
  const result = spawnSync("ps", ["-p", String(pid), "-o", "lstart="], { encoding: "utf8", timeout: 2000 });
  const start = result.status === 0 ? result.stdout.trim() : "";
  return start && start.length <= 80 ? start : null;
}

export function live(entry: Registry, currentStart = processStart(entry.pid)): boolean {
  return !!currentStart && entry.processStart === currentStart;
}

export async function privateDirectory(path: string): Promise<void> {
  await mkdir(path, { mode: 0o700, recursive: true });
  await validatePrivateDirectory(path);
  const stat = await lstat(path);
  if ((stat.mode & 0o777) !== 0o700) await chmod(path, 0o700);
}

async function validatePrivateDirectory(path: string): Promise<void> {
  const stat = await lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0) {
    throw new Error("RoamPi runtime directory must be an owner-only real directory");
  }
}

export async function publishRegistry(dir: string, entry: Registry): Promise<void> {
  const destination = join(dir, `${entry.runId}.json`);
  const temporary = join(dir, `.${entry.runId}.${randomUUID()}.tmp`);
  const bytes = JSON.stringify(entry);
  if (Buffer.byteLength(bytes) > MAX_REGISTRY) throw new Error("Registry metadata exceeds limit");
  await writeFile(temporary, bytes, { encoding: "utf8", mode: 0o600, flag: "wx" });
  try {
    await rename(temporary, destination);
  } catch (error) {
    await unlink(temporary).catch(() => {});
    throw error;
  }
}

async function respondsAs(entry: Registry): Promise<boolean> {
  try {
    const stat = await lstat(entry.socket);
    if (!stat.isSocket() || stat.uid !== process.getuid?.() || (stat.mode & 0o077)) return false;
  } catch { return false; }
  return new Promise((resolve) => {
    const socket = createConnection(entry.socket);
    const framer = new Framer();
    let settled = false;
    const finish = (value: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => finish(false), 500);
    socket.on("connect", () => socket.write(frame({ version: VERSION, id: "discovery", type: "snapshot" })));
    socket.on("data", (data) => {
      try {
        const response = framer.push(data)[0] as { metadata?: Registry } | undefined;
        if (response) finish(response.metadata?.runId === entry.runId && response.metadata?.processStart === entry.processStart);
      } catch { finish(false); }
    });
    socket.on("error", () => finish(false));
    socket.on("close", () => finish(false));
  });
}

export async function discover(dir: string): Promise<Registry[]> {
  try { await validatePrivateDirectory(dir); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
  const entries: Registry[] = [];
  let names: string[];
  try { names = await readdir(dir); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
  for (const file of names.slice(0, 256)) {
    if (!/^[a-f0-9-]{36}\.json$/.test(file)) continue;
    try {
      const path = join(dir, file);
      const stat = await lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0 || stat.size > MAX_REGISTRY) continue;
      const value: unknown = JSON.parse(await readFile(path, "utf8"));
      if (!value || typeof value !== "object") continue;
      const entry = value as Registry;
      if (entry.version !== VERSION || `${entry.runId}.json` !== file || !Number.isSafeInteger(entry.pid) ||
          typeof entry.processStart !== "string" || typeof entry.socket !== "string" ||
          typeof entry.sessionId !== "string" || typeof entry.cwd !== "string") continue;
      // The socket challenge prevents a reused PID with the same displayed ps second
      // from reviving a stale registry entry.
      if (live(entry) && await respondsAs(entry)) entries.push(entry);
    } catch { /* An incomplete, corrupt, or removed record is not a live session. */ }
  }
  return entries;
}

export class Framer {
  private pending = Buffer.alloc(0);
  push(chunk: Buffer): unknown[] {
    const frames: unknown[] = [];
    let offset = 0;
    while (offset < chunk.length) {
      const newline = chunk.indexOf(10, offset);
      const end = newline < 0 ? chunk.length : newline;
      const bytes = this.pending.length + end - offset;
      if (bytes + (newline < 0 ? 0 : 1) > MAX_FRAME || (newline < 0 && bytes >= MAX_FRAME)) {
        throw new Error("frame_too_large");
      }
      const line = Buffer.concat([this.pending, chunk.subarray(offset, end)]);
      this.pending = Buffer.alloc(0);
      if (newline < 0) { this.pending = line; break; }
      if (!line.length || line.includes(13) || line.includes(0)) throw new Error("invalid_frame");
      // Decoder rejects malformed UTF-8 rather than replacing bytes with U+FFFD.
      try { frames.push(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line))); }
      catch { throw new Error("invalid_json"); }
      if (frames.length > 128) throw new Error("too_many_frames");
      offset = newline + 1;
    }
    return frames;
  }
}

export function frame(value: unknown): Buffer {
  const encoded = Buffer.from(JSON.stringify(value) + "\n");
  if (encoded.length > MAX_FRAME) throw new Error("frame_too_large");
  return encoded;
}
