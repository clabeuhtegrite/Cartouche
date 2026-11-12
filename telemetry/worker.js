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
// POST /v1/games finds on IGDB the cover, the artwork and the genre of a
// game of the player's that Cartouche's catalog does not know, by the name
// its copy gives it (launcher/Sources/CartoucheGameLookup.swift), as
// catalog/tools/igdb_covers.py finds those of the catalog's games, with the
// Twitch application of IGDB_CLIENT_ID and IGDB_CLIENT_SECRET. The answer is
// kept 30 days for that name, and given again to whoever asks for it: never
// who asked.
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
  // A game's name to find on IGDB, as JavaScript counts it.
  lookupName: 128,
  // Names one address may ask for in an hour, counted in each Worker
  // instance's memory and never kept; names the server asks IGDB for in a
  // day, from every address; days an answer is kept and given again.
  lookupsPerAddressPerHour: 60,
  lookupsPerDay: 1000,
  lookupKeptDays: 30,
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
  lookup: "SELECT day, answer FROM lookups WHERE name = ?1",
  lookupsOfDay: "SELECT count(*) AS count FROM lookups WHERE day = ?1",
  keepLookup:
    "INSERT INTO lookups (name, day, answer) VALUES (?1, ?2, ?3) " +
    "ON CONFLICT (name) DO UPDATE SET day = excluded.day, answer = excluded.answer",
  expireLookups: "DELETE FROM lookups WHERE day < ?1",
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

// The first MAXIMUM entries of an array that pass CHECK.
const list = (check, maximum) => (value) => {
  if (!Array.isArray(value)) return undefined;
  const kept = [];
  for (const entry of value.slice(0, maximum)) {
    const checked = check(entry);
    if (checked !== undefined) kept.push(checked);
  }
  return kept.length ? kept : undefined;
};

const eventValue = (value) => {
  if (typeof value === "string") return value.length <= 160 ? value : undefined;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  return flag(value);
};

