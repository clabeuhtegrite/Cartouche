// Tests of the telemetry dashboard (telemetry/dashboard/): its Worker, which
// opens only behind Cloudflare Access and reads the database a page at a
// time, and what its page sums up (index.html's model), on the reports
// Cartouche makes (app-reports.json) as the telemetry server keeps them, and
// on the page's sample data.
//
//     node --import ./telemetry/test/text-modules.mjs --test telemetry/test/dashboard.test.js

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, test } from "node:test";
import vm from "node:vm";

import dashboard, {
  CLOSED,
  LIMITS,
  REPORT,
  SESSION,
  SQL,
  data,
  daysAsked,
  forgetAccessKeys,
  problemsOnGitHub,
  teamDomain,
  verifyAccessToken,
  viewer,
} from "../dashboard/worker.js";
import telemetry, { resetThrottle } from "../worker.js";

const PAGE = readFileSync(new URL("../dashboard/index.html", import.meta.url), "utf8");
const SCHEMA_SQL = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");
const APP_REPORTS = JSON.parse(readFileSync(new URL("./app-reports.json", import.meta.url), "utf8")).reports;

// The page's model, run as the browser runs it, here.
const MODEL = /<script nonce="\{\{nonce\}\}" id="model">([\s\S]*?)<\/script>/.exec(PAGE)[1];
vm.runInThisContext(MODEL);
const M = globalThis.CartoucheModel;

const NOW = Date.UTC(2026, 10, 10, 9, 30);
const TODAY = "2026-11-10";
const TEAM = "https://cartouche.cloudflareaccess.com";
const AUD = "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2";
const SIGNED_IN = { access: { aud: AUD, getIdentity: async () => ({ email: "player@example.com" }) } };

let realFetch;
beforeEach(() => {
  realFetch = globalThis.fetch;
  forgetAccessKeys();
});
afterEach(() => {
  globalThis.fetch = realFetch;
});

function get(path, headers = {}) {
  return new Request(`https://cartouche-dashboard.example.workers.dev${path}`, { headers });
}

// MARK: A stand-in for D1

// The reports as the page query answers them: newest first, as rows of
// the dashboard's columns, the way D1 writes them (test_dashboard.py
// checks the SQL itself on SQLite).
class PagedD1 {
  constructor(count = 0) {
    this.rows = Array.from({ length: count }, (_, index) => ({
      rowid: index + 1,
      day: TODAY,
      row: ["event", TODAY, "8c1f6c2e", index + 1, "iPhone19,4", "27.3", "0.10.0", "fr", 6143, true, null, "app.opened", { games: 3 }],
    }));
    this.received = [{ day: TODAY, reports: 12, installs: 2 }, { day: "2026-11-09", reports: 30, installs: 3 }];
    this.problems = { waiting: 1, today: 2 };
    this.largest = Infinity;
    this.down = false;
    this.calls = [];
  }

  prepare(sql) {
    return { bind: (...args) => ({ sql, args, all: () => this.answer(sql, args) }) };
  }

  async batch(statements) {
    const answers = [];
    for (const statement of statements) answers.push(await this.answer(statement.sql, statement.args));
    return answers;
  }

  async answer(sql, args) {
    this.calls.push(sql);
    if (this.down) throw new Error("D1 is away");
    switch (sql) {
      case SQL.first: {
        const found = this.rows.filter((row) => row.day >= args[0])[0];
        return { results: found ? [{ first: found.rowid }] : [], meta: { rows_read: found ? 1 : 0 } };
      }
      case SQL.received:
        return { results: this.received.filter((row) => row.day >= args[0]), meta: { rows_read: 5 } };
      case SQL.problems:
        return { results: [this.problems], meta: { rows_read: 3, size_after: 524288 } };
      case SQL.page: {
        const [lowest, below, size, from] = args;
        if (size > this.largest) throw new Error("D1_ERROR: string or blob too big: SQLITE_TOOBIG");
        const page = this.rows
          .filter((row) => row.rowid >= lowest && row.rowid < below && row.day >= from)
          .sort((a, b) => b.rowid - a.rowid)
          .slice(0, size);
        return {
          results: [{ rows: JSON.stringify(page.map((row) => row.row)), next: page.length ? page[page.length - 1].rowid : null, n: page.length }],
          meta: { rows_read: page.length, size_after: 1048576 },
        };
      }
      default:
        throw new Error(`a statement the dashboard does not make: ${sql}`);
    }
  }
}

// MARK: Cloudflare Access

test("without Cloudflare Access, the page says it is closed and no data leaves", async () => {
  const db = new PagedD1(3);
  const env = { DB: db };
  const page = await dashboard.fetch(get("/"), env, {}, NOW);
  assert.equal(page.status, 403);
  const text = await page.text();
  assert.match(text, /Ce tableau de bord est fermé/);
  assert.doesNotMatch(text, /\{\{nonce\}\}/);
  assert.match(page.headers.get("content-security-policy"), /script-src 'nonce-[A-Za-z0-9_-]{24}'/);
  const answer = await dashboard.fetch(get("/data"), env, {}, NOW);
  assert.equal(answer.status, 403);
  assert.equal(answer.headers.get("content-type"), "application/json; charset=utf-8");
  assert.deepEqual(await answer.json(), { error: "Cloudflare Access did not sign this request in" });
  assert.equal(db.calls.length, 0);
});

test("a header that looks like Access's is not enough", async () => {
  const env = { DB: new PagedD1(1) };
  const forged = await dashboard.fetch(get("/data", { "cf-access-authenticated-user-email": "player@example.com", "cf-access-jwt-assertion": "a.b.c" }), env, {}, NOW);
  assert.equal(forged.status, 403);
});

test("signed in by Access, the page and its data open", async () => {
  const env = { DB: new PagedD1(2) };
  const page = await dashboard.fetch(get("/"), env, SIGNED_IN, NOW);
  assert.equal(page.status, 200);
  const text = await page.text();
  const csp = page.headers.get("content-security-policy");
  const nonce = /script-src 'nonce-([^']+)'/.exec(csp)[1];
  assert.match(csp, new RegExp(`style-src 'nonce-${nonce}'`));
  assert.match(csp, /img-src 'self' data: https:\/\/images\.igdb\.com;/);
  assert.match(csp, /connect-src 'self';/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.equal(text.split(`nonce="${nonce}"`).length - 1, 3);
  assert.doesNotMatch(text, /\{\{nonce\}\}/);
  for (const [name, value] of [["cache-control", "no-store"], ["x-frame-options", "DENY"], ["x-robots-tag", "noindex, nofollow"], ["referrer-policy", "no-referrer"]]) {
    assert.equal(page.headers.get(name), value, name);
  }
  const answer = await dashboard.fetch(get("/data?days=7"), env, SIGNED_IN, NOW);
  assert.equal(answer.status, 200);
  const body = await answer.json();
  assert.equal(body.viewer, "player@example.com");
  assert.equal(body.days, 7);
  assert.equal(body.from, "2026-11-04");
});

