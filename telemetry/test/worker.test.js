// Tests of the telemetry Worker (telemetry/worker.js), with a stand-in for
// D1 that keeps its rows in memory and knows the Worker's statements.
//
//     node --test telemetry/test/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { beforeEach, test } from "node:test";

import worker, { LIMITS, SQL, clean, expire, resetThrottle } from "../worker.js";

class FakeD1 {
  constructor() {
    this.reports = new Map();
    this.daily = new Map();
    this.down = false;
  }

  prepare(sql) {
    const db = this;
    return {
      bind(...args) {
        return { sql, args, first: () => db.run(sql, args, true), run: () => db.run(sql, args) };
      },
    };
  }

  async batch(statements) {
    for (const statement of statements) await this.run(statement.sql, statement.args);
    return [];
  }

  async run(sql, args, first = false) {
    if (this.down) throw new Error("D1 is away");
    switch (sql) {
      case SQL.count: {
        const key = `${args[0]}|${args[1]}`;
        const count = (this.daily.get(key) ?? 0) + args[2];
        this.daily.set(key, count);
        return first ? { count } : {};
      }
      case SQL.insert: {
        const [id, kind, install, day, seq, cartouche, device, ios, game, name, session, body] = args;
        if (!this.reports.has(id)) {
          this.reports.set(id, { id, kind, install, day, seq, cartouche, device, ios, game, name, session, body });
        }
        return {};
      }
      case SQL.forgetReports:
        for (const [id, row] of this.reports) if (row.install === args[0]) this.reports.delete(id);
        return {};
      case SQL.forgetDaily:
        for (const key of this.daily.keys()) if (key.startsWith(`${args[0]}|`)) this.daily.delete(key);
        return {};
      case SQL.expireReports:
        for (const [id, row] of this.reports) if (row.day < args[0]) this.reports.delete(id);
        return {};
      case SQL.expireDaily:
        for (const key of this.daily.keys()) if (key.split("|")[1] < args[0]) this.daily.delete(key);
        return {};
      default:
        throw new Error(`a statement the Worker does not make: ${sql}`);
    }
  }
}

const NOW = Date.UTC(2026, 10, 10, 7, 30);
const INSTALL = "8c1f6c2e-7a2f-4e19-8c3d-2f6a9b0e1d7c";
let counter = 0;
const uuid = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;

const context = {
  install: INSTALL,
  cartouche: "0.10.0",
  device: "iPhone19,4",
  ios: "27.3",
  language: "fr",
  memoryLimitMiB: 6143,
  increasedMemoryLimit: true,
};

function sessionReport(extra = {}) {
  return {
    schema: 1,
    kind: "session",
    id: uuid(),
    session: uuid(),
    seq: 7,
    ...context,
    game: "0400C3F00006E000",
    gameVersion: "1.0.0",
    nxnative: "6c3aeb3d70a1",
    nxnativeChanged: false,
    settings: { DM_OPMODE: "0", DM_RENDER_SCALE: "1.0" },
    minutes: 35.2,
    reader: 1,
    frames: 120000,
    fps: { median: 59.9, low5: 52 },
    targetFps: 60,
    frameMs: { p50: 16.67, p95: 18.9, p99: 33.4 },
    gpuMs: { p50: 9.8, p95: 14.2 },
    overTargetPercent: 2.4,
    droppedPercent: 1.8,
    stutters: { count: 108, perMinute: 3.1, shaders: 76, textures: 21, other: 11 },
    shaderStallMsPerMinute: 210,
    prepare: { seconds: 21.43, lines: 13394 },
    cpu: { watts: 4.1, percent: 230, performanceCoresPercent: 85 },
    gpuBusyMsPerSecond: 610,
    thermal: { nominal: 18, fair: 9, serious: 8.2, critical: 0, seriousAfterMinutes: 24 },
    lowPowerMinutes: 0,
    memory: { peakMiB: 4813, exactPeak: false, gpuPeakMiB: 2910, lowestHeadroomMiB: 1330 },
    upscaler: { kind: "metalfx", gpuMs: 1.2 },
    audioUnderrunsPerMinute: 0.2,
    display: { tv: false, foldSplit: false },
    dlc: true,
    end: { kind: "crash", signal: 11, pc: "main+0x1a2b3c", lr: "main+0x1a2b00" },
    ...extra,
  };
}

