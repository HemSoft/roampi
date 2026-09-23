import { randomUUID } from "node:crypto";
import { createServer, type Server, type Socket } from "node:net";
import { lstat, unlink, chmod } from "node:fs/promises";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Framer, frame, MAX_CLIENTS, MAX_PENDING_BYTES, privateDirectory, processStart, publishRegistry, type Phase, type Registry, runtimeDir, VERSION } from "./protocol.ts";

const LEASE_MS = 15_000;
const GRACE_MS = 3_000;
const DIALOG_MS = 60_000;
const MAX_PROMPT = 16_384;

type Client = { socket: Socket; id: string; subscribed: boolean; framer: Framer };
type Dialog = { id: string; clientId: string; kind: "confirm" | "select" | "input"; options?: string[]; resolve: (value: string | boolean | undefined) => void; timer: NodeJS.Timeout };
const object = (x: unknown): x is Record<string, unknown> => x !== null && typeof x === "object" && !Array.isArray(x);

export class Bridge {
  readonly dir: string;
  readonly runId = randomUUID();
  readonly pid = process.pid;
  readonly started = processStart(process.pid);
  private server?: Server;
  private registry?: Registry;
  private clients = new Set<Client>();
  private controller?: { clientId: string; token: string; until: number };
  private dialog?: Dialog;
  private seq = 0;
  private timer?: NodeJS.Timeout;
  private writes: Promise<void> = Promise.resolve();
  private closed = false;
  private generation = 0;
  private ctx?: ExtensionContext;

  constructor(private readonly pi: Pick<ExtensionAPI, "sendUserMessage">, agentDir?: string) {
    this.dir = runtimeDir(agentDir);
    if (!this.started) throw new Error("Cannot establish process start identity");
  }

  get socketPath(): string { return join(this.dir, `${this.runId}.sock`); }
  get metadata(): Registry | undefined { return this.registry && { ...this.registry }; }