test("each page gets a nonce of its own", async () => {
  const env = { DB: new PagedD1() };
  const nonces = new Set();
  for (let index = 0; index < 3; index += 1) {
    const page = await dashboard.fetch(get("/"), env, SIGNED_IN, NOW);
    nonces.add(/'nonce-([^']+)'/.exec(page.headers.get("content-security-policy"))[1]);
  }
  assert.equal(nonces.size, 3);
});

test("Access's identity out of reach still signs in, without an address", async () => {
  const who = await viewer(get("/"), {}, { access: { aud: AUD, getIdentity: async () => { throw new Error("no identity"); } } }, NOW);
  assert.deepEqual(who, { email: null });
});

test("only GET, on the page and its data", async () => {
  const env = { DB: new PagedD1() };
  const post = await dashboard.fetch(new Request("https://cartouche-dashboard.example.workers.dev/data", { method: "POST", body: "{}" }), env, SIGNED_IN, NOW);
  assert.equal(post.status, 405);
  const other = await dashboard.fetch(get("/v1/reports"), env, SIGNED_IN, NOW);
  assert.equal(other.status, 404);
});

test("the team's address, from its name or its address, and nothing else", () => {
  for (const value of ["cartouche", "Cartouche", "cartouche.cloudflareaccess.com", "https://cartouche.cloudflareaccess.com", "https://cartouche.cloudflareaccess.com/", " cartouche "]) {
    assert.equal(teamDomain(value), TEAM, value);
  }
  for (const value of ["", "evil.example.com", "https://cartouche.cloudflareaccess.com.evil.example", "http://cartouche.cloudflareaccess.com", "-cartouche", "car touche", undefined, null, 7]) {
    assert.equal(teamDomain(value), undefined, String(value));
  }
});

// The tokens of Access's: RS256, signed with a key of the team's certs.
const base64url = (value) => Buffer.from(value).toString("base64url");
async function team(kid = "key-1") {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  return { pair, key: { kid, kty: "RSA", alg: "RS256", use: "sig", e: jwk.e, n: jwk.n } };
}
async function token(pair, claims = {}, header = {}) {
  const head = base64url(JSON.stringify({ alg: "RS256", kid: "key-1", typ: "JWT", ...header }));
  const body = base64url(
    JSON.stringify({ iss: TEAM, aud: [AUD], email: "player@example.com", sub: "1", iat: NOW / 1000, nbf: NOW / 1000, exp: NOW / 1000 + 3600, ...claims }),
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${base64url(new Uint8Array(signature))}`;
}
function certs(...keys) {
  const fetched = [];
  globalThis.fetch = async (url) => {
    fetched.push(String(url));
    if (String(url) === `${TEAM}/cdn-cgi/access/certs`) return Response.json({ keys });
    return new Response("", { status: 404 });
  };
  return fetched;
}
const ENV = { ACCESS_TEAM_DOMAIN: "cartouche", ACCESS_AUD: AUD };

test("behind a hostname's Access application, its token signs in", async () => {
  const { pair, key } = await team();
  const fetched = certs(key);
  const env = { ...ENV, DB: new PagedD1(1) };
  const answer = await dashboard.fetch(get("/data", { "cf-access-jwt-assertion": await token(pair) }), env, {}, NOW);
  assert.equal(answer.status, 200);
  assert.equal((await answer.json()).viewer, "player@example.com");
  assert.deepEqual(fetched, [`${TEAM}/cdn-cgi/access/certs`]);
  // The keys stay known.
  await dashboard.fetch(get("/data", { "cf-access-jwt-assertion": await token(pair) }), env, {}, NOW + 1000);
  assert.equal(fetched.length, 1);
});

test("a token of another application, another team, out of its time or not signed by the team is refused", async () => {
  const { pair, key } = await team();
  const other = await team();
  certs(key);
  const refused = [
    await token(pair, { aud: ["0".repeat(64)] }),
    await token(pair, { iss: "https://other.cloudflareaccess.com" }),
    await token(pair, { exp: NOW / 1000 - LIMITS.leeway - 1 }),
    await token(pair, { exp: undefined }),
    await token(pair, { nbf: NOW / 1000 + LIMITS.leeway + 60 }),
    await token(other.pair),
    await token(pair, {}, { alg: "HS256" }),
    await token(pair, {}, { alg: "none" }),
    (await token(pair)).replace(/\.[^.]+\./, `.${base64url(JSON.stringify({ iss: TEAM, aud: [AUD], email: "someone@example.com", exp: NOW / 1000 + 3600 }))}.`),
    "not.a.token",
    "",
    "x".repeat(20000),
  ];
  for (const [index, value] of refused.entries()) {
    assert.equal(await verifyAccessToken(value, TEAM, AUD, NOW), undefined, `token ${index}`);
  }
  assert.ok(await verifyAccessToken(await token(pair, { aud: AUD }), TEAM, AUD, NOW), "aud as a string");
});

test("without the team and the application, a token is not read", async () => {
  const { pair, key } = await team();
  const fetched = certs(key);
  const signed = await token(pair);
  for (const env of [{}, { ACCESS_TEAM_DOMAIN: "cartouche" }, { ACCESS_AUD: AUD }, { ACCESS_TEAM_DOMAIN: "evil.example.com", ACCESS_AUD: AUD }, { ACCESS_TEAM_DOMAIN: "cartouche", ACCESS_AUD: "short" }]) {
    assert.equal(await viewer(get("/", { "cf-access-jwt-assertion": signed }), env, {}, NOW), undefined);
  }
  assert.equal(fetched.length, 0);
});

test("a key the team signs with anew is fetched, at most once a minute", async () => {
  const first = await team("key-1");
  const second = await team("key-2");
  const fetched = certs(first.key);
  assert.ok(await verifyAccessToken(await token(first.pair), TEAM, AUD, NOW));
  const rotated = await token(second.pair, {}, { kid: "key-2" });
  assert.equal(await verifyAccessToken(rotated, TEAM, AUD, NOW + 1000), undefined);
  assert.equal(fetched.length, 1);
  certs(first.key, second.key);
  assert.ok(await verifyAccessToken(rotated, TEAM, AUD, NOW + 61000));
});

test("Access's keys out of reach sign nobody in", async () => {
  const { pair } = await team();
  globalThis.fetch = async () => {
    throw new TypeError("fetch failed");
  };
  assert.equal(await verifyAccessToken(await token(pair), TEAM, AUD, NOW), undefined);
});

// MARK: The data

test("the days asked, from 1 to 400, 28 without asking", () => {
  const days = (query) => daysAsked(new URL(`https://dashboard.example/data${query}`));
  assert.equal(days(""), 28);
  assert.equal(days("?days=7"), 7);
  assert.equal(days("?days=365"), 365);
  assert.equal(days("?days=0"), 1);
  assert.equal(days("?days=9999"), LIMITS.days);
  for (const query of ["?days=", "?days=abc", "?days=-3", "?days=1e3", "?days=12345", "?days=7.5"]) assert.equal(days(query), 28, query);
});

