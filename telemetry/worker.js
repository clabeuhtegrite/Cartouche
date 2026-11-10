// Cartouche's telemetry server: a Cloudflare Worker and its D1 database,
// created in the EU jurisdiction (telemetry/README.md, docs/privacy.md).
//
// POST /v1/reports takes a batch of reports from Cartouche: a report of each
// game session, and Cartouche's own events (launcher/Sources/
// CartoucheTelemetryReport.swift). Each report is checked field by field and
// kept as the server rebuilt it: a field it does not know, or whose value is
// not one it expects, is left out, and a report without the fields every
// report has is refused. The server adds the day it received the report, and
// nothing else: not the time, not the address it came from.
//
// POST /v1/forget deletes every report of one copy of Cartouche, by its
// random number.
//
// POST /v1/problems takes a report a player sends from System › Report a
// problem with Send to Cartouche (launcher/Sources/
// CartoucheProblemReport.swift), and files it as an issue of the project's
// private repository, PROBLEMS_REPOSITORY, with the token PROBLEMS_TOKEN.
// The database keeps it until GitHub has it: one GitHub does not take, or
// one sent before the token is set, is filed by the daily run. Once filed,
// the database keeps only its day and its issue's number, for the daily
// cap, and forgets them two days later.
//
// Every day, reports older than 25 months are deleted, and the problems
// GitHub does not have yet are filed.
//
// No dependency: the Worker is this file, deployed as it is by
// .github/workflows/telemetry.yml.

export const SCHEMA = 1;

export const LIMITS = {
  // One request: a batch of reports.
  body: 64 * 1024,
  // One report, as JSON.
  report: 8 * 1024,
  batch: 25,
  // Reports one copy of Cartouche may send in a day.
  perInstallPerDay: 2000,
  // Requests one address may make in a minute, counted in each Worker
  // instance's memory and never kept.
  perAddressPerMinute: 120,
  // Months a report is kept.
  keptMonths: 25,
  // A problem a player sends: the length of its fields, as JavaScript
  // counts it, which the request's 64 KiB bound anyway.
  problemTitle: 256,
  problemWhat: 16000,
  problemLogs: 60000,
  problemField: 64,
  // Problems one address may send in an hour, counted in each Worker
  // instance's memory and never kept; problems taken in a day, from every
  // address; problems the daily run files.
  problemsPerAddressPerHour: 10,
  problemsPerDay: 50,
  problemsPerRun: 25,
};

export const SQL = {
  count:
    "INSERT INTO daily (install, day, count) VALUES (?1, ?2, ?3) " +
    "ON CONFLICT (install, day) DO UPDATE SET count = count + excluded.count RETURNING count",
  insert:
    "INSERT INTO reports (id, kind, install, day, seq, cartouche, device, ios, game, name, session, body) " +
    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12) ON CONFLICT (id) DO NOTHING",
  forgetReports: "DELETE FROM reports WHERE install = ?1",
  forgetDaily: "DELETE FROM daily WHERE install = ?1",
  expireReports: "DELETE FROM reports WHERE day < ?1",
  expireDaily: "DELETE FROM daily WHERE day < ?1",
  problem: "SELECT issue FROM problems WHERE id = ?1",
  problemsOfDay: "SELECT count(*) AS count FROM problems WHERE day = ?1",
  keepProblem: "INSERT INTO problems (id, day, title, body) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (id) DO NOTHING",
  problemFiled: "UPDATE problems SET issue = ?2, title = '', body = '' WHERE id = ?1",
  waitingProblems: "SELECT id, title, body FROM problems WHERE issue IS NULL ORDER BY day, id LIMIT ?1",
  expireProblems: "DELETE FROM problems WHERE (issue IS NOT NULL AND day < ?1) OR day < ?2",
};

// MARK: Fields

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TITLE = /^[0-9A-F]{16}$/;
const LOCATION = /^[A-Za-z_][A-Za-z0-9_.$]{0,63}\+0x[0-9a-fA-F]{1,16}$/;
const EVENT = /^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*){0,3}$/;
const WORD = /^[a-zA-Z][a-zA-Z0-9]{0,31}$/;

const has = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