const ms = number(0, 1e6);
const minutes = number(0, 1e6);
const mebibytes = integer(0, 1 << 22);
const points = integer(1, 10000);

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
        kind: oneOf("crash", "boot-failed", "memory-likely", "quit", "unknown"),
        signal: integer(1, 128),
        pc: text(LOCATION),
        lr: text(LOCATION),
      },
      ["kind"],
    ),
    // What the game's own process wrote, when it ran behind the console.
    process: object(
      {
        limitMiB: mebibytes,
        peakMiB: mebibytes,
        lastAvailableMiB: mebibytes,
        quit: flag,
        screens: list(
          object({ minute: minutes, width: points, height: points, footprintMiB: mebibytes }, ["minute", "width", "height"]),
          10,
        ),
      },
      ["limitMiB", "peakMiB"],
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

// MARK: Games Cartouche does not know

// IGDB (igdb.com, Twitch's game database), asked as catalog/tools/
// igdb_covers.py asks it: among its Nintendo Switch and Nintendo Switch 2
// games, by name, an entry with a cover whose name, or one of its other
// names, is close enough once plain.
export const IGDB = {
  token: "https://id.twitch.tv/oauth2/token",
  api: "https://api.igdb.com/v4/",
  platforms: { switch: "Nintendo Switch", switch2: "Nintendo Switch 2" },
  fields: "fields name,alternative_names.name,platforms,genres,cover.image_id,artworks.image_id;",
  likeness: 0.9,
};

// IGDB's genres, by their IDs, as Cartouche's own (CartoucheText.genre in
// launcher/Sources/CartoucheText.swift), in the order they win when a game
// has several: the more a genre tells of a game, the earlier. Tactical says
// Fire Emblem, where Turn-based strategy also goes to Pokémon, a
// role-playing game. IGDB's Indie tells nothing of the kind.
// catalog/tools/igdb_covers.py has the same list, which its tests check.
export const IGDB_GENRES = [
  [10, "racing"], // Racing
  [14, "sports"], // Sport
  [7, "music"], // Music
  [4, "action"], // Fighting
  [5, "action"], // Shooter
  [11, "strategy"], // Real Time Strategy (RTS)
  [24, "strategy"], // Tactical
  [36, "strategy"], // MOBA
  [13, "simulation"], // Simulator
  [12, "rpg"], // Role-playing (RPG)
  [15, "strategy"], // Strategy
  [16, "strategy"], // Turn-based strategy (TBS)
  [35, "board"], // Card & Board Game
  [9, "puzzle"], // Puzzle
  [26, "puzzle"], // Quiz/Trivia
  [8, "action"], // Platform
  [25, "action"], // Hack and slash/Beat 'em up
  [33, "action"], // Arcade
  [30, "action"], // Pinball
  [31, "adventure"], // Adventure
  [2, "adventure"], // Point-and-click
  [34, "adventure"], // Visual Novel
];

const IMAGE = /^[0-9a-z]{1,40}$/;
const EDITION = /\b(nintendo switch 2 edition|nintendo switch edition|switch 2 edition)\b/g;

/** NAME without accents, marks, punctuation, case or edition words, as
 * igdb_covers.py's plain() makes it. */
export function plainName(name) {
  const text = name
    .replace(/[™®©]/g, "")
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replaceAll("&", " and ")
    .replace(EDITION, " ");
  return text.replace(/[^a-z0-9]+/g, " ").trim();
}

/** NAME as words only, for a second search, as igdb_covers.py's words():
 * IGDB's search finds neither "NieR:Automata" nor "Rabbids®" as a game's
 * copy may spell them. */
export function searchWords(name) {
  return name
    .replace(/[™®©]/g, "")
    .replace(/[^\p{L}\p{N}_]+/gu, " ")
    .trim();
}

/** How alike A and B are, from 0 to 1, as Python's
 * difflib.SequenceMatcher(None, a, b).ratio() says it for names shorter
 * than 200 characters: twice the characters of their matching blocks,
 * over the characters of both. */
export function ratio(a, b) {
  const total = a.length + b.length;
  if (total === 0) return 1;
  const where = new Map();
  for (let j = 0; j < b.length; j++) {
    const places = where.get(b[j]);
    if (places) places.push(j);
    else where.set(b[j], [j]);
  }
  let matched = 0;
  const left = [[0, a.length, 0, b.length]];
  while (left.length) {
    const [aLow, aHigh, bLow, bHigh] = left.pop();
    // The longest block of A's part in B's, the earliest in A, then in B.
    let bestA = aLow;
    let bestB = bLow;
    let size = 0;
    let lengths = new Map();
    for (let i = aLow; i < aHigh; i++) {
      const next = new Map();
      for (const j of where.get(a[i]) ?? []) {
        if (j < bLow) continue;
        if (j >= bHigh) break;
        const length = (lengths.get(j - 1) ?? 0) + 1;
        next.set(j, length);
        if (length > size) {
          bestA = i - length + 1;
          bestB = j - length + 1;
          size = length;
        }
      }
      lengths = next;
    }
    if (size === 0) continue;
    matched += size;
    if (aLow < bestA && bLow < bestB) left.push([aLow, bestA, bLow, bestB]);
    if (bestA + size < aHigh && bestB + size < bHigh) left.push([bestA + size, aHigh, bestB + size, bHigh]);
  }
  return (2 * matched) / total;
}

/** How alike NAME is to the IGDB entry's name or one of its other names. */
export function likeness(name, entry) {
  const wanted = plainName(name);
  const others = Array.isArray(entry.alternative_names) ? entry.alternative_names.map((other) => other?.name) : [];
  return Math.max(
    ...[entry.name, ...others].map((other) => ratio(wanted, plainName(typeof other === "string" ? other : ""))),
  );
}

/** The IGDB entry for the game NAME among FOUND, or undefined: an entry
 * with a cover and a name close enough to NAME; among those, the closest
 * name wins, then an entry on the platform PLATFORM, IGDB's ID of it. */
export function chooseGame(name, platform, found) {
  let best;
  let bestKey;
  for (const entry of found) {
    if (!isObject(entry) || !Number.isInteger(entry.id) || entry.id < 1 || typeof entry.name !== "string") continue;
    if (!IMAGE.test(entry.cover?.image_id ?? "")) continue;
    const score = likeness(name, entry);
    if (score < IGDB.likeness) continue;
    const key = [Math.round(score * 1000) / 1000, Array.isArray(entry.platforms) && entry.platforms.includes(platform) ? 1 : 0];
    if (!best || key[0] > bestKey[0] || (key[0] === bestKey[0] && key[1] > bestKey[1])) {
      best = entry;
      bestKey = key;
    }
  }
  return best;
}

/** Cartouche's genre for IGDB's genre IDs, or undefined. */
export function genreOf(genres) {
  if (!Array.isArray(genres)) return undefined;
  return IGDB_GENRES.find(([id]) => genres.includes(id))?.[1];
}

/** What the server gives of an IGDB entry: its ID and name, its cover, an
 * artwork, its genre, and the platform the app said, else IGDB's. */
function gameOf(entry, platform, platforms) {
  const game = { igdb: entry.id, name: entry.name.slice(0, 200), cover: entry.cover.image_id };
  const artwork = (Array.isArray(entry.artworks) ? entry.artworks : []).map((art) => art?.image_id).find((id) => IMAGE.test(id ?? ""));
  if (artwork) game.artwork = artwork;
  const genre = genreOf(entry.genres);
  if (genre) game.genre = genre;
  const on = Array.isArray(entry.platforms) ? entry.platforms : [];
  game.platform = platform ?? (on.includes(platforms.switch) || !on.includes(platforms.switch2) ? "switch" : "switch2");
  return game;
}

const quoted = (text) => `"${text.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;

// The Twitch application's token, and IGDB's IDs of the two platforms, while
// this instance of the Worker lives: never kept anywhere else.
let igdbToken;
let igdbPlatforms;

export function resetIGDB() {
  igdbToken = undefined;
  igdbPlatforms = undefined;
}

async function igdbTokenOf(env, now) {
  if (igdbToken && igdbToken.expires > now + 60000) return igdbToken.value;
  if (!env.IGDB_CLIENT_ID || !env.IGDB_CLIENT_SECRET) throw new Error("no IGDB credentials");
  const response = await fetch(IGDB.token, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.IGDB_CLIENT_ID,
      client_secret: env.IGDB_CLIENT_SECRET,
      grant_type: "client_credentials",
    }).toString(),
  });
  if (!response.ok) throw new Error(`Twitch answered ${response.status}`);
  const answer = await response.json();
  if (typeof answer?.access_token !== "string") throw new Error("Twitch gave no token");
  const seconds = Number.isFinite(answer.expires_in) ? answer.expires_in : 3600;
  igdbToken = { value: answer.access_token, expires: now + seconds * 1000 };
  return igdbToken.value;
}

/** What IGDB's ENDPOINT answers QUERY: a list. */
async function askIGDB(env, endpoint, query, now) {
  const token = await igdbTokenOf(env, now);
  const response = await fetch(IGDB.api + endpoint, {
    method: "POST",
    headers: { "client-id": env.IGDB_CLIENT_ID, authorization: `Bearer ${token}`, accept: "application/json" },
    body: query,
  });
  // A token Twitch no longer takes: the next request takes a new one.
  if (response.status === 401) igdbToken = undefined;
  if (!response.ok) throw new Error(`IGDB answered ${response.status}`);
  const found = await response.json();
  if (!Array.isArray(found)) throw new Error("IGDB answered no list");
  return found;
}

/** IGDB's IDs of the Nintendo Switch and the Nintendo Switch 2. */
async function igdbPlatformsOf(env, now) {
  if (igdbPlatforms) return igdbPlatforms;
  const names = Object.values(IGDB.platforms);
  const found = await askIGDB(env, "platforms", `fields id,name; where ${names.map((name) => `name = ${quoted(name)}`).join(" | ")}; limit 10;`, now);
  const ids = {};
  for (const [key, name] of Object.entries(IGDB.platforms)) {
    const platform = found.find((entry) => entry?.name === name && Number.isInteger(entry.id));
    if (!platform) throw new Error(`IGDB has no platform named ${name}`);
    ids[key] = platform.id;
  }
  igdbPlatforms = ids;
  return ids;
}

/** The game NAME on IGDB, on PLATFORM if the app said it, or undefined
 * when IGDB has none close enough: by the name as the app sent it, then as
 * words only. Throws when IGDB cannot be asked. */
export async function findGame(env, name, platform, now) {
  const platforms = await igdbPlatformsOf(env, now);
  const on = Object.values(platforms).join(",");
  for (const terms of new Set([name, searchWords(name)])) {
    if (!terms) continue;
    const found = await askIGDB(env, "games", `search ${quoted(terms)}; ${IGDB.fields} where platforms = (${on}); limit 20;`, now);
    const entry = chooseGame(name, platforms[platform] ?? 0, found);
    if (entry) return gameOf(entry, platform, platforms);
  }
  return undefined;
}

/** The name and the platform the app asks for, or undefined: a name of a
 * few words, without control characters, and switch or switch2 when the
 * app knows the game's platform. */
export function cleanLookup(value) {
  if (!isObject(value)) return undefined;
  const name = words(LIMITS.lookupName, false)(value.name)?.trim();
  if (!name) return undefined;
  if (!has(value, "platform")) return { name };
  const platform = oneOf("switch", "switch2")(value.platform);
  return platform ? { name, platform } : undefined;
}

// MARK: Requests

const recent = new Map();
const recentProblems = new Map();
const recentLookups = new Map();

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
  recentLookups.clear();
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

/** What the server answers of a game it looked up: the game, or that IGDB
 * has none. */
const lookupAnswer = (answer) => (answer ? { found: true, ...JSON.parse(answer) } : { found: false });

async function games(request, env, now) {
  const read = await readJSON(request);
  if (read.error) return read.error;
  const asked = cleanLookup(read.value);
  if (!asked) return reply(400, { error: "expected a game's name" });
  if (over(recentLookups, request.headers.get("cf-connecting-ip"), now, 3600000, LIMITS.lookupsPerAddressPerHour)) {
    return reply(429, { error: "too many games from this address" }, { "retry-after": "3600" });
  }
  const simple = plainName(asked.name);
  // A name of no letter IGDB could read, such as one in Japanese only.
  if (!simple) return reply(200, { found: false });
  // Kept by the name made plain, with the platform the app said.
  const name = `${asked.platform ?? ""}:${simple}`;
  const day = today(now);
  let known;
  try {
    known = await env.DB.prepare(SQL.lookup).bind(name).first();
    if (known && known.day >= today(now - LIMITS.lookupKeptDays * 86400000)) return reply(200, lookupAnswer(known.answer));
    const counted = await env.DB.prepare(SQL.lookupsOfDay).bind(day).first();
    if ((counted?.count ?? 0) >= LIMITS.lookupsPerDay) {
      if (known) return reply(200, lookupAnswer(known.answer));
      return reply(503, { error: "too many games today" }, { "retry-after": "3600" });
    }
  } catch {
    return reply(503, { error: "unavailable" }, { "retry-after": "3600" });
  }
  let game;
  try {
    game = await findGame(env, asked.name, asked.platform, now);
  } catch {
    // IGDB away, or no credentials: an answer kept before still holds.
    if (known) return reply(200, lookupAnswer(known.answer));
    return reply(503, { error: "IGDB unavailable" }, { "retry-after": "3600" });
  }
  const answer = game ? JSON.stringify(game) : "";
  try {
    await env.DB.prepare(SQL.keepLookup).bind(name, day, answer).run();
  } catch {
    // Answered all the same; asked again next time.
  }
  return reply(200, lookupAnswer(answer));
}

/** Deletes the reports older than 25 months, the counts of past days, the
 * problems filed before yesterday, and the games looked up more than 30
 * days ago. */
export async function expire(env, now) {
  const cutoff = new Date(now);
  cutoff.setUTCMonth(cutoff.getUTCMonth() - LIMITS.keptMonths);
  // The counts of today and yesterday are all the daily caps read.
  const counted = new Date(now - 2 * 86400000);
  await env.DB.batch([
    env.DB.prepare(SQL.expireReports).bind(cutoff.toISOString().slice(0, 10)),
    env.DB.prepare(SQL.expireDaily).bind(counted.toISOString().slice(0, 10)),
    env.DB.prepare(SQL.expireProblems).bind(counted.toISOString().slice(0, 10), cutoff.toISOString().slice(0, 10)),
    env.DB.prepare(SQL.expireLookups).bind(today(now - LIMITS.lookupKeptDays * 86400000)),
  ]);
}

const ROUTES = new Map([
  ["/v1/reports", reports],
  ["/v1/forget", forget],
  ["/v1/problems", problems],
  ["/v1/games", games],
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
