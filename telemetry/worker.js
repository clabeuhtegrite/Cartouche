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
// Every day, reports older than 25 months are deleted.
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

// MARK: Requests

const recent = new Map();

/** Whether ADDRESS made too many requests this minute. Kept only in memory. */
function throttled(address, now) {
  if (!address) return false;
  const minute = Math.floor(now / 60000);
  if (recent.size > 10000) recent.clear();
  const seen = recent.get(address);
  if (!seen || seen.minute !== minute) {
    recent.set(address, { minute, count: 1 });
    return false;
  }
  seen.count += 1;
  return seen.count > LIMITS.perAddressPerMinute;
}

export function resetThrottle() {
  recent.clear();
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

/** Deletes the reports older than 25 months, and the counts of past days. */
export async function expire(env, now) {
  const cutoff = new Date(now);
  cutoff.setUTCMonth(cutoff.getUTCMonth() - LIMITS.keptMonths);
  // The counts of today and yesterday are all the daily cap reads.
  const counted = new Date(now - 2 * 86400000);
  await env.DB.batch([
    env.DB.prepare(SQL.expireReports).bind(cutoff.toISOString().slice(0, 10)),
    env.DB.prepare(SQL.expireDaily).bind(counted.toISOString().slice(0, 10)),
  ]);
}

const ROUTES = new Map([
  ["/v1/reports", reports],
  ["/v1/forget", forget],
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
    context.waitUntil(expire(env, Date.now()));
  },
};
