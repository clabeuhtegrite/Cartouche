-- The telemetry database (telemetry/README.md). The deploy workflow applies
-- this file at each deploy: every statement must run again without harm.

-- One row per report, as the Worker kept it (body), with the fields the
-- weekly summary reads beside it. day is the day the server received it,
-- in UTC: there is no time and no address.
CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  install TEXT NOT NULL,
  day TEXT NOT NULL,
  seq INTEGER,
  cartouche TEXT,
  device TEXT,
  ios TEXT,
  game TEXT,
  name TEXT,
  session TEXT,
  body TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS reports_by_game ON reports (kind, game, device);
CREATE INDEX IF NOT EXISTS reports_by_install ON reports (install);
CREATE INDEX IF NOT EXISTS reports_by_day ON reports (day);

-- How many reports each copy of Cartouche sent each day, for its daily cap.
CREATE TABLE IF NOT EXISTS daily (
  install TEXT NOT NULL,
  day TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (install, day)
);

-- The problems players send from Report a problem, until GitHub has them
-- as issues of the project's private repository (worker.js, POST
-- /v1/problems): title and body are the issue's. Once filed, only the day
-- and the issue's number stay, for the daily cap, until the day after.
CREATE TABLE IF NOT EXISTS problems (
  id TEXT PRIMARY KEY,
  day TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  issue INTEGER
);
CREATE INDEX IF NOT EXISTS problems_by_day ON problems (day);
CREATE INDEX IF NOT EXISTS problems_waiting ON problems (issue, day);

-- What IGDB has of a game Cartouche's catalog does not know, as the server
-- found it for the name the app sent (worker.js, POST /v1/games): name is
-- that name made plain, after the platform the app said, such as
-- "switch:unravel two"; answer the game found, as JSON, or '' when IGDB has
-- none close enough. day is the day the server asked IGDB, for its daily
-- cap and to ask again after 30 days. Never who asked.
CREATE TABLE IF NOT EXISTS lookups (
  name TEXT PRIMARY KEY,
  day TEXT NOT NULL,
  answer TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS lookups_by_day ON lookups (day);