const number = (min, max) => (value) =>
  typeof value === "number" && Number.isFinite(value) && value >= min && value <= max ? value : undefined;
const integer = (min, max) => (value) =>
  Number.isInteger(value) && value >= min && value <= max ? value : undefined;
const flag = (value) => (typeof value === "boolean" ? value : undefined);
const text = (pattern) => (value) => (typeof value === "string" && pattern.test(value) ? value : undefined);
const oneOf = (...values) => (value) => (values.includes(value) ? value : undefined);

// The valid fields of an object; undefined when a required one is missing or
// when nothing is left.
const object = (fields, required = []) => (value) => {
  if (!isObject(value)) return undefined;
  const kept = {};
  for (const [key, check] of Object.entries(fields)) {
    if (!has(value, key)) continue;
    const checked = check(value[key]);
    if (checked !== undefined) kept[key] = checked;
  }
  if (!required.every((key) => has(kept, key))) return undefined;
  return Object.keys(kept).length ? kept : undefined;
};

// Up to MAXIMUM entries whose key matches KEY and whose value passes CHECK.
const dictionary = (key, check, maximum) => (value) => {
  if (!isObject(value)) return undefined;
  const kept = Object.create(null);
  let count = 0;
  for (const name of Object.keys(value).sort()) {
    if (count === maximum) break;
    if (!key.test(name)) continue;
    const checked = check(value[name]);
    if (checked === undefined) continue;
    kept[name] = checked;
    count += 1;
  }
  return count ? kept : undefined;
};

const eventValue = (value) => {
  if (typeof value === "string") return value.length <= 160 ? value : undefined;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  return flag(value);
};

const ms = number(0, 1e6);
const minutes = number(0, 1e6);
const mebibytes = integer(0, 1 << 22);

const common = {
  schema: oneOf(SCHEMA),
  kind: oneOf("session", "event"),
  id: text(UUID),
  seq: integer(0, 1e12),
  install: text(UUID),
  cartouche: text(/^\d{1,4}(\.\d{1,4}){1,2}$/),
  device: text(/^[A-Za-z]{2,16}\d{1,4},\d{1,4}$/),
  ios: text(/^\d{1,3}(\.\d{1,3}){0,2}$/),
  language: text(/^[a-z]{2,3}([-_][A-Za-z0-9]{2,8}){0,2}$/),
  memoryLimitMiB: mebibytes,
  increasedMemoryLimit: flag,
};
const required = ["schema", "kind", "id", "seq", "install", "cartouche", "device", "ios"];

const session = object(
  {
    ...common,
    session: text(UUID),
    game: text(TITLE),
    gameVersion: text(/^[0-9A-Za-z._+-]{1,32}$/),
    nxnative: text(/^[0-9a-f]{7,40}$/),
    nxnativeChanged: flag,
    settings: dictionary(/^DM_[A-Z0-9_]{1,40}$/, text(/^[A-Za-z0-9._:+-]{1,32}$/), 40),
    minutes,
    reader: integer(1, 1000),
    frames: integer(0, 1e12),
    fps: object({ median: number(0, 1000), low5: number(0, 1000) }, ["median", "low5"]),
    targetFps: integer(1, 1000),
    frameMs: object({ p50: ms, p95: ms, p99: ms }, ["p50", "p95"]),
    gpuMs: object({ p50: ms, p95: ms, p99: ms }, ["p50", "p95"]),
    overTargetPercent: number(0, 100),
    droppedPercent: number(0, 100),
    stutters: object(
      {
        count: integer(0, 1e9),
        perMinute: number(0, 1e6),
        shaders: integer(0, 1e9),
        textures: integer(0, 1e9),
        other: integer(0, 1e9),
      },
      ["count"],
    ),
    shaderStallMsPerMinute: number(0, 1e7),
    prepare: object({ seconds: number(0, 1e6), lines: integer(0, 1e9) }, ["seconds", "lines"]),
    cpu: object({ watts: number(0, 100), percent: number(0, 1e4), performanceCoresPercent: number(0, 100) }),
    gpuBusyMsPerSecond: number(0, 1000),
    thermal: object(
      { nominal: minutes, fair: minutes, serious: minutes, critical: minutes, seriousAfterMinutes: minutes },
      ["nominal", "fair", "serious", "critical"],
    ),
    lowPowerMinutes: minutes,
    memory: object({ peakMiB: mebibytes, exactPeak: flag, gpuPeakMiB: mebibytes, lowestHeadroomMiB: mebibytes }),
    guestFile: flag,
    upscaler: object({ kind: oneOf("metalfx", "bilinear"), gpuMs: number(0, 1000) }, ["kind", "gpuMs"]),
    audioUnderrunsPerMinute: number(0, 1e6),
    display: object({ tv: flag, foldSplit: flag }),
    dlc: flag,
    end: object(
      {
        kind: oneOf("crash", "boot-failed", "memory-likely", "unknown"),
        signal: integer(1, 128),
        pc: text(LOCATION),
        lr: text(LOCATION),
      },
      ["kind"],
    ),
  },
  [...required, "session", "minutes", "reader"],
);