  async start(ctx: ExtensionContext): Promise<void> {
    if (this.server) return;
    this.closed = false;
    this.ctx = ctx;
    await privateDirectory(this.dir);
    // Darwin sockaddr_un is small; do not truncate or fall back to TCP.
    if (Buffer.byteLength(this.socketPath) > 103) throw new Error("RoamPi socket path exceeds Unix limit");
    const server = createServer((socket) => this.connect(socket));
    server.maxConnections = MAX_CLIENTS;
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(this.socketPath, () => { server.off("error", reject); resolve(); });
      });
      await chmod(this.socketPath, 0o600);
      this.server = server;
      this.registry = {
        version: VERSION, runId: this.runId, pid: this.pid, processStart: this.started!,
        sessionId: ctx.sessionManager.getSessionId(), sessionFile: ctx.sessionManager.getSessionFile() ?? null,
        cwd: ctx.cwd, sessionName: ctx.sessionManager.getSessionName() ?? null, mode: ctx.mode,
        model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : null,
        thinkingLevel: ctx.thinkingLevel ?? null, state: ctx.isIdle() ? "idle" : "working",
        socket: this.socketPath, updatedAt: new Date().toISOString(),
      };
      await this.save();
      this.timer = setInterval(() => this.expire(), 1000);
      this.timer.unref();
    } catch (error) {
      server.close();
      await this.removeOwnedSocket();
      this.server = undefined;
      throw error;
    }
  }

  private async save(): Promise<void> {
    if (!this.registry || this.closed) return;
    const entry = { ...this.registry, updatedAt: new Date().toISOString() };
    this.registry.updatedAt = entry.updatedAt;
    this.writes = this.writes.catch(() => {}).then(async () => {
      if (!this.closed) await publishRegistry(this.dir, entry);
    });
    await this.writes;
  }

  async update(ctx: ExtensionContext, state?: Phase): Promise<void> {
    if (!this.registry || this.closed) return;
    this.ctx = ctx;
    const next = this.registry;
    next.sessionId = ctx.sessionManager.getSessionId();
    next.sessionFile = ctx.sessionManager.getSessionFile() ?? null;
    next.sessionName = ctx.sessionManager.getSessionName() ?? null;
    next.model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : null;
    next.thinkingLevel = ctx.thinkingLevel ?? null;
    if (state) next.state = state;
    await this.save();
    this.emit("session", { metadata: next });
  }

  setState(state: Phase): void {
    if (!this.registry || this.closed || this.registry.state === state) return;
    this.registry.state = state;
    void this.save().catch(() => this.close());
    this.emit("session", { state });
  }

  private send(client: Client, message: unknown): void {
    if (client.socket.destroyed) return;
    try {
      if (client.socket.writableLength > MAX_PENDING_BYTES) { client.socket.destroy(); return; }
      client.socket.write(frame(message));
    } catch { client.socket.destroy(); }
  }

  emit(kind: string, data: object = {}): void {
    if (!this.registry || this.closed) return;
    const payload = { version: VERSION, type: "event", seq: ++this.seq, kind, ...data };
    for (const client of this.clients) if (client.subscribed) this.send(client, payload);
  }

  private connect(socket: Socket): void {
    if (this.closed || this.clients.size >= MAX_CLIENTS) { socket.destroy(); return; }
    const client: Client = { socket, id: randomUUID(), subscribed: false, framer: new Framer() };
    this.clients.add(client);
    socket.on("data", (data) => {
      try {
        for (const request of client.framer.push(data)) this.handle(client, request);
      } catch { this.send(client, { version: VERSION, type: "error", code: "invalid_frame" }); socket.destroy(); }
    });
    socket.on("error", () => {});
    socket.on("close", () => {
      this.clients.delete(client);
      if (this.controller?.clientId === client.id) {
        this.controller.until = Math.min(this.controller.until, Date.now() + GRACE_MS);
        this.cancelDialog();
      }
    });
  }

  private owns(client: Client, token: unknown): boolean {
    return typeof token === "string" && !!this.controller && this.controller.clientId === client.id &&
      this.controller.token === token && this.controller.until > Date.now();
  }

  private reply(client: Client, id: unknown, result: object): void {
    this.send(client, { version: VERSION, type: "response", id, ...result });
  }

  private handle(client: Client, value: unknown): void {
    if (!object(value) || value.version !== VERSION || typeof value.type !== "string" ||
        typeof value.id !== "string" || value.id.length > 80) {
      this.send(client, { version: VERSION, type: "error", code: "unsupported_or_invalid" });
      client.socket.destroy();
      return;
    }
    const { id, type } = value;
    if (type === "snapshot") {
      this.reply(client, id, { ok: true, metadata: this.registry, seq: this.seq, controlled: !!this.controller && this.controller.until > Date.now() });
    } else if (type === "subscribe") {
      client.subscribed = true;
      this.reply(client, id, { ok: true, metadata: this.registry, seq: this.seq });
    } else if (type === "acquire") {
      this.expire();
      if (this.controller) { this.reply(client, id, { ok: false, code: "lease_held" }); return; }
      const token = randomUUID();
      this.controller = { clientId: client.id, token, until: Date.now() + LEASE_MS };
      this.reply(client, id, { ok: true, token, leaseMs: LEASE_MS });
      this.emit("control", { held: true });
    } else if (type === "renew") {
      if (!this.owns(client, value.token)) { this.reply(client, id, { ok: false, code: "not_controller" }); return; }
      this.controller!.until = Date.now() + LEASE_MS;
      this.reply(client, id, { ok: true, leaseMs: LEASE_MS });
    } else if (type === "release") {
      if (!this.owns(client, value.token)) { this.reply(client, id, { ok: false, code: "not_controller" }); return; }
      this.cancelDialog(); this.controller = undefined;
      this.reply(client, id, { ok: true }); this.emit("control", { held: false });
    } else if (type === "prompt") {
      if (!this.owns(client, value.token)) { this.reply(client, id, { ok: false, code: "not_controller" }); return; }
      if (typeof value.text !== "string" || !value.text.trim() || Buffer.byteLength(value.text) > MAX_PROMPT ||
          !["immediate", "followUp", "steer"].includes(String(value.delivery))) {
        this.reply(client, id, { ok: false, code: "invalid_prompt" }); return;
      }
      const idle = this.ctx?.isIdle() ?? false;
      if ((idle && value.delivery !== "immediate") || (!idle && value.delivery === "immediate")) {
        this.reply(client, id, { ok: false, code: "wrong_delivery_state" }); return;
      }
      try {
        this.pi.sendUserMessage(value.text, idle ? undefined : { deliverAs: value.delivery as "steer" | "followUp" });
        this.reply(client, id, { ok: true });
      } catch { this.reply(client, id, { ok: false, code: "delivery_failed" }); }
    } else if (type === "interrupt") {
      if (!this.owns(client, value.token)) { this.reply(client, id, { ok: false, code: "not_controller" }); return; }
      try { this.ctx?.abort(); this.reply(client, id, { ok: true }); }
      catch { this.reply(client, id, { ok: false, code: "interrupt_failed" }); }
    } else if (type === "answer") {
      if (!this.owns(client, value.token) || !this.dialog || this.dialog.clientId !== client.id || value.dialogId !== this.dialog.id) {
        this.reply(client, id, { ok: false, code: "not_controller_or_no_dialog" }); return;
      }
      const dialog = this.dialog;
      if (dialog.kind === "confirm" && typeof value.value !== "boolean" ||
          dialog.kind !== "confirm" && value.value !== null && (typeof value.value !== "string" || value.value.length > MAX_PROMPT ||
          dialog.kind === "select" && !dialog.options?.includes(value.value))) {
        this.reply(client, id, { ok: false, code: "invalid_answer" }); return;
      }
      clearTimeout(dialog.timer); this.dialog = undefined;
      dialog.resolve(value.value === null ? undefined : value.value as string | boolean);
      this.reply(client, id, { ok: true });
    } else {
      this.reply(client, id, { ok: false, code: "unsupported_request" });
    }
  }

  // Only cooperating extensions can route dialogs. Pi does not expose the payload
  // or answer channel for arbitrary third-party extension UI calls to another extension.
  async relayDialog(kind: "confirm" | "select" | "input", title: string, detail: string | string[]): Promise<string | boolean | undefined> {
    const holder = [...this.clients].find((client) => client.id === this.controller?.clientId && client.subscribed);
    if (!holder || !this.controller || this.controller.until <= Date.now() || this.dialog) return kind === "confirm" ? false : undefined;
    if (title.length > 256 || JSON.stringify(detail).length > MAX_PROMPT ||
        (kind === "select" && (!Array.isArray(detail) || detail.some((option) => typeof option !== "string")))) {
      return kind === "confirm" ? false : undefined;
    }
    this.setState("waitingForApproval");
    const generation = this.generation;
    const id = randomUUID();
    try {
      return await new Promise<string | boolean | undefined>((resolve) => {
        const timer = setTimeout(() => { this.dialog = undefined; resolve(kind === "confirm" ? false : undefined); }, DIALOG_MS);
        this.dialog = { id, clientId: holder.id, kind, options: kind === "select" ? detail as string[] : undefined, resolve, timer };
        this.send(holder, { version: VERSION, type: "dialog", id, kind, title, detail, timeoutMs: DIALOG_MS });
      });
    } finally {
      if (generation === this.generation) this.setState(this.ctx?.isIdle() ? "idle" : "working");
      this.emit("approval", { completed: true });
    }
  }

  private cancelDialog(): void {
    if (!this.dialog) return;
    const dialog = this.dialog; this.dialog = undefined;
    clearTimeout(dialog.timer);
    dialog.resolve(dialog.kind === "confirm" ? false : undefined);
  }

  private expire(): void {
    if (this.controller && this.controller.until <= Date.now()) {
      this.cancelDialog(); this.controller = undefined;
      this.emit("control", { held: false });
    }
  }

  private async removeOwnedSocket(): Promise<void> {
    try {
      const stat = await lstat(this.socketPath);
      if (stat.isSocket() && stat.uid === process.getuid?.()) await unlink(this.socketPath);
    } catch { /* Already absent. */ }
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.emit("shutdown");
    this.closed = true; this.generation++;
    if (this.timer) clearInterval(this.timer);
    await this.writes.catch(() => {});
    this.cancelDialog();
    for (const client of this.clients) {
      client.socket.end();
      setTimeout(() => client.socket.destroy(), 1000).unref();
    }
    this.clients.clear();
    const server = this.server; this.server = undefined;
    if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
    await this.removeOwnedSocket();
    try {
      const path = join(this.dir, `${this.runId}.json`);
      const stat = await lstat(path);
      if (stat.isFile() && stat.uid === process.getuid?.()) await unlink(path);
    } catch { /* Already absent. */ }
  }
}