function eventReport(extra = {}) {
  return {
    schema: 1,
    kind: "event",
    id: uuid(),
    seq: 8,
    ...context,
    name: "game.installed",
    game: "0400C3F00006E000",
    fields: { version: "1.0.0", nxnative: "6c3aeb3d70a1", fromStorage: true, sizeMiB: 19456 },
    ...extra,
  };
}

function post(path, body, headers = {}) {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  return new Request(`https://telemetry.example.workers.dev${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.7", ...headers },
    body: text,
  });
}

let db;
let env;
beforeEach(() => {
  db = new FakeD1();
  env = { DB: db };
  resetThrottle();
});

test("keeps a session and an event as they came, with the day received", async () => {
  const session = sessionReport();
  const event = eventReport();
  const response = await worker.fetch(post("/v1/reports", { reports: [session, event] }), env, {}, NOW);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { accepted: 2, refused: 0 });
  const row = db.reports.get(session.id);
  assert.equal(row.kind, "session");
  assert.equal(row.day, "2026-11-10");
  assert.equal(row.game, "0400C3F00006E000");
  assert.equal(row.device, "iPhone19,4");
  assert.equal(row.session, session.session);
  assert.deepEqual(JSON.parse(row.body), session);
  assert.equal(db.reports.get(event.id).name, "game.installed");
  assert.deepEqual(JSON.parse(db.reports.get(event.id).body), event);
});

// The reports as Cartouche makes them, every field of them: the launcher's
// tests check that they are (CartoucheTelemetryReportTests.swift).
const appReports = JSON.parse(readFileSync(new URL("./app-reports.json", import.meta.url), "utf8")).reports;

test("keeps every field of the reports Cartouche makes", async () => {
  for (const report of appReports) assert.deepEqual(JSON.parse(JSON.stringify(clean(report))), report);
  const response = await worker.fetch(post("/v1/reports", { reports: appReports }), env, {}, NOW);
  assert.deepEqual(await response.json(), { accepted: appReports.length, refused: 0 });
  for (const report of appReports) assert.deepEqual(JSON.parse(db.reports.get(report.id).body), report);
});

test("a report sent again is kept once", async () => {
  const session = sessionReport();
  await worker.fetch(post("/v1/reports", { reports: [session] }), env, {}, NOW);
  await worker.fetch(post("/v1/reports", { reports: [session] }), env, {}, NOW);
  assert.equal(db.reports.size, 1);
});

test("fields it does not know, or with values it does not expect, are left out", () => {
  const kept = clean(
    sessionReport({
      email: "someone@example.com",
      settings: { DM_OPMODE: "0", DM_SAVE_DIR: "/var/mobile/Documents", HOME: "x", __proto__: { polluted: true } },
      fps: { median: 59.9, low5: 52, extra: 1 },
      memory: { peakMiB: -5, gpuPeakMiB: 2910 },
      end: { kind: "crash", signal: 11, pc: "/private/var/x+0x10" },
      cpu: { watts: 18446744073.71 },
      upscaler: { kind: "fsr", gpuMs: 1 },
    }),
  );
  assert.equal(kept.email, undefined);
  assert.deepEqual({ ...kept.settings }, { DM_OPMODE: "0" });
  assert.deepEqual(kept.fps, { median: 59.9, low5: 52 });
  assert.deepEqual(kept.memory, { gpuPeakMiB: 2910 });
  assert.deepEqual(kept.end, { kind: "crash", signal: 11 });
  assert.equal(kept.cpu, undefined);
  assert.equal(kept.upscaler, undefined);
  assert.equal({}.polluted, undefined);
});

test("a report without what every report has is refused", async () => {
  const reports = [
    sessionReport({ install: "not-a-number" }),
    sessionReport({ schema: 2 }),
    sessionReport({ minutes: undefined }),
    sessionReport({ session: undefined }),
    eventReport({ name: "Bad Name" }),
    eventReport({ kind: "other" }),
    { ...eventReport(), device: undefined },
    "a string",
    null,
  ];
  const response = await worker.fetch(post("/v1/reports", { reports }), env, {}, NOW);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { accepted: 0, refused: reports.length });
  assert.equal(db.reports.size, 0);
});

test("an event keeps up to 24 fields of short text, numbers and yes or no", () => {
  const fields = {};
  for (let index = 0; index < 30; index += 1) fields[`field${String(index).padStart(2, "0")}`] = index;
  fields.long = "x".repeat(161);
  fields.list = [1, 2];
  fields["not a word"] = "x";
  const kept = clean(eventReport({ fields }));
  assert.equal(Object.keys(kept.fields).length, 24);
  assert.equal(kept.fields.long, undefined);
  assert.equal(kept.fields.list, undefined);
  assert.equal(kept.fields["not a word"], undefined);
});

test("a request that is not a batch of reports is refused", async () => {
  for (const body of ["not json", { reports: "x" }, { reports: Array(26).fill(eventReport()) }, {}]) {
    const response = await worker.fetch(post("/v1/reports", body), env, {}, NOW);
    assert.equal(response.status, 400);
  }
  const large = await worker.fetch(post("/v1/reports", "x".repeat(LIMITS.body + 1)), env, {}, NOW);
  assert.equal(large.status, 413);
  const oversized = sessionReport({ gameVersion: "1.0.0", padding: "x".repeat(LIMITS.report) });
  const response = await worker.fetch(post("/v1/reports", { reports: [oversized] }), env, {}, NOW);
  assert.deepEqual(await response.json(), { accepted: 0, refused: 1 });
});

test("only POST, on its routes", async () => {
  const home = await worker.fetch(new Request("https://telemetry.example.workers.dev/"), env, {}, NOW);
  assert.equal(home.status, 200);
  const get = await worker.fetch(new Request("https://telemetry.example.workers.dev/v1/reports"), env, {}, NOW);
  assert.equal(get.status, 405);
  const missing = await worker.fetch(post("/v1/other", {}), env, {}, NOW);
  assert.equal(missing.status, 404);
});

test("a copy of Cartouche sends at most its daily share", async () => {
  db.daily.set(`${INSTALL}|2026-11-10`, LIMITS.perInstallPerDay - 1);
  const response = await worker.fetch(post("/v1/reports", { reports: [eventReport(), eventReport()] }), env, {}, NOW);
  assert.deepEqual(await response.json(), { accepted: 1, refused: 1 });
});

test("an address that sends too fast waits a minute", async () => {
  let last;
  for (let index = 0; index <= LIMITS.perAddressPerMinute; index += 1) {
    last = await worker.fetch(post("/v1/reports", { reports: [] }), env, {}, NOW);
  }
  assert.equal(last.status, 429);
  assert.equal(last.headers.get("retry-after"), "60");
  const later = await worker.fetch(post("/v1/reports", { reports: [] }), env, {}, NOW + 60000);
  assert.equal(later.status, 200);
});

test("the app tries again later when the database is away", async () => {
  db.down = true;
  const response = await worker.fetch(post("/v1/reports", { reports: [eventReport()] }), env, {}, NOW);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("retry-after"), "3600");
});

test("forgets every report of one copy of Cartouche", async () => {
  const other = { ...eventReport(), install: "11111111-2222-4333-8444-555555555555" };
  await worker.fetch(post("/v1/reports", { reports: [sessionReport(), eventReport(), other] }), env, {}, NOW);
  const response = await worker.fetch(post("/v1/forget", { install: INSTALL }), env, {}, NOW);
  assert.equal(response.status, 200);
  assert.deepEqual([...db.reports.values()].map((row) => row.install), [other.install]);
  assert.equal(db.daily.has(`${INSTALL}|2026-11-10`), false);
  const bad = await worker.fetch(post("/v1/forget", { install: "x" }), env, {}, NOW);
  assert.equal(bad.status, 400);
});

test("reports older than 25 months go", async () => {
  db.reports.set("old", { id: "old", install: INSTALL, day: "2024-10-09" });
  db.reports.set("kept", { id: "kept", install: INSTALL, day: "2024-10-10" });
  db.daily.set(`${INSTALL}|2026-11-07`, 3);
  db.daily.set(`${INSTALL}|2026-11-09`, 3);
  await expire(env, NOW);
  assert.deepEqual([...db.reports.keys()], ["kept"]);
  assert.deepEqual([...db.daily.keys()], [`${INSTALL}|2026-11-09`]);
});
