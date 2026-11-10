// Tests of the telemetry Worker (telemetry/worker.js), with a stand-in for
// D1 that keeps its rows in memory and knows the Worker's statements.
//
//     node --test telemetry/test/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { beforeEach, test } from "node:test";

import worker, { LIMITS, SQL, clean, cleanProblem, expire, fileWaiting, issueBody, resetThrottle } from "../worker.js";

class FakeD1 {
  constructor() {
    this.reports = new Map();
    this.daily = new Map();
    this.problems = new Map();
    this.down = false;
  }

  prepare(sql) {
    const db = this;
    return {
      bind(...args) {
        return {
          sql,
          args,
          first: () => db.run(sql, args, true),
          run: () => db.run(sql, args),
          all: async () => ({ results: await db.run(sql, args) }),
        };
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
      case SQL.problem: {
        const row = this.problems.get(args[0]);
        return row ? { issue: row.issue } : null;
      }
      case SQL.problemsOfDay:
        return { count: [...this.problems.values()].filter((row) => row.day === args[0]).length };
      case SQL.keepProblem: {
        const [id, day, title, body] = args;
        if (!this.problems.has(id)) this.problems.set(id, { id, day, title, body, issue: null });
        return {};
      }
      case SQL.problemFiled: {
        const row = this.problems.get(args[0]);
        if (row) Object.assign(row, { issue: args[1], title: "", body: "" });
        return {};
      }
      case SQL.waitingProblems:
        return [...this.problems.values()]
          .filter((row) => row.issue === null)
          .sort((a, b) => (a.day + a.id < b.day + b.id ? -1 : 1))
          .slice(0, args[0])
          .map(({ id, title, body }) => ({ id, title, body }));
      case SQL.expireProblems:
        for (const [id, row] of this.problems) {
          if ((row.issue !== null && row.day < args[0]) || row.day < args[1]) this.problems.delete(id);
        }
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

// One report of each kind Cartouche Builder makes on the Mac, events named
// builder.*: its tests check that it makes them so (TelemetryTests.swift).
const builderReports = JSON.parse(readFileSync(new URL("./builder-reports.json", import.meta.url), "utf8")).reports;

test("keeps every field of the reports Cartouche Builder makes", async () => {
  for (const report of builderReports) assert.deepEqual(JSON.parse(JSON.stringify(clean(report))), report);
  const response = await worker.fetch(post("/v1/reports", { reports: builderReports }), env, {}, NOW);
  assert.deepEqual(await response.json(), { accepted: builderReports.length, refused: 0 });
  for (const report of builderReports) assert.deepEqual(JSON.parse(db.reports.get(report.id).body), report);
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

test("what a game's own process wrote behind the console keeps its valid sizes, ten at most", () => {
  const screen = (minute) => ({ minute, width: 874, height: 402, footprintMiB: 1830 });
  const kept = clean(
    sessionReport({
      process: {
        limitMiB: 6143,
        peakMiB: 4813,
        lastAvailableMiB: -1,
        quit: "yes",
        screens: [screen(0), { minute: 1, width: 0, height: 402 }, { width: 874, height: 402 }, "874x402", screen(2.5)],
        pid: 412,
      },
      end: { kind: "quit", signal: 9 },
    }),
  );
  assert.deepEqual(kept.process, { limitMiB: 6143, peakMiB: 4813, screens: [screen(0), screen(2.5)] });
  assert.deepEqual(kept.end, { kind: "quit", signal: 9 });
  const many = clean(sessionReport({ process: { limitMiB: 6143, peakMiB: 4813, screens: Array.from({ length: 12 }, (_, index) => screen(index)) } }));
  assert.deepEqual(many.process.screens, Array.from({ length: 10 }, (_, index) => screen(index)));
  assert.equal(clean(sessionReport({ process: { peakMiB: 4813, quit: true } })).process, undefined);
  assert.equal(clean(sessionReport({ process: { limitMiB: 6143, peakMiB: 4813, screens: [] } })).process.screens, undefined);
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

// MARK: Problems

// GitHub's API as the Worker calls it: each issue it is asked for, and an
// answer that a test may change.
class FakeGitHub {
  constructor() {
    this.issues = [];
    this.status = 201;
    this.down = false;
  }

  async fetch(url, init) {
    if (this.down) throw new TypeError("network connection lost");
    const issue = { url, headers: init.headers, ...JSON.parse(init.body) };
    if (this.status !== 201) return new Response(JSON.stringify({ message: "Bad credentials" }), { status: this.status });
    this.issues.push(issue);
    return new Response(JSON.stringify({ number: this.issues.length }), { status: 201 });
  }
}

const REPOSITORY = "clabeuhtegrite/cartouche-reports";
const TOKEN = "github_pat_for_the_tests";

// The problem as Cartouche sends it: the launcher's tests check that
// Cartouche makes it so (CartoucheProblemReportTests.swift).
const appProblem = JSON.parse(readFileSync(new URL("./app-problem.json", import.meta.url), "utf8"));

function problem(extra = {}) {
  return { ...appProblem, id: uuid(), ...extra };
}

let github;
let realFetch;
function withGitHub() {
  github = new FakeGitHub();
  realFetch = globalThis.fetch;
  globalThis.fetch = (url, init) => github.fetch(url, init);
  env.PROBLEMS_REPOSITORY = REPOSITORY;
  env.PROBLEMS_TOKEN = TOKEN;
}
function withoutGitHub() {
  if (realFetch) globalThis.fetch = realFetch;
  realFetch = undefined;
}

test("files a problem as an issue of the private repository", async () => {
  withGitHub();
  try {
    const sent = problem();
    const response = await worker.fetch(post("/v1/problems", sent), env, {}, NOW);
    assert.equal(response.status, 201);
    assert.deepEqual(await response.json(), { filed: true });
    assert.equal(github.issues.length, 1);
    const [issue] = github.issues;
    assert.equal(issue.url, `https://api.github.com/repos/${REPOSITORY}/issues`);
    assert.equal(issue.headers.authorization, `Bearer ${TOKEN}`);
    assert.equal(issue.headers["user-agent"], "cartouche-telemetry");
    assert.equal(issue.title, sent.title);
    assert.equal(issue.body, issueBody(cleanProblem(sent)));
    // The bug report form's sections, and the measurement add_device.py reads.
    for (const heading of ["### What happened", "### iPhone or iPad model", "### iOS version", "### Cartouche version", "### Logs"]) {
      assert.ok(issue.body.includes(`${heading}\n\n`), heading);
    }
    assert.ok(issue.body.includes("For catalog/devices.json:\n{"));
    // Filed: the database keeps its day and its number only.
    assert.deepEqual(db.problems.get(sent.id), { id: sent.id, day: "2026-11-10", title: "", body: "", issue: 1 });
  } finally {
    withoutGitHub();
  }
});

test("a problem sent again is filed once", async () => {
  withGitHub();
  try {
    const sent = problem();
    await worker.fetch(post("/v1/problems", sent), env, {}, NOW);
    const again = await worker.fetch(post("/v1/problems", sent), env, {}, NOW);
    assert.equal(again.status, 200);
    assert.deepEqual(await again.json(), { filed: true });
    assert.equal(github.issues.length, 1);
  } finally {
    withoutGitHub();
  }
});

test("a problem GitHub does not take is kept, and the daily run files it", async () => {
  withGitHub();
  try {
    github.status = 401;
    const first = problem();
    const response = await worker.fetch(post("/v1/problems", first), env, {}, NOW);
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { kept: true });
    github.status = 201;
    github.down = true;
    const second = problem();
    assert.equal((await worker.fetch(post("/v1/problems", second), env, {}, NOW)).status, 202);
    assert.equal(db.problems.get(first.id).issue, null);
    assert.ok(db.problems.get(first.id).body.includes("### Logs"));

    github.down = false;
    assert.equal(await fileWaiting(env), 2);
    assert.equal(github.issues.length, 2);
    assert.ok(github.issues[0].body.includes("### Logs"));
    assert.equal(db.problems.get(first.id).issue, 1);
    assert.equal(db.problems.get(second.id).issue, 2);
    assert.equal(await fileWaiting(env), 0);
  } finally {
    withoutGitHub();
  }
});

test("without a token, problems wait on the server", async () => {
  const sent = problem();
  const response = await worker.fetch(post("/v1/problems", sent), env, {}, NOW);
  assert.equal(response.status, 202);
  assert.equal(db.problems.get(sent.id).issue, null);
  assert.equal(await fileWaiting(env), 0);
});

test("a problem that is not of the form the server expects is refused", async () => {
  const bad = [
    problem({ schema: 2 }),
    problem({ id: "not-a-number" }),
    // As Swift writes a UUID: the app sends it in lowercase.
    problem({ id: "6F1C2A3B-4D5E-4F60-8A7B-9C0D1E2F3A4B" }),
    problem({ title: " " }),
    problem({ title: "\u0007\n" }),
    problem({ title: "x".repeat(LIMITS.problemTitle + 1) }),
    problem({ device: undefined }),
    problem({ ios: 27 }),
    problem({ logs: "x".repeat(LIMITS.problemLogs + 1) }),
    "a string",
  ];
  for (const sent of bad) {
    const response = await worker.fetch(post("/v1/problems", sent), env, {}, NOW);
    assert.equal(response.status, 400, JSON.stringify(sent).slice(0, 80));
  }
  assert.equal(db.problems.size, 0);
  // A field it does not know is left out; what the player wrote may be empty.
  const kept = cleanProblem(problem({ email: "someone@example.com", what: "" }));
  assert.equal(kept.email, undefined);
  assert.ok(issueBody(kept).startsWith("### What happened\n\n_No response_\n\n"));
});

test("control characters go: a line's become spaces, and lines keep their line feeds", () => {
  const kept = cleanProblem(problem({ title: "Two\nlines\tand a bell\u0007", what: "A bell\u0007\r\nthen\rlines\twith tabs", logs: "550 Not found\r\n\u001b[0m" }));
  assert.equal(kept.title, "Two lines and a bell ");
  assert.equal(kept.what, "A bell\nthen\nlines\twith tabs");
  assert.equal(kept.logs, "550 Not found\n[0m");
});

test("the logs' fence holds logs with backticks", () => {
  const body = issueBody(cleanProblem(problem({ logs: "Error: ```quoted``` and ````more````" })));
  assert.ok(body.includes("\n`````text\nError: ```quoted``` and ````more````\n`````\n"));
});

test("an address sends at most ten problems an hour, and the server takes fifty a day", async () => {
  let last;
  for (let index = 0; index <= LIMITS.problemsPerAddressPerHour; index += 1) {
    last = await worker.fetch(post("/v1/problems", problem()), env, {}, NOW);
  }
  assert.equal(last.status, 429);
  assert.equal(last.headers.get("retry-after"), "3600");
  assert.equal(db.problems.size, LIMITS.problemsPerAddressPerHour);

  for (let index = db.problems.size; index < LIMITS.problemsPerDay; index += 1) {
    const id = uuid();
    db.problems.set(id, { id, day: "2026-11-10", title: "", body: "", issue: index });
  }
  const other = await worker.fetch(post("/v1/problems", problem(), { "cf-connecting-ip": "198.51.100.4" }), env, {}, NOW);
  assert.equal(other.status, 429);
  assert.deepEqual(await other.json(), { error: "too many problems today" });
  const tomorrow = await worker.fetch(post("/v1/problems", problem(), { "cf-connecting-ip": "198.51.100.4" }), env, {}, NOW + 86400000);
  assert.equal(tomorrow.status, 202);
});

test("problems filed before yesterday go, those waiting stay up to 25 months", async () => {
  db.problems.set("filed-old", { id: "filed-old", day: "2026-11-07", title: "", body: "", issue: 1 });
  db.problems.set("filed-yesterday", { id: "filed-yesterday", day: "2026-11-09", title: "", body: "", issue: 2 });
  db.problems.set("waiting", { id: "waiting", day: "2026-01-02", title: "t", body: "b", issue: null });
  db.problems.set("waiting-too-long", { id: "waiting-too-long", day: "2024-10-09", title: "t", body: "b", issue: null });
  await expire(env, NOW);
  assert.deepEqual([...db.problems.keys()], ["filed-yesterday", "waiting"]);
});
