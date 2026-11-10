// The telemetry dashboard: a Cloudflare Worker of its own, beside the
// telemetry server (../worker.js), that reads the same D1 database and shows
// what it holds on one page (index.html), for the project alone
// (telemetry/README.md#dashboard).
//
// It opens only behind Cloudflare Access: when Access protects the Worker,
// the runtime hands it the signed-in person in ctx.access; with a
// hostname-based Access application instead, it checks the token Access adds
// to each request, Cf-Access-Jwt-Assertion, against the team's keys, when the
// deploy gave it ACCESS_TEAM_DOMAIN and ACCESS_AUD. Without either, every
// request gets a page that says so, and no data. Who may sign in, with their
// Cloudflare account or with GitHub, is the Access policy's to say.
//
// GET /          the page;
// GET /data      the reports of the last ?days=N days (28 by default), as
//                compact rows the page sums up itself, with what the server
//                received today and yesterday, the problems players sent
//                and the database's size.
//
// The reports leave D1 as JSON that D1 itself writes (json_group_array),
// a page of rows at a time, newest first, and go to the browser as they
// come: the Worker never parses them, which keeps it well within the free
// plan's CPU time. Only the first 8 digits of a copy of Cartouche's random
// number go, enough to count iPhones.
//
// No dependency: the Worker is this file and its page, deployed as they are
// by telemetry/deploy.sh, with the catalog's names and covers in the page.

import PAGE from "./index.html";

export const SCHEMA = 1;

export const LIMITS = {
  // Days a request may ask for, and those it gets without asking.
  days: 400,
  defaultDays: 28,
  // Reports in one page of D1's answer: a JSON string, which D1 keeps under
  // 2 MB. A page D1 refuses is asked again in halves, down to 200 reports,
  // less than 2 MB even at the server's 8 KiB a report.
  page: 2000,
  smallestPage: 200,
  // Queries of one request, under the free plan's 50 a request: past them,
  // the newest reports go, and the answer says it is cut.
  queries: 45,
  // Issues of the problems' repository the page lists.
  issues: 30,
  // Seconds a key of Access's stays known, and the clock's leeway on a token.
  accessKeys: 3600,
  leeway: 60,
};

// What every report sends, in the order of a row, and its own part last:
// the fields of an event, or SESSION's of a session.
export const REPORT = [
  "kind",
  "day",
  "install",
  "seq",
  "device",
  "ios",
  "cartouche",
  "language",
  "memoryLimitMiB",
  "increasedMemoryLimit",
  "game",
  "name",
  "data",
];

// What a session sends besides, by its path in the report
// (telemetry/README.md#reports): its number first.
export const SESSION = [
  "session",
  "gameVersion",
  "nxnative",
  "nxnativeChanged",
  "settings",
  "minutes",
  "reader",
  "frames",
  "targetFps",
  "fps.median",
  "fps.low5",
  "frameMs.p50",
  "frameMs.p95",
  "frameMs.p99",
  "gpuMs.p50",
  "gpuMs.p95",
  "gpuMs.p99",
  "overTargetPercent",
  "droppedPercent",
  "stutters.count",
  "stutters.perMinute",
  "stutters.shaders",
  "stutters.textures",
  "stutters.other",
  "shaderStallMsPerMinute",
  "prepare.seconds",
  "prepare.lines",
  "cpu.watts",
  "cpu.percent",
  "cpu.performanceCoresPercent",
  "gpuBusyMsPerSecond",
  "thermal.nominal",
  "thermal.fair",
  "thermal.serious",
  "thermal.critical",
  "thermal.seriousAfterMinutes",
  "lowPowerMinutes",
  "memory.peakMiB",
  "memory.exactPeak",
  "memory.gpuPeakMiB",
  "memory.lowestHeadroomMiB",
  "guestFile",
  "upscaler.kind",
  "upscaler.gpuMs",
  "audioUnderrunsPerMinute",
  "display.tv",
  "display.foldSplit",
  "dlc",
  "end.kind",
  "end.signal",
  "end.pc",
  "end.lr",
];

// A field of the report, as JSON: `->` keeps its type, a number a number and
// true true, and an object stays one inside json_array.
const field = (path) => `body -> '$.${path}'`;

const sessionPart = SESSION.map((path) => (path === "session" ? "substr(session, 1, 8)" : field(path))).join(", ");

const columns = {
  kind: "kind",
  day: "day",
  install: "substr(install, 1, 8)",
  seq: "seq",
  device: "device",
  ios: "ios",
  cartouche: "cartouche",
  language: field("language"),
  memoryLimitMiB: field("memoryLimitMiB"),
  increasedMemoryLimit: field("increasedMemoryLimit"),
  game: "game",
  name: "name",
  data: `CASE kind WHEN 'session' THEN json_array(${sessionPart}) ELSE ${field("fields")} END`,
};