test("the reports go a page at a time, newest first, as D1 wrote them", async () => {
  const db = new PagedD1(4500);
  const text = await data({ DB: db }, { email: "player@example.com" }, NOW, 28);
  const body = JSON.parse(text);
  assert.equal(body.count, 4500);
  assert.equal(body.truncated, false);
  assert.equal(body.reports.length, 4500);
  assert.deepEqual(body.reports.slice(0, 2).map((row) => row[3]), [4500, 4499]);
  assert.equal(body.reports.at(-1)[3], 1);
  assert.deepEqual(body.columns, { report: REPORT, session: SESSION });
  assert.deepEqual(body.received, { today: 12, yesterday: 30, installsToday: 2 });
  assert.deepEqual({ waiting: body.problems.waiting, today: body.problems.today, github: body.problems.github }, { waiting: 1, today: 2, github: null });
  assert.deepEqual(body.database, { bytes: 1048576, rowsRead: 1 + 5 + 3 + 4500 });
  assert.equal(db.calls.filter((sql) => sql === SQL.page).length, 3);
  assert.equal(body.generated, new Date(NOW).toISOString());
});

test("a window without reports sends none", async () => {
  const body = JSON.parse(await data({ DB: new PagedD1(0) }, null, NOW, 28));
  assert.equal(body.count, 0);
  assert.deepEqual(body.reports, []);
  assert.equal(body.viewer, null);
});

test("past the queries of one request, the newest reports go, and the answer says it is cut", async () => {
  const saved = { ...LIMITS };
  try {
    LIMITS.page = 10;
    LIMITS.smallestPage = 2;
    const db = new PagedD1(10 * LIMITS.queries);
    const body = JSON.parse(await data({ DB: db }, null, NOW, 28));
    assert.equal(body.truncated, true);
    assert.equal(body.count, 10 * (LIMITS.queries - 3));
    assert.equal(body.reports[0][3], 10 * LIMITS.queries);
    assert.equal(db.calls.length, LIMITS.queries);
  } finally {
    Object.assign(LIMITS, saved);
  }
});

test("a page too long for D1 comes again in smaller pages, every report once", async () => {
  const db = new PagedD1(2600);
  db.largest = 600;
  const body = JSON.parse(await data({ DB: db }, null, NOW, 28));
  assert.equal(body.count, 2600);
  assert.equal(new Set(body.reports.map((row) => row[3])).size, 2600);
  assert.equal(body.truncated, false);
});

test("the database out of reach, the page is told to try again", async () => {
  const db = new PagedD1(10);
  db.down = true;
  const answer = await dashboard.fetch(get("/data"), { DB: db }, SIGNED_IN, NOW);
  assert.equal(answer.status, 503);
  assert.deepEqual(await answer.json(), { error: "The database cannot be read right now" });
  const tooLong = new PagedD1(10);
  tooLong.largest = 1;
  assert.equal((await dashboard.fetch(get("/data"), { DB: tooLong }, SIGNED_IN, NOW)).status, 503);
});

// MARK: Problems on GitHub

const REPOSITORY = "clabeuhtegrite/cartouche-reports";
const GITHUB_TOKEN = "github_pat_for_the_tests";

test("the problems' issues come from GitHub without their bodies", async () => {
  const asked = [];
  globalThis.fetch = async (url, init) => {
    asked.push({ url: String(url), init });
    return Response.json({
      data: {
        repository: {
          open: { totalCount: 2 },
          closed: { totalCount: 5 },
          issues: { nodes: [{ number: 7, title: "Le jeu se ferme", state: "OPEN", createdAt: "2026-11-10T08:00:00Z", closedAt: null, url: "https://github.com/x/y/issues/7", comments: { totalCount: 1 }, labels: { nodes: [{ name: "bug" }] } }] },
        },
      },
    });
  };
  const found = await problemsOnGitHub({ PROBLEMS_REPOSITORY: REPOSITORY, PROBLEMS_TOKEN: GITHUB_TOKEN });
  assert.deepEqual(found, {
    repository: REPOSITORY,
    open: 2,
    closed: 5,
    issues: [{ number: 7, title: "Le jeu se ferme", state: "OPEN", created: "2026-11-10T08:00:00Z", closed: null, url: "https://github.com/x/y/issues/7", comments: 1, labels: ["bug"] }],
  });
  assert.equal(asked.length, 1);
  assert.equal(asked[0].url, "https://api.github.com/graphql");
  assert.equal(asked[0].init.headers.authorization, `Bearer ${GITHUB_TOKEN}`);
  const query = JSON.parse(asked[0].init.body);
  assert.doesNotMatch(query.query, /\bbody\b/);
  assert.deepEqual(query.variables, { owner: "clabeuhtegrite", name: "cartouche-reports", count: LIMITS.issues });
});

test("without the token, or GitHub away, the page says so and the token never shows", async () => {
  let asked = 0;
  globalThis.fetch = async () => {
    asked += 1;
    return new Response("{}", { status: 401 });
  };
  assert.equal(await problemsOnGitHub({ PROBLEMS_REPOSITORY: REPOSITORY }), undefined);
  assert.equal(await problemsOnGitHub({ PROBLEMS_REPOSITORY: "not a repository", PROBLEMS_TOKEN: GITHUB_TOKEN }), undefined);
  assert.equal(asked, 0);
  const refused = await problemsOnGitHub({ PROBLEMS_REPOSITORY: REPOSITORY, PROBLEMS_TOKEN: GITHUB_TOKEN });
  assert.deepEqual(refused, { repository: REPOSITORY, error: "GitHub answered 401" });
  globalThis.fetch = async () => Response.json({ data: { repository: null } });
  assert.deepEqual(await problemsOnGitHub({ PROBLEMS_REPOSITORY: REPOSITORY, PROBLEMS_TOKEN: GITHUB_TOKEN }), {
    repository: REPOSITORY,
    error: "GitHub does not show this repository to the token",
  });
  globalThis.fetch = async () => {
    throw new TypeError("fetch failed");
  };
  const away = await problemsOnGitHub({ PROBLEMS_REPOSITORY: REPOSITORY, PROBLEMS_TOKEN: GITHUB_TOKEN });
  assert.deepEqual(away, { repository: REPOSITORY, error: "GitHub could not be reached" });
  const body = await data({ DB: new PagedD1(1), PROBLEMS_REPOSITORY: REPOSITORY, PROBLEMS_TOKEN: GITHUB_TOKEN }, null, NOW, 28);
  assert.doesNotMatch(body, new RegExp(GITHUB_TOKEN));
});