const event = object(
  {
    ...common,
    name: text(EVENT),
    game: text(TITLE),
    fields: dictionary(WORD, eventValue, 24),
  },
  [...required, "name"],
);

/** The report as the server keeps it, or undefined when it refuses it. */
export function clean(report) {
  if (!isObject(report)) return undefined;
  if (report.kind === "session") {
    const kept = session(report);
    return kept && kept.kind === "session" ? kept : undefined;
  }
  if (report.kind === "event") {
    const kept = event(report);
    return kept && kept.kind === "event" ? kept : undefined;
  }
  return undefined;
}

// MARK: Problems

const REPOSITORY = /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/;

// TEXT without control characters: a line's become spaces; LINES keep
// their line feeds and tabs, and a carriage return becomes a line feed.
const plain = (text, lines) => {
  const unified = text.replace(/\r\n?/g, "\n");
  return lines ? unified.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "") : unified.replace(/[\u0000-\u001f\u007f]/g, " ");
};

// A string of at most MAXIMUM code units, made plain, that says something
// unless it MAY BE BLANK.
const words = (maximum, lines, mayBeBlank = false) => (value) => {
  if (typeof value !== "string" || value.length > maximum) return undefined;
  const kept = plain(value, lines);
  return mayBeBlank || kept.trim() !== "" ? kept : undefined;
};

const problemFields = {
  schema: oneOf(SCHEMA),
  id: text(UUID),
  title: words(LIMITS.problemTitle, false),
  what: words(LIMITS.problemWhat, true, true),
  device: words(LIMITS.problemField, false),
  ios: words(LIMITS.problemField, false),
  version: words(LIMITS.problemField, false),
  logs: words(LIMITS.problemLogs, true, true),
};
const problemRequired = ["schema", "id", "title", "device", "ios", "version"];

/** The problem as the server files it, without control characters, or
 * undefined when it refuses it: a field it knows whose value is not of the
 * form it expects refuses it whole; a field it does not know is left
 * out. */
export function cleanProblem(value) {
  if (!isObject(value)) return undefined;
  const kept = {};
  for (const [key, check] of Object.entries(problemFields)) {
    if (!has(value, key)) continue;
    const checked = check(value[key]);
    if (checked === undefined) return undefined;
    kept[key] = checked;
  }
  return problemRequired.every((key) => has(kept, key)) ? kept : undefined;
}

/** The issue's body, as GitHub writes one of its bug report form's
 * (.github/ISSUE_TEMPLATE/bug_report.yml), which catalog/tools/
 * add_device.py reads too. The logs' fence is longer than any run of
 * backticks in them. */