export const SQL = {
  // The first report of the window: day only grows with rowid, as the
  // server gives each report the day it received it.
  first: "SELECT rowid AS first FROM reports WHERE day >= ?1 ORDER BY day, rowid LIMIT 1",
  // A page of at most ?3 of the window's reports, from the rowid ?1 and
  // below ?2, newest first, as one JSON array; next is the rowid the next
  // page goes below.
  page:
    `SELECT json_group_array(json_array(${REPORT.map((name) => columns[name]).join(", ")})) AS rows, ` +
    "min(r) AS next, count(*) AS n FROM (SELECT rowid AS r, * FROM reports " +
    "WHERE rowid >= ?1 AND rowid < ?2 AND day >= ?4 ORDER BY rowid DESC LIMIT ?3)",
  // What the server took today and yesterday, for each copy's daily cap.
  received: "SELECT day, sum(count) AS reports, count(*) AS installs FROM daily WHERE day >= ?1 GROUP BY day",
  // Problems GitHub does not have yet, and those taken today.
  problems: "SELECT sum(issue IS NULL) AS waiting, sum(day = ?1) AS today FROM problems",
};

// MARK: Cloudflare Access

const TEAM = /^(?:https:\/\/)?([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.cloudflareaccess\.com)?\/?$/i;
const AUD = /^[0-9a-f]{32,128}$/i;

/** The team's address, https://<team>.cloudflareaccess.com, from its name
 * or its address; undefined for anything else. */
export function teamDomain(value) {
  const found = typeof value === "string" ? TEAM.exec(value.trim()) : null;
  return found ? `https://${found[1].toLowerCase()}.cloudflareaccess.com` : undefined;
}

const bytes = (base64url) => {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
};
const decoded = (part) => JSON.parse(new TextDecoder().decode(bytes(part)));

// The keys each team signs with, as Access serves them, kept in this
// instance's memory for an hour, and fetched again for a key not seen yet,
// at most once a minute.
const teamKeys = new Map();

export function forgetAccessKeys() {
  teamKeys.clear();
}

async function accessKeys(team, now, kid) {
  const known = teamKeys.get(team);
  const fresh = known && now - known.at < LIMITS.accessKeys * 1000;
  if (fresh && (known.keys.some((key) => key.kid === kid) || now - known.at < 60000)) return known.keys;
  try {
    const response = await fetch(`${team}/cdn-cgi/access/certs`, { headers: { accept: "application/json" } });
    if (!response.ok) return known?.keys ?? [];
    const answer = await response.json();
    const keys = Array.isArray(answer?.keys) ? answer.keys.filter((key) => key?.kty === "RSA") : [];
    teamKeys.set(team, { at: now, keys });
    return keys;
  } catch {
    return known?.keys ?? [];
  }
}

/** The claims of an Access token TEAM signed for the application AUD, or
 * undefined: another team's, another application's, expired, not yet valid,
 * not signed with one of the team's keys, or not a token. */
export async function verifyAccessToken(token, team, aud, now) {
  if (typeof token !== "string" || token.length > 16384 || !team || !aud) return undefined;
  const parts = token.split(".");
  if (parts.length !== 3) return undefined;
  let header;
  let claims;
  try {
    header = decoded(parts[0]);
    claims = decoded(parts[1]);
  } catch {
    return undefined;
  }
  if (header?.alg !== "RS256" || typeof header.kid !== "string" || claims === null || typeof claims !== "object") {
    return undefined;
  }
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  const seconds = now / 1000;
  if (claims.iss !== team || !audiences.includes(aud)) return undefined;
  if (typeof claims.exp !== "number" || claims.exp + LIMITS.leeway < seconds) return undefined;
  if (typeof claims.nbf === "number" && claims.nbf - LIMITS.leeway > seconds) return undefined;
  const key = (await accessKeys(team, now, header.kid)).find((candidate) => candidate.kid === header.kid);
  if (!key) return undefined;
  try {
    const verifier = await crypto.subtle.importKey(
      "jwk",
      { kty: "RSA", n: key.n, e: key.e, alg: "RS256", ext: true },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", verifier, bytes(parts[2]), signed);
    return valid ? claims : undefined;
  } catch {
    return undefined;
  }
}

/** Who Cloudflare Access signed in for this request, as { email }, or
 * undefined when Access did not: then the dashboard shows nothing. */
export async function viewer(request, env, ctx, now) {
  if (ctx?.access) {
    let identity;
    try {
      identity = await ctx.access.getIdentity();
    } catch {
      identity = undefined;
    }
    return { email: typeof identity?.email === "string" ? identity.email : null };
  }
  const team = teamDomain(env?.ACCESS_TEAM_DOMAIN);
  const aud = typeof env?.ACCESS_AUD === "string" && AUD.test(env.ACCESS_AUD.trim()) ? env.ACCESS_AUD.trim() : undefined;
  const token = request.headers.get("cf-access-jwt-assertion");
  if (!team || !aud || !token) return undefined;
  const claims = await verifyAccessToken(token, team, aud, now);
  return claims ? { email: typeof claims.email === "string" ? claims.email : null } : undefined;
}

// MARK: Problems

const REPOSITORY = /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/;

// The repository's issues without their bodies, which hold the reports and
// can weigh 60 KB each: GraphQL gives only the fields asked for.
const ISSUES = `query ($owner: String!, $name: String!, $count: Int!) {
  repository(owner: $owner, name: $name) {
    open: issues(states: OPEN) { totalCount }
    closed: issues(states: CLOSED) { totalCount }
    issues(first: $count, orderBy: { field: CREATED_AT, direction: DESC }) {
      nodes { number title state createdAt closedAt url comments { totalCount } labels(first: 5) { nodes { name } } }
    }
  }
}`;

/** The problems players sent, as GitHub has them in PROBLEMS_REPOSITORY;
 * undefined without its token. */
export async function problemsOnGitHub(env) {
  const repository = env.PROBLEMS_REPOSITORY;
  if (!env.PROBLEMS_TOKEN || typeof repository !== "string" || !REPOSITORY.test(repository)) return undefined;
  const [owner, name] = repository.split("/");
  try {
    const response = await fetch("https://api.github.com/graphql", {
      method: "POST",
      headers: {
        accept: "application/json",
        authorization: `Bearer ${env.PROBLEMS_TOKEN}`,
        "content-type": "application/json",
        "user-agent": "cartouche-dashboard",
      },
      body: JSON.stringify({ query: ISSUES, variables: { owner, name, count: LIMITS.issues } }),
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) return { repository, error: `GitHub answered ${response.status}` };
    const found = (await response.json())?.data?.repository;
    if (!found) return { repository, error: "GitHub does not show this repository to the token" };
    const text = (value) => (typeof value === "string" ? value : null);
    return {
      repository,
      open: found.open?.totalCount ?? 0,
      closed: found.closed?.totalCount ?? 0,
      issues: (found.issues?.nodes ?? []).map((issue) => ({
        number: issue?.number ?? null,
        title: text(issue?.title),
        state: text(issue?.state),
        created: text(issue?.createdAt),
        closed: text(issue?.closedAt),
        url: text(issue?.url),
        comments: issue?.comments?.totalCount ?? 0,
        labels: (issue?.labels?.nodes ?? []).map((label) => text(label?.name)).filter(Boolean),
      })),
    };
  } catch {
    return { repository, error: "GitHub could not be reached" };
  }
}

// MARK: Data

const dayOf = (time) => new Date(time).toISOString().slice(0, 10);

/** The days a request asks for: a whole number from 1 to LIMITS.days. */
export function daysAsked(url) {
  const asked = url.searchParams.get("days");
  if (asked === null || !/^\d{1,4}$/.test(asked)) return LIMITS.defaultDays;
  return Math.min(Math.max(Number(asked), 1), LIMITS.days);
}

/** The body of GET /data, as JSON text. */
export async function data(env, who, now, days) {
  const today = dayOf(now);
  const from = dayOf(now - (days - 1) * 86400000);
  const yesterday = dayOf(now - 86400000);
  const github = problemsOnGitHub(env);
  let rowsRead = 0;
  let size = null;
  const note = (result) => {
    rowsRead += result?.meta?.rows_read ?? 0;
    if (typeof result?.meta?.size_after === "number") size = result.meta.size_after;
    return result?.results ?? [];
  };

  const [first, received, problems] = (
    await env.DB.batch([
      env.DB.prepare(SQL.first).bind(from),
      env.DB.prepare(SQL.received).bind(yesterday),
      env.DB.prepare(SQL.problems).bind(today),
    ])
  ).map(note);

  const pages = [];
  let count = 0;
  let truncated = false;
  let queries = 3;
  let perPage = LIMITS.page;
  const lowest = first[0]?.first;
  if (Number.isInteger(lowest)) {
    let below = Number.MAX_SAFE_INTEGER;
    for (;;) {
      if (queries >= LIMITS.queries) {
        truncated = true;
        break;
      }
      queries += 1;
      let page;
      try {
        [page] = note(await env.DB.prepare(SQL.page).bind(lowest, below, perPage, from).all());
      } catch (error) {
        // Too long a string for D1, as long reports can make: the same
        // reports, in smaller pages.
        if (perPage <= LIMITS.smallestPage) throw error;
        perPage = Math.max(LIMITS.smallestPage, Math.floor(perPage / 2));
        continue;
      }
      if (!page?.n || typeof page.rows !== "string") break;
      // A JSON array as D1 wrote it, without its brackets.
      pages.push(page.rows.slice(1, -1));
      count += page.n;
      if (page.n < perPage || !Number.isInteger(page.next)) break;
      below = page.next;
    }
  }

  const day = (wanted) => received.find((row) => row.day === wanted);
  const head = {
    schema: SCHEMA,
    generated: new Date(now).toISOString(),
    today,
    from,
    days,
    viewer: who?.email ?? null,
    columns: { report: REPORT, session: SESSION },
    count,
    truncated,
    received: {
      today: day(today)?.reports ?? 0,
      yesterday: day(yesterday)?.reports ?? 0,
      installsToday: day(today)?.installs ?? 0,
    },
    problems: {
      waiting: problems[0]?.waiting ?? 0,
      today: problems[0]?.today ?? 0,
      github: (await github) ?? null,
    },
    database: { bytes: size, rowsRead },
  };
  const text = JSON.stringify(head);
  return `${text.slice(0, -1)},"reports":[${pages.filter((page) => page !== "").join(",")}]}`;
}

// MARK: Requests

const SECURITY = {
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "x-robots-tag": "noindex, nofollow",
};

function json(status, body) {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: {
      ...SECURITY,
      "content-type": "application/json; charset=utf-8",
      "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    },
  });
}

function nonce() {
  const random = crypto.getRandomValues(new Uint8Array(18));
  return btoa(String.fromCharCode(...random)).replace(/\+/g, "-").replace(/\//g, "_");
}

function html(status, page) {
  const once = nonce();
  return new Response(page.replaceAll("{{nonce}}", once), {
    status,
    headers: {
      ...SECURITY,
      "content-type": "text/html; charset=utf-8",
      "content-security-policy":
        `default-src 'none'; script-src 'nonce-${once}'; style-src 'nonce-${once}'; ` +
        "img-src 'self' data: https://images.igdb.com; connect-src 'self'; " +
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    },
  });
}

// The page of a request Access did not sign in: it says what the dashboard
// waits for, and nothing of what the database holds.
export const CLOSED = `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Tableau de bord fermé</title>
<style nonce="{{nonce}}">
  :root { color-scheme: light dark; --ink: #0b0b0b; --ink-2: #52514e; --plane: #f9f9f7; --card: #fcfcfb; --line: rgba(11, 11, 11, .1); }
  @media (prefers-color-scheme: dark) { :root { --ink: #f0efec; --ink-2: #c3c2b7; --plane: #0d0d0d; --card: #1a1a19; --line: rgba(255, 255, 255, .1); } }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--plane); color: var(--ink);
         font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 34rem; margin: 16px; padding: 28px; background: var(--card); border: 1px solid var(--line); border-radius: 16px; }
  h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
  p { margin: .5rem 0 0; color: var(--ink-2); }
  b { color: var(--ink); font-weight: 600; }
</style>
</head>
<body>
<main>
  <h1>Ce tableau de bord est fermé</h1>
  <p>Il ne s'ouvre que derrière Cloudflare Access, une fois connecté avec un compte que sa règle autorise.</p>
  <p>Pour l'ouvrir : <b>Workers &amp; Pages › cartouche-dashboard › Access › Protect this Worker behind Access</b>, <b>All traffic</b>, puis la règle <b>Cloudflare account</b>.</p>
  <p>Sur ce Worker seulement : le serveur, cartouche-telemetry, reste ouvert aux iPhones, qui n'ont pas de compte pour s'y connecter.</p>
</main>
</body>
</html>
`;

export default {
  async fetch(request, env, ctx, now = Date.now()) {
    const url = new URL(request.url);
    if (request.method !== "GET") return json(405, { error: "GET only" });
    const who = await viewer(request, env, ctx, now);
    if (!who) return url.pathname === "/data" ? json(403, { error: "Cloudflare Access did not sign this request in" }) : html(403, CLOSED);
    if (url.pathname === "/") return html(200, PAGE);
    if (url.pathname === "/data") {
      try {
        return json(200, await data(env, who, now, daysAsked(url)));
      } catch {
        // D1's daily limit, or the database away.
        return json(503, { error: "The database cannot be read right now" });
      }
    }
    return json(404, { error: "not found" });
  },
};