// MARK: The page

test("the page's scripts and styles run under its nonce only", () => {
  const tags = PAGE.match(/<(script|style)\b[^>]*>/g);
  for (const tag of tags) {
    if (tag.includes('type="application/json"')) continue;
    assert.match(tag, /nonce="\{\{nonce\}\}"/, tag);
  }
  assert.doesNotMatch(PAGE, /\son[a-z]+="/, "no inline handler, which the policy would block");
  assert.doesNotMatch(PAGE, /<(script|link)\b[^>]*\b(src|href)="https?:/, "no script or style from elsewhere");
  assert.equal(PAGE.split('<script type="application/json" id="catalog">{}</script>').length - 1, 1, "one place for the catalog");
});

test("the page shows every field of a session the Worker sends, in its order", () => {
  assert.deepEqual([...M.SHOWN], SESSION);
  const sample = M.demo(7, {}, NOW);
  assert.deepEqual([...sample.columns.report], REPORT);
});

// A report as the server keeps it, as a row of /data: what the page query
// makes of it on SQLite (test_dashboard.py).
function asRow(report) {
  const item = { ...report, install: report.install.slice(0, 8), day: TODAY };
  if (report.kind === "session") {
    const at = (path) => path.split(".").reduce((value, key) => (value && typeof value === "object" ? value[key] : undefined), report);
    for (const path of SESSION) item[path] = path === "session" ? report.session.slice(0, 8) : at(path);
  }
  return M.compact({ report: REPORT, session: SESSION }, item);
}
function answer(rows, extra = {}) {
  return { schema: 1, today: TODAY, from: "2026-10-14", days: 28, columns: { report: REPORT, session: SESSION }, count: rows.length, reports: rows, ...extra };
}
const CATALOG = {
  games: { "0400C3F00006E000": ["Mario Kart World", "co9abc"], "0100000000010000": ["Super Mario Odyssey", "co1mxf"] },
  aliases: { "0400C3F00006F000": "0400C3F00006E000" },
  devices: { "iPhone19,4": ["A20 Pro", 12] },
};

test("the page sums up the reports Cartouche makes", () => {
  const model = M.build(answer(APP_REPORTS.map(asRow).reverse()), CATALOG);
  const [session] = APP_REPORTS;
  assert.equal(model.totals.iphones, 1);
  assert.equal(model.totals.sessions, 1);
  assert.equal(model.totals.minutes, session.minutes);
  assert.equal(model.totals.cadence, session.fps.median / session.targetFps);
  assert.equal(model.games.length, 1);
  const [game] = model.games;
  assert.equal(game.id, "0400C3F00006E000");
  assert.equal(game.name, "Mario Kart World");
  assert.equal(game.cover, "co9abc");
  assert.equal(game.fps, session.fps.median);
  // The slowest 5% only from the reading of the log that takes pauses out.
  assert.equal(game.low5, session.reader >= M.SLOWEST_READER ? session.fps.low5 : null);
  assert.equal(game.peak, session.memory.peakMiB);
  assert.deepEqual(game.tightest, { peak: session.memory.peakMiB, limit: session.memoryLimitMiB, ratio: session.memory.peakMiB / session.memoryLimitMiB });
  assert.deepEqual(model.memory.byGame.map((item) => [item.id, item.peak, item.limit]), [["0400C3F00006E000", session.memory.peakMiB, session.memoryLimitMiB]]);
  assert.equal(game.build, session.nxnative);
  assert.equal(game.ends.crash, 1);
  assert.deepEqual(model.endings.crashes.map((crash) => [crash.signal, crash.pc, crash.lr, crash.count]), [[11, "main+0x1a2b3c", "main+0x1a2b00", 1]]);
  assert.deepEqual(model.fluidity.frameMs.map((item) => item.value), [session.frameMs.p50, session.frameMs.p95, session.frameMs.p99]);
  assert.deepEqual(model.fluidity.settings.map((item) => item.key), ["DM_OPMODE=0", "DM_RENDER_SCALE=1.0"]);
  assert.equal(model.fluidity.upscaler[0].key, "metalfx");
  assert.deepEqual(model.fluidity.fold, { share: 1, yes: 1, known: 1 });
  assert.deepEqual(model.heat.minutes.map((item) => item.minutes), [18, 9, 8.2, 0]);
  assert.equal(model.heat.watts, session.cpu.watts);
  assert.equal(model.memory.headroom, session.memory.lowestHeadroomMiB);
  assert.deepEqual(model.memory.increased, { share: 1, yes: 1, known: 1 });
  assert.equal(model.installs.count, 1);
  assert.equal(model.installs.size, 19456);
  assert.deepEqual(model.installs.fromStorage, { share: 1, yes: 1, known: 1 });
  assert.deepEqual(model.devices.models.map((item) => item.key), ["iPhone19,4"]);
  assert.deepEqual(model.devices.languages.map((item) => item.key), ["fr"]);
  assert.deepEqual(model.eventNames.map((item) => item.key), ["game.installed"]);
  const day = model.daily.find((item) => item.day === TODAY);
  assert.deepEqual([day.iphones, day.sessions, day.bad], [1, 1, 1]);
  assert.equal(day.cadence, session.fps.median / session.targetFps);
});

test("a session sent again counts once, at its highest seq; a variant counts for its game", () => {
  const [session] = APP_REPORTS;
  const again = { ...session, seq: session.seq + 5, minutes: 50, game: "0400C3F00006F000" };
  const model = M.build(answer([asRow(again), asRow(session)]), CATALOG);
  assert.equal(model.totals.sessions, 1);
  assert.equal(model.totals.minutes, 50);
  assert.equal(model.games[0].id, "0400C3F00006E000");
});

test("Cartouche Builder's Macs are not iPhones", () => {
  const mac = { schema: 1, kind: "event", seq: 1, install: "0b1e2c3d-0000-4000-8000-000000000000", cartouche: "0.2.1", device: "Mac16,12", ios: "26.6", name: "builder.built", game: "0100000000010000", fields: { seconds: 3600, ipaMB: 2100, source: "dump", reasons: "named,shared" } };
  const model = M.build(answer([asRow(mac), ...APP_REPORTS.map(asRow)]), CATALOG);
  assert.equal(model.totals.iphones, 1);
  assert.equal(model.totals.macs, 1);
  assert.equal(model.builder.built.count, 1);
  assert.deepEqual(model.builder.built.reasons.map((item) => item.key), ["named", "shared"]);
  assert.equal(model.builder.built.games[0].name, "Super Mario Odyssey");
  assert.ok(!model.eventNames.some((item) => item.key.startsWith("builder.")));
});

test("the filters scope everything to a game, a model or a version", () => {
  const [session, event] = APP_REPORTS;
  const other = { ...session, session: "0f0f0f0f-0000-4000-8000-000000000000", install: "11111111-2222-4333-8444-555555555555", device: "iPhone18,1", game: "0100000000010000", minutes: 10, end: undefined };
  const rows = answer([asRow(other), asRow(session), asRow(event)]);
  const all = M.build(rows, CATALOG);
  assert.equal(all.totals.iphones, 2);
  assert.deepEqual(all.options.games.map((item) => item.value).sort(), ["0100000000010000", "0400C3F00006E000"]);
  const odyssey = M.build(rows, CATALOG, { game: "0100000000010000" });
  assert.equal(odyssey.totals.sessions, 1);
  assert.equal(odyssey.totals.iphones, 1);
  assert.equal(odyssey.installs.count, 0, "the other iPhone's install is of another game");
  assert.equal(odyssey.endings.ends.ok, 1);
  const model = M.build(rows, CATALOG, { device: "iPhone19,4" });
  assert.deepEqual(model.games.map((game) => game.id), ["0400C3F00006E000"]);
  assert.equal(M.build(rows, CATALOG, { version: "0.9.0" }).totals.reports, 0);
});

test("a game's memory is read against the limit of the iPhone it ran on", () => {
  const [session] = APP_REPORTS;
  const roomy = { ...session, memory: { ...session.memory, peakMiB: 5000 } };
  // In Cartouche's place: its limit is the iPhone's.
  const tight = { ...session, session: "0f0f0f0f-0000-4000-8000-000000000000", install: "11111111-2222-4333-8444-555555555555", memoryLimitMiB: 3376, increasedMemoryLimit: false, memory: { ...session.memory, peakMiB: 3000 }, process: undefined };
  const model = M.build(answer([asRow(roomy), asRow(tight)]), CATALOG);
  const [game] = model.games;
  assert.equal(game.peak, 5000);
  assert.deepEqual(game.tightest, { peak: 3000, limit: 3376, ratio: 3000 / 3376 });
  assert.deepEqual(model.memory.limits.map((item) => [item.key, item.count]), [[3376, 1], [6143, 1]]);
});

test("a game that ran behind the console is read against its process's limit, and one the player quit ended well", () => {
  const [session] = APP_REPORTS;
  const behind = { ...session, process: { ...session.process, limitMiB: 5120, quit: true }, end: { kind: "quit" } };
  const model = M.build(answer([asRow(behind)]), CATALOG);
  const [game] = model.games;
  assert.deepEqual(game.tightest, { peak: session.memory.peakMiB, limit: 5120, ratio: session.memory.peakMiB / 5120 });
  assert.equal(game.ends.ok, 1);
  assert.equal(game.ends.bad, 0);
});

test("errors by version of Cartouche, against its openings, the newest version first", () => {
  const [, event] = APP_REPORTS;
  const opened = (cartouche, seq) => ({ ...event, cartouche, seq, name: "app.opened", game: undefined, fields: { games: 2 } });
  const error = (cartouche, seq) => ({ ...event, cartouche, seq, name: "error", game: undefined, fields: { origin: "storage", error: "NSPOSIXErrorDomain 60", background: true } });
  const rows = [opened("0.9.0", 1), error("0.9.0", 2), opened("0.10.0", 3), opened("0.10.0", 4), error("0.10.0", 5)].map(asRow);
  const model = M.build(answer(rows), CATALOG);
  assert.deepEqual(model.errors.byVersion, [{ version: "0.10.0", errors: 1, opens: 2 }, { version: "0.9.0", errors: 1, opens: 1 }]);
  assert.deepEqual(model.errors.byCode.map((row) => [row.origin, row.error, row.count]), [["storage", "NSPOSIXErrorDomain 60", 2]]);
  assert.deepEqual(["0.9.0", "0.10.0", "0.10.1", "1.0"].sort(M.newestFirst), ["1.0", "0.10.1", "0.10.0", "0.9.0"]);
});

test("the Apple sign-in says how often it goes through, the step it stops at and why", () => {
  const [, event] = APP_REPORTS;
  const failed = (seq, stage, cause, vpn) => ({ ...event, seq, name: "error", game: undefined, fields: { origin: "signIn", error: "SideStore 1", cause, stage, kind: "noDevice", vpn, pairing: true, seconds: 20 } });
  const signedIn = (seq) => ({ ...event, seq, name: "account.signedIn", game: undefined, fields: { seconds: 12, automatic: false } });
  const rows = [failed(1, "device", "device", false), failed(2, "device", "device", false), failed(3, "team", "appleServer", true), signedIn(4)].map(asRow);
  const model = M.build(answer(rows), CATALOG);
  const signIn = model.errors.signIn;
  assert.deepEqual([signIn.succeeded, signIn.failed, signIn.iphones], [1, 3, 1]);
  assert.deepEqual(signIn.byStage.map((row) => [row.key, row.count]), [["device", 2], ["team", 1]]);
  assert.deepEqual(model.errors.byCause.map((row) => [row.key, row.count]), [["device", 2], ["appleServer", 1]]);
  assert.deepEqual(signIn.vpn, { share: 1 / 3, yes: 1, known: 3 });
  assert.deepEqual([signIn.seconds, signIn.secondsOk], [20, 12]);
  assert.deepEqual(model.errors.byCode.map((row) => [row.cause, row.stage, row.kind, row.count]), [["device", "device", "noDevice", 2], ["appleServer", "team", "noDevice", 1]]);
  // An error from before the causes says none.
  const older = M.build(answer([asRow({ ...event, seq: 9, name: "error", game: undefined, fields: { origin: "storage", error: "NSPOSIXErrorDomain 60" } })]), CATALOG);
  assert.deepEqual(older.errors.byCause.map((row) => row.key), ["unknown"]);
});

// MARK: What the page makes of the reports

// Reports of copies of their own, number N (the server keeps the first 8
// characters of an install and of a session).
let serial = 0;
const copy = (n) => `${String(n).padStart(8, "0")}-0000-4000-8000-000000000000`;
function sessionOf(n, fields = {}) {
  serial += 1;
  const [session] = APP_REPORTS;
  return { ...session, install: copy(n), session: `${String(serial).padStart(8, "0")}-1111-4000-8000-000000000000`, seq: serial, end: undefined, ...fields };
}
function eventOf(n, name, fields = {}, extra = {}) {
  serial += 1;
  const [, event] = APP_REPORTS;
  return { ...event, install: copy(n), seq: serial, name, game: undefined, fields, ...extra };
}
function onDay(day, report) {
  const row = asRow(report);
  row[REPORT.indexOf("day")] = day;
  return row;
}
const build = (reports) => M.build(answer(reports.map((report) => (Array.isArray(report) ? report : asRow(report)))), CATALOG);

test("the slowest 5% counts only from the reading of the log that takes pauses out", () => {
  assert.equal(M.SLOWEST_READER, 2);
  // Read before, a pause took this session's slowest 5% down to 12 frames a second.
  const before = sessionOf(1, { reader: 1, fps: { median: 59.9, low5: 12 } });
  const after = sessionOf(2, { reader: 2, fps: { median: 59.9, low5: 50 } });
  const model = build([before, after]);
  const [game] = model.games;
  assert.equal(game.low5, 50);
  assert.equal(game.low5Waiting, 1);
  assert.deepEqual([model.fluidity.low5, model.fluidity.low5Measured, model.fluidity.low5Waiting], [50, 1, 1]);
  assert.equal(game.verdict.status, "playable", "the pause makes no game « with issues »");
  const older = build([before]);
  assert.equal(older.games[0].low5, null);
  assert.equal(older.fluidity.low5, null);
  assert.equal(older.games[0].verdict.status, "playable");
});

test("a game's verdict follows the game sheets' rules, each iPhone counting once", () => {
  const status = (sessions) => {
    const { verdict } = build(sessions).games[0];
    return [verdict.status, verdict.reasons.map((reason) => reason.key)];
  };
  const good = (n, fields = {}) => sessionOf(n, { fps: { median: 59.5, low5: 50 }, reader: 2, ...fields });
  assert.deepEqual(status([good(1), good(2), good(3)]), ["playable", []]);
  // One iPhone that played five slow sessions weighs as much as each of the two others.
  const slow = Array.from({ length: 5 }, () => good(1, { fps: { median: 20, low5: 15 } }));
  assert.deepEqual(status([...slow, good(2), good(3)]), ["playable", []]);
  const verdict = build([...slow, good(2), good(3)]).games[0].verdict;
  assert.deepEqual([verdict.iphones, verdict.sessions, verdict.fps, verdict.low], [3, 7, 59.5, 50]);
  // Below 90 % of the rate the game asks for, or its slowest 5 % below 75 %.
  assert.deepEqual(status([good(1, { fps: { median: 50, low5: 48 } }), good(2, { fps: { median: 52, low5: 48 } })]), ["issues", ["fps"]]);
  assert.deepEqual(status([good(1, { fps: { median: 59, low5: 40 } }), good(2, { fps: { median: 59, low5: 42 } })]), ["issues", ["slowest"]]);
  // One session in ten that ends badly; half of them.
  const crashed = (n) => good(n, { end: { kind: "crash", signal: 11, pc: "main+0x10", lr: "main+0x0" } });
  assert.deepEqual(status([crashed(1), ...Array.from({ length: 9 }, (_, index) => good(2 + index))]), ["issues", ["bad"]]);
  assert.deepEqual(status([crashed(1), crashed(2), good(3), good(4)]), ["boots", ["bad"]]);
  // No frame at all.
  const blank = (n) => sessionOf(n, { fps: undefined, frames: 0, end: { kind: "boot-failed" } });
  assert.deepEqual(status([blank(1), blank(2)]), ["none", ["noFrame"]]);
  assert.equal(M.verdict([]), null);
});

test("the players' journey: a step reached counts those before it, even unsaid", () => {
  const journey = build([
    // 1 opened Cartouche, no more; 2 opened it, and the Apple sign-in failed.
    eventOf(1, "app.opened", { setUp: false, signedIn: false }),
    eventOf(2, "app.opened", { setUp: false, signedIn: false }),
    eventOf(2, "error", { origin: "signIn", cause: "appleServer", stage: "account" }),
    // 3 went all the way, and played on two days.
    eventOf(3, "app.opened", { setUp: true, signedIn: true }),
    eventOf(3, "account.signedIn", { seconds: 12 }),
    eventOf(3, "game.installed", { version: "1.0.0" }, { game: "0400C3F00006E000" }),
    onDay("2026-11-09", sessionOf(3)),
    sessionOf(3),
    // 4 ran a version that said neither its sign-in nor its set-up, and played.
    eventOf(4, "game.installed", {}, { game: "0400C3F00006E000" }),
    sessionOf(4),
    // 5 was installed with the player's own certificate.
    eventOf(5, "app.opened", { setUp: false, signedIn: false, signing: "imported" }),
  ]).journey;
  assert.equal(journey.copies, 5);
  assert.deepEqual(journey.steps.map((step) => [step.key, step.copies]), [["opened", 5], ["signedIn", 3], ["setUp", 2], ["installed", 2], ["played", 2], ["returned", 1]]);
  assert.equal(journey.stuckCopies, 3);
  assert.deepEqual(journey.stuck.map((step) => [step.key, step.copies]), [["opened", 2], ["signedIn", 1], ["setUp", 0], ["installed", 0]]);
  assert.deepEqual(journey.blockers, [{ origin: "signIn", cause: "appleServer", copies: 1 }]);
  assert.equal(journey.neverSignedIn, 1);
});

test("each version says how far its copies got, the newest first", () => {
  const older = { cartouche: "0.11.1" };
  const newer = { cartouche: "0.11.2" };
  const model = build([
    eventOf(1, "app.opened", { setUp: false }, older),
    eventOf(1, "error", { origin: "signIn", cause: "appleServer" }, older),
    eventOf(2, "app.opened", { setUp: true }, older),
    eventOf(2, "account.signedIn", {}, older),
    sessionOf(2, { ...older, end: { kind: "crash", signal: 11, pc: "main+0x10", lr: "main+0x0" } }),
    eventOf(3, "app.opened", { setUp: true }, newer),
    eventOf(3, "account.signedIn", {}, newer),
    sessionOf(3, newer),
  ]);
  assert.deepEqual(model.versions.map((row) => row.version), ["0.11.2", "0.11.1"]);
  const [two, one] = model.versions;
  assert.deepEqual(one.signIn, { ok: 1, failed: 1, copies: 2, okCopies: 1 });
  assert.deepEqual(one.setUp, { share: 0.5, known: 2 });
  assert.deepEqual([one.copies, one.opens, one.players, one.sessions, one.bad, one.errors], [2, 2, 1, 1, 1, 1]);
  assert.deepEqual(one.topError, { origin: "signIn", cause: "appleServer", copies: 1, count: 1 });
  assert.deepEqual([two.copies, two.players, two.bad, two.errors, two.topError], [1, 1, 0, 0, null]);
  // A version picked leaves the others beside it.
  const picked = M.build(answer([eventOf(1, "app.opened", {}, older), eventOf(3, "app.opened", {}, newer)].map(asRow)), CATALOG, { version: "0.11.1" });
  assert.deepEqual(picked.versions.map((row) => row.version), ["0.11.2", "0.11.1"]);
});

test("each game on each model, the most played first", () => {
  const model = build([
    sessionOf(1, { device: "iPhone19,4", reader: 2, fps: { median: 59.9, low5: 55 } }),
    sessionOf(2, { device: "iPhone19,4", reader: 2, fps: { median: 59.5, low5: 55 } }),
    sessionOf(3, { device: "iPhone15,4", fps: undefined, frames: 0, end: { kind: "boot-failed" } }),
    sessionOf(4, { device: "iPhone19,4", game: "0100000000010000", minutes: 5 }),
  ]);
  const { models, games } = model.compatibility;
  assert.deepEqual(models, ["iPhone19,4", "iPhone15,4"]);
  assert.deepEqual(games.map((game) => game.id), ["0400C3F00006E000", "0100000000010000"]);
  assert.deepEqual(games[0].cells.map((cell) => cell && [cell.status, cell.iphones]), [["playable", 2], ["none", 1]]);
  assert.deepEqual(games[1].cells.map((cell) => cell && cell.status), ["playable", null]);
});

test("the settings that change from one session to another come apart from those all share", () => {
  const fluidity = build([
    sessionOf(1, { settings: { DM_OPMODE: "0", DM_RENDER_SCALE: "1.0", DM_LANG: "fr" } }),
    sessionOf(2, { settings: { DM_OPMODE: "1", DM_RENDER_SCALE: "1.0" } }),
  ]).fluidity;
  assert.deepEqual(fluidity.variedSettings.map((item) => [item.key, item.values.length, item.sessions]), [["DM_LANG", 2, 2], ["DM_OPMODE", 2, 2]]);
  assert.deepEqual(fluidity.variedSettings[0].values.find((value) => value.value === null), { value: null, count: 1, installs: null }, "a session without the setting");
  assert.deepEqual(fluidity.sameSettings, ["DM_RENDER_SCALE=1.0"]);
});

test("a measure that only ever says 0, as the GPU's busy time on iOS, says nothing", () => {
  const idle = [sessionOf(1, { gpuBusyMsPerSecond: 0 }), sessionOf(2, { gpuBusyMsPerSecond: 0 })];
  assert.equal(build(idle).heat.gpuBusy, null);
  assert.equal(build([sessionOf(3, { gpuBusyMsPerSecond: 610 }), sessionOf(4, { gpuBusyMsPerSecond: 700 })]).heat.gpuBusy, 655);
});

test("the page opens on the first day with a report, a week at least, within the window", () => {
  const window = { from: "2026-10-14", today: TODAY };
  assert.deepEqual(M.shownDays(window, [{ day: "2026-11-09" }, { day: TODAY }]), M.dayList("2026-11-04", TODAY));
  assert.deepEqual(M.shownDays(window, [{ day: "2026-10-20" }, { day: TODAY }]), M.dayList("2026-10-20", TODAY));
  assert.deepEqual(M.shownDays(window, []), M.dayList("2026-10-14", TODAY));
  assert.deepEqual(M.shownDays({ from: "2026-11-08", today: TODAY }, [{ day: TODAY }]), M.dayList("2026-11-08", TODAY));
  assert.deepEqual(build([onDay("2026-11-09", eventOf(1, "app.opened", {}))]).days, M.dayList("2026-11-04", TODAY));
});

test("an error only the newest version sent is new; one older versions sent is not", () => {
  const signIn = { origin: "signIn", cause: "appleServer", stage: "account", kind: "invalidResponseFormat", error: "SideSign.ServerError 1" };
  const storage = { origin: "storage", cause: "offline", error: "NSPOSIXErrorDomain 60" };
  const model = build([
    eventOf(1, "error", signIn, { cartouche: "0.11.2" }),
    eventOf(2, "error", signIn, { cartouche: "0.11.2" }),
    eventOf(3, "error", storage, { cartouche: "0.11.1" }),
    eventOf(4, "error", storage, { cartouche: "0.11.2" }),
    eventOf(4, "error", storage, { cartouche: "0.11.2" }),
  ]);
  assert.deepEqual(model.errors.byCode.map((row) => [row.origin, row.newIn, row.iphones, row.count, row.versions]), [
    ["storage", null, 2, 3, ["0.11.2", "0.11.1"]],
    ["signIn", "0.11.2", 2, 2, ["0.11.2"]],
  ]);
  // With one version alone, nothing is new.
  assert.equal(build([eventOf(1, "error", signIn, { cartouche: "0.11.2" })]).errors.byCode[0].newIn, null);
});

test("what needs a look comes first, the most serious and the widest first", () => {
  const mac = (n, name, fields) => eventOf(100 + n, name, fields, { device: "Mac16,12", ios: "26.6", cartouche: "0.4.2", game: "0100000000010000" });
  const signIn = { origin: "signIn", cause: "appleServer", stage: "account", kind: "invalidResponseFormat", error: "SideSign.ServerError 1" };
  const crash = { kind: "crash", signal: 6, pc: "__pthread_kill+0x8", lr: "pthread_kill+0x10c" };
  const model = build([
    // Three copies of the newest version stopped at the Apple sign-in, with an error no version sent before.
    ...[1, 2, 3].flatMap((n) => [eventOf(n, "app.opened", { setUp: false }, { cartouche: "0.11.2" }), eventOf(n, "error", signIn, { cartouche: "0.11.2" })]),
    // A game that drew no frame on two iPhones.
    ...[4, 5].map((n) => sessionOf(n, { game: "0100000000010000", fps: undefined, frames: 0 })),
    // The same crash on two iPhones, three sessions that went well, and one at the edge of its memory.
    ...[6, 7].map((n) => sessionOf(n, { end: crash })),
    sessionOf(8),
    sessionOf(9),
    sessionOf(10, { memory: { ...APP_REPORTS[0].memory, peakMiB: 6000 } }),
    // An nxnative commit no Mac could build with.
    mac(1, "builder.failed", { nxnative: "deadbeef00aa", stage: "app build", cause: "app_build" }),
    mac(1, "builder.failed", { nxnative: "deadbeef00aa", stage: "app build", cause: "app_build" }),
    mac(2, "builder.failed", { nxnative: "deadbeef00aa", stage: "app build", cause: "app_build" }),
    mac(2, "builder.built", { nxnative: "0123456789ab", seconds: 1800 }),
  ]);
  assert.deepEqual(model.attention.map((item) => [item.key, item.tone, item.copies]), [
    ["signIn", "critical", 3],
    ["game", "critical", 2],
    ["build", "serious", 2],
    ["crash", "serious", 2],
    ["memory", "warning", 5],
    ["newError", "warning", 3],
  ]);
  const byKey = Object.fromEntries(model.attention.map((item) => [item.key, item]));
  assert.deepEqual([byKey.signIn.cause, byKey.signIn.causeCopies, byKey.signIn.section], ["appleServer", 3, "parcours"]);
  assert.deepEqual([byKey.game.game, byKey.game.status], ["0100000000010000", "none"]);
  assert.deepEqual([byKey.build.commit, byKey.build.failed, byKey.build.stage], ["deadbeef00aa", 3, "app build"]);
  assert.deepEqual([byKey.crash.signal, byKey.crash.pc, byKey.crash.count], [6, "__pthread_kill+0x8", 2]);
  assert.deepEqual([byKey.memory.game, byKey.memory.peak, byKey.memory.limit], ["0400C3F00006E000", 6000, 6143]);
  assert.deepEqual([byKey.newError.version, byKey.newError.origin, byKey.newError.stage, byKey.newError.count], ["0.11.2", "signIn", "account", 3]);
  assert.equal(model.attentionMore, 0);
  // Below the thresholds, nothing.
  assert.deepEqual(build([eventOf(1, "app.opened", {}), sessionOf(1), sessionOf(2)]).attention, []);
});

test("the sample data fills every section, and is the same each time", () => {
  const first = M.demo(28, CATALOG, NOW);
  assert.equal(JSON.stringify(first), JSON.stringify(M.demo(28, CATALOG, NOW)));
  assert.equal(first.demo, true);
  const model = M.build(first, CATALOG);
  assert.equal(model.days.length, 28);
  assert.equal(model.totals.iphones, 16);
  assert.equal(model.builder.macs, 2);
  assert.ok(model.games.length >= 6);
  assert.ok(model.games.some((game) => game.name === "Super Mario Odyssey" && game.cover === "co1mxf"));
  assert.ok(model.games.every((game) => !game.tightest || game.tightest.ratio < 1), "no game past its iPhone's limit");
  for (const [name, value] of Object.entries({
    sessions: model.totals.sessions,
    errors: model.errors.count,
    crashes: model.endings.crashes.length,
    installs: model.installs.count,
    renewals: model.devices.renewals,
    updates: model.devices.updates.length,
    built: model.builder.built.count,
    signedIn: model.errors.signIn.succeeded,
    signInFailures: model.errors.signIn.failed,
    causes: model.errors.byCause.length,
    issues: model.problems.github.issues.length,
    slowest: model.fluidity.low5Measured,
    stuck: model.journey.stuckCopies,
    blockers: model.journey.blockers.length,
    versions: model.versions.length,
    models: model.compatibility.models.length,
    attention: model.attention.length,
    commits: model.builder.byCommit.length,
  })) {
    assert.ok(value > 0, name);
  }
  assert.ok(model.journey.steps.every((step, index) => !index || step.copies <= model.journey.steps[index - 1].copies), "each step holds fewer copies than the one before");
  const year = M.build(M.demo(365, CATALOG, NOW), CATALOG);
  assert.equal(year.days.length, 365);
});

test("the days of the window, across months and years", () => {
  assert.deepEqual(M.dayList("2026-12-30", "2027-01-02"), ["2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"]);
  assert.deepEqual(M.dayList("2026-11-10", "2026-11-10"), ["2026-11-10"]);
});

// MARK: From the app to the page

// With Node's own SQLite, when it has one: the reports Cartouche makes go
// through the telemetry server into the database, and come out of the
// dashboard into the page's sums.
let sqlite;
try {
  sqlite = await import("node:sqlite");
} catch {
  sqlite = undefined;
}

function sqliteD1() {
  const db = new sqlite.DatabaseSync(":memory:");
  db.exec(SCHEMA_SQL);
  const run = (sql, args) => {
    const statement = db.prepare(sql);
    if (/^\s*SELECT/i.test(sql) || /\bRETURNING\b/i.test(sql)) {
      const rows = statement.all(...args).map((row) => ({ ...row }));
      return { results: rows, meta: { rows_read: rows.length, size_after: 65536 } };
    }
    statement.run(...args);
    return { results: [], meta: { size_after: 65536 } };
  };
  const bound = (sql, args) => ({
    sql,
    args,
    bind: (...more) => bound(sql, more),
    all: async () => run(sql, args),
    run: async () => run(sql, args),
    first: async (column) => {
      const row = run(sql, args).results[0] ?? null;
      return column ? (row?.[column] ?? null) : row;
    },
  });
  return {
    prepare: (sql) => bound(sql, []),
    async batch(statements) {
      return statements.map((statement) => run(statement.sql, statement.args));
    },
  };
}

test("from the app to the page, through the telemetry server and the dashboard", { skip: !sqlite && "Node has no node:sqlite" }, async () => {
  resetThrottle();
  const DB = sqliteD1();
  const sent = await telemetry.fetch(
    new Request("https://telemetry.example.workers.dev/v1/reports", {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.7" },
      body: JSON.stringify({ reports: APP_REPORTS }),
    }),
    { DB },
    {},
    NOW,
  );
  assert.deepEqual(await sent.json(), { accepted: 2, refused: 0 });
  const answer = await dashboard.fetch(get("/data"), { DB }, SIGNED_IN, NOW);
  assert.equal(answer.status, 200);
  const body = await answer.json();
  assert.equal(body.count, 2);
  assert.deepEqual(body.received, { today: 2, yesterday: 0, installsToday: 1 });
  assert.deepEqual(body.reports, APP_REPORTS.map(asRow).reverse());
  const model = M.build(body, CATALOG);
  assert.equal(model.games[0].name, "Mario Kart World");
  assert.equal(model.totals.sessions, 1);
  assert.equal(model.installs.count, 1);
});