export function issueBody(problem) {
  const answer = (value) => (value && value.trim() ? value.trim() : "_No response_");
  const logs = problem.logs?.trim() ?? "";
  const longest = Math.max(0, ...(logs.match(/`+/g) ?? []).map((run) => run.length));
  const fence = "`".repeat(Math.max(3, longest + 1));
  return [
    "### What happened",
    "",
    answer(problem.what),
    "",
    "### iPhone or iPad model",
    "",
    answer(problem.device),
    "",
    "### iOS version",
    "",
    answer(problem.ios),
    "",
    "### Cartouche version",
    "",
    answer(problem.version),
    "",
    "### Logs",
    "",
    ...(logs ? [fence + "text", logs, fence] : ["_No response_"]),
    "",
    "_Sent from Cartouche, System › Report a problem._",
  ].join("\n");
}

/** Files an issue of PROBLEMS_REPOSITORY: its number, or undefined when the
 * server has no token or GitHub did not take it. */
async function fileIssue(env, title, body) {
  const repository = env.PROBLEMS_REPOSITORY;
  if (!env.PROBLEMS_TOKEN || typeof repository !== "string" || !REPOSITORY.test(repository)) return undefined;
  try {
    const response = await fetch(`https://api.github.com/repos/${repository}/issues`, {
      method: "POST",
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${env.PROBLEMS_TOKEN}`,
        "content-type": "application/json",
        "user-agent": "cartouche-telemetry",
        "x-github-api-version": "2022-11-28",
      },
      body: JSON.stringify({ title, body }),
    });
    if (response.status !== 201) return undefined;
    const issue = await response.json();
    return Number.isInteger(issue?.number) ? issue.number : undefined;
  } catch {
    return undefined;
  }
}

/** Files the problems GitHub does not have yet, the oldest first, until
 * GitHub refuses one: the next run tries again. */
export async function fileWaiting(env) {
  if (!env.PROBLEMS_TOKEN) return 0;
  const waiting = await env.DB.prepare(SQL.waitingProblems).bind(LIMITS.problemsPerRun).all();
  let filed = 0;
  for (const row of waiting?.results ?? []) {
    const issue = await fileIssue(env, row.title, row.body);
    if (issue === undefined) break;
    await env.DB.prepare(SQL.problemFiled).bind(row.id, issue).run();
    filed += 1;
  }
  return filed;
}

// MARK: Requests

const recent = new Map();
const recentProblems = new Map();

/** Whether ADDRESS made more than MAXIMUM requests in this PERIOD, in
 * milliseconds, as SEEN counts them. Kept only in memory. */
function over(seen, address, now, period, maximum) {
  if (!address) return false;
  const slot = Math.floor(now / period);
  if (seen.size > 10000) seen.clear();
  const known = seen.get(address);
  if (!known || known.slot !== slot) {
    seen.set(address, { slot, count: 1 });
    return false;
  }
  known.count += 1;
  return known.count > maximum;
}

/** Whether ADDRESS made too many requests this minute. */
function throttled(address, now) {
  return over(recent, address, now, 60000, LIMITS.perAddressPerMinute);
}

export function resetThrottle() {
  recent.clear();
  recentProblems.clear();
}

function reply(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

async function readJSON(request) {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > LIMITS.body) return { error: reply(413, { error: "too large" }) };
  const body = await request.text();
  if (body.length > LIMITS.body) return { error: reply(413, { error: "too large" }) };
  try {
    return { value: JSON.parse(body) };
  } catch {
    return { error: reply(400, { error: "not JSON" }) };
  }
}

const today = (now) => new Date(now).toISOString().slice(0, 10);

async function reports(request, env, now) {
  const read = await readJSON(request);
  if (read.error) return read.error;
  const batch = read.value?.reports;
  if (!Array.isArray(batch) || batch.length > LIMITS.batch) {
    return reply(400, { error: "expected up to 25 reports" });
  }
  const day = today(now);
  const accepted = [];
  for (const report of batch) {
    if (JSON.stringify(report).length > LIMITS.report) continue;
    const kept = clean(report);
    if (kept) accepted.push(kept);
  }
  const byInstall = new Map();
  for (const kept of accepted) {
    byInstall.set(kept.install, [...(byInstall.get(kept.install) ?? []), kept]);
  }
  const statements = [];
  try {
    for (const [install, kept] of byInstall) {
      const counted = await env.DB.prepare(SQL.count).bind(install, day, kept.length).first();
      const before = (counted?.count ?? kept.length) - kept.length;
      const room = Math.max(LIMITS.perInstallPerDay - before, 0);
      for (const report of kept.slice(0, room)) {
        statements.push(
          env.DB.prepare(SQL.insert).bind(
            report.id,
            report.kind,
            report.install,
            day,
            report.seq,
            report.cartouche,
            report.device,
            report.ios,
            report.game ?? null,
            report.name ?? null,
            report.session ?? null,
            JSON.stringify(report),
          ),
        );
      }
    }
    if (statements.length) await env.DB.batch(statements);
  } catch {
    // D1's daily limit, or the database away: the app tries again later.
    return reply(503, { error: "unavailable" }, { "retry-after": "3600" });
  }
  return reply(200, { accepted: statements.length, refused: batch.length - statements.length });
}

async function forget(request, env) {
  const read = await readJSON(request);
  if (read.error) return read.error;
  const install = text(UUID)(read.value?.install);
  if (!install) return reply(400, { error: "expected an install" });
  try {
    await env.DB.batch([
      env.DB.prepare(SQL.forgetReports).bind(install),
      env.DB.prepare(SQL.forgetDaily).bind(install),
    ]);
  } catch {
    return reply(503, { error: "unavailable" }, { "retry-after": "3600" });
  }
  return reply(200, { forgotten: true });
}

async function problems(request, env, now) {
  const read = await readJSON(request);
  if (read.error) return read.error;
  const problem = cleanProblem(read.value);
  if (!problem) return reply(400, { error: "not a problem report" });
  if (over(recentProblems, request.headers.get("cf-connecting-ip"), now, 3600000, LIMITS.problemsPerAddressPerHour)) {
    return reply(429, { error: "too many problems from this address" }, { "retry-after": "3600" });
  }
  const day = today(now);
  const body = issueBody(problem);
  try {
    const known = await env.DB.prepare(SQL.problem).bind(problem.id).first();
    // Sent again, after an answer that did not reach the app.
    if (known && known.issue !== null && known.issue !== undefined) return reply(200, { filed: true });
    if (!known) {
      const counted = await env.DB.prepare(SQL.problemsOfDay).bind(day).first();
      if ((counted?.count ?? 0) >= LIMITS.problemsPerDay) {
        return reply(429, { error: "too many problems today" }, { "retry-after": "3600" });
      }
      await env.DB.prepare(SQL.keepProblem).bind(problem.id, day, problem.title, body).run();
    }
  } catch {
    return reply(503, { error: "unavailable" }, { "retry-after": "3600" });
  }
  const issue = await fileIssue(env, problem.title, body);
  // Kept: the daily run files it.
  if (issue === undefined) return reply(202, { kept: true });
  try {
    await env.DB.prepare(SQL.problemFiled).bind(problem.id, issue).run();
  } catch {
    // GitHub has it; the database will forget it with its day.
  }
  return reply(201, { filed: true });
}

/** Deletes the reports older than 25 months, the counts of past days, and
 * the problems filed before yesterday. */
export async function expire(env, now) {
  const cutoff = new Date(now);
  cutoff.setUTCMonth(cutoff.getUTCMonth() - LIMITS.keptMonths);
  // The counts of today and yesterday are all the daily caps read.
  const counted = new Date(now - 2 * 86400000);
  await env.DB.batch([
    env.DB.prepare(SQL.expireReports).bind(cutoff.toISOString().slice(0, 10)),
    env.DB.prepare(SQL.expireDaily).bind(counted.toISOString().slice(0, 10)),
    env.DB.prepare(SQL.expireProblems).bind(counted.toISOString().slice(0, 10), cutoff.toISOString().slice(0, 10)),
  ]);
}

const ROUTES = new Map([
  ["/v1/reports", reports],
  ["/v1/forget", forget],
  ["/v1/problems", problems],
]);

export default {
  async fetch(request, env, context, now = Date.now()) {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/") {
      return new Response("Cartouche telemetry\n", { headers: { "content-type": "text/plain" } });
    }
    const route = ROUTES.get(pathname);
    if (!route) return reply(404, { error: "not found" });
    if (request.method !== "POST") return reply(405, { error: "POST only" }, { allow: "POST" });
    if (throttled(request.headers.get("cf-connecting-ip"), now)) {
      return reply(429, { error: "slow down" }, { "retry-after": "60" });
    }
    return route(request, env, now);
  },

  async scheduled(controller, env, context) {
    context.waitUntil(Promise.all([expire(env, Date.now()), fileWaiting(env)]));
  },
};
