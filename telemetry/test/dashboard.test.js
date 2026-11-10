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
  assert.equal(game.low5, session.fps.low5);
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

test("the sample data fills every section, and is the same each time", () => {
  const first = M.demo(28, CATALOG, NOW);
  assert.equal(JSON.stringify(first), JSON.stringify(M.demo(28, CATALOG, NOW)));
  assert.equal(first.demo, true);
  const model = M.build(first, CATALOG);
  assert.equal(model.days.length, 28);
  assert.equal(model.totals.iphones, 12);
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
    issues: model.problems.github.issues.length,
  })) {
    assert.ok(value > 0, name);
  }
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
