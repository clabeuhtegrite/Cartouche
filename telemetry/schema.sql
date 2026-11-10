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
