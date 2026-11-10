#!/usr/bin/env bash
# Deploys the telemetry server (README.md) to the Cloudflare account
# CLOUDFLARE_ACCOUNT_ID with the API token CLOUDFLARE_API_TOKEN, through
# Cloudflare's API, with curl and jq and nothing else:
#
# 1. the D1 database cartouche-telemetry, created in the EU jurisdiction
#    when it does not exist yet: a database's jurisdiction is set when it
#    is created, and never changes;
# 2. schema.sql applied to it, each statement of which runs again without
#    harm;
# 3. the Worker cartouche-telemetry, worker.js as it is, with the database
#    as DB and no logs kept, and what it files the problems players send
#    with: the private repository CARTOUCHE_REPORTS_REPOSITORY and the token
#    CARTOUCHE_REPORTS_TOKEN, when they are set; without them, or with a
#    public repository, the Worker keeps the problems until a deploy with
#    them;
# 4. its workers.dev address, on the account's workers.dev subdomain,
#    which is created when the account has none;
# 5. its daily run, which deletes the reports older than 25 months.
#
# It ends with the Worker's address, which goes in app/config.env as
# CARTOUCHE_TELEMETRY_URL. Without the two variables it says so and does
# nothing: they are secrets of the repository's environment cloudflare,
# which .github/workflows/telemetry.yml deploys from.
#
#     CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… telemetry/deploy.sh
#
# The token needs Account › Workers Scripts › Edit and Account › D1 › Edit.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=cartouche-telemetry
# The Workers runtime worker.js is written for.
COMPATIBILITY_DATE=2026-09-01
# Every day at 03:17 UTC.
SCHEDULE="17 3 * * *"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  echo "::notice::No CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID: the telemetry server is not deployed."
  exit 0
fi

# CLOUDFLARE_API stands in for Cloudflare's API in the tests (test/test_deploy.py).
API="${CLOUDFLARE_API:-https://api.cloudflare.com/client/v4}/accounts/$CLOUDFLARE_ACCOUNT_ID"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The token goes to curl in a file, never on a command line.
printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" >"$WORK/authorization"

# ask METHOD PATH [CURL ARGUMENTS...]: Cloudflare's whole answer, in
# $WORK/answer.json; fails when Cloudflare says the call did not succeed.
ask() {
  local method="$1" path="$2"
  shift 2
  curl -sS -o "$WORK/answer.json" -X "$method" -H @"$WORK/authorization" "$@" "$API$path" || return 1
  jq -e '.success == true' "$WORK/answer.json" >/dev/null 2>&1
}

# call METHOD PATH [CURL ARGUMENTS...]: the call's result, or its errors and
# the end of the deploy.
call() {
  if ! ask "$@"; then
    echo "Cloudflare refused $1 $2:" >&2
    jq -r '.errors[]? | "  \(.code): \(.message)"' "$WORK/answer.json" >&2 2>/dev/null || cat "$WORK/answer.json" >&2
    exit 1
  fi
  jq '.result' "$WORK/answer.json"
}

json() { printf '%s' "$1" >"$WORK/body.json"; echo "@$WORK/body.json"; }

# 1. The database.
found="$(call GET "/d1/database?name=$NAME" |
  jq -r --arg name "$NAME" 'map(select(.name == $name)) | first // empty | "\(.uuid) \(.jurisdiction // "")"')"
if [ -z "$found" ]; then
  echo "Creating the D1 database $NAME in the EU jurisdiction"
  database="$(call POST /d1/database -H "Content-Type: application/json" \
    --data-binary "$(json "$(jq -n --arg name "$NAME" '{name: $name, jurisdiction: "eu"}')")" | jq -r '.uuid')"
else
  read -r database jurisdiction <<<"$found"
  if [ -n "$jurisdiction" ] && [ "$jurisdiction" != eu ]; then
    echo "The D1 database $NAME is in the jurisdiction $jurisdiction, not eu: delete it, and deploy again." >&2
    exit 1
  fi
  echo "The D1 database $NAME is there"
fi

# 2. Its tables. D1 runs the statements as one batch; the comments are left
# out.
echo "Applying schema.sql"
call POST "/d1/database/$database/query" -H "Content-Type: application/json" \
  --data-binary "$(json "$(sed -e '/^[[:space:]]*--/d' "$HERE/schema.sql" | jq -Rs '{sql: .}')")" >/dev/null

# 3. The Worker, and the repository it files problems in. Its token goes
# to curl and jq in files too.
echo '[]' >"$WORK/problems.json"
problems="the server keeps the problems players send: there is no CARTOUCHE_REPORTS_TOKEN"
if [ -n "${CARTOUCHE_REPORTS_TOKEN:-}" ] && [ -n "${CARTOUCHE_REPORTS_REPOSITORY:-}" ]; then
  repository="$CARTOUCHE_REPORTS_REPOSITORY"
  printf 'Authorization: Bearer %s\n' "$CARTOUCHE_REPORTS_TOKEN" >"$WORK/github-authorization"
  printf '%s' "$CARTOUCHE_REPORTS_TOKEN" >"$WORK/problems-token"
  visibility="$(curl -sS --max-time 20 -H @"$WORK/github-authorization" -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/$repository" 2>/dev/null |
    jq -r 'if (type == "object" and has("private")) then (if .private then "private" else "public" end) else empty end' 2>/dev/null || true)"
  case "$visibility" in
    private) problems="players' problems go to $repository, a private repository" ;;
    public) problems="$repository is public: the server files no problem there, and keeps them" ;;
    *) problems="the token cannot read $repository: the server keeps the problems until GitHub takes them" ;;
  esac
  if [ "$visibility" != public ]; then
    jq -n --arg repository "$repository" --rawfile token "$WORK/problems-token" '[
      {type: "plain_text", name: "PROBLEMS_REPOSITORY", text: $repository},
      {type: "secret_text", name: "PROBLEMS_TOKEN", text: $token}
    ]' >"$WORK/problems.json"
  fi
fi
case "$problems" in
  players*) echo "Problems: $problems" ;;
  *public*) echo "::error::Problems: $problems." ;;
  *) echo "::warning::Problems: $problems." ;;
esac

echo "Uploading the Worker $NAME"
jq -n --arg date "$COMPATIBILITY_DATE" --arg database "$database" --slurpfile problems "$WORK/problems.json" '{
  main_module: "worker.js",
  compatibility_date: $date,
  bindings: ([{type: "d1", name: "DB", id: $database}] + $problems[0]),
  observability: {enabled: false}
}' >"$WORK/metadata.json"
call PUT "/workers/scripts/$NAME" \
  -F "metadata=@$WORK/metadata.json;type=application/json" \
  -F "worker.js=@$HERE/worker.js;type=application/javascript+module" >/dev/null

# 4. Its address.
if ask GET /workers/subdomain && subdomain="$(jq -er '.result.subdomain // empty' "$WORK/answer.json")"; then
  echo "The account's workers.dev subdomain is $subdomain"
else
  subdomain="cartouche-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  echo "The account has no workers.dev subdomain: creating $subdomain"
  call PUT /workers/subdomain -H "Content-Type: application/json" \
    --data-binary "$(json "$(jq -n --arg subdomain "$subdomain" '{subdomain: $subdomain}')")" >/dev/null
fi
call POST "/workers/scripts/$NAME/subdomain" -H "Content-Type: application/json" \
  --data-binary "$(json '{"enabled": true, "previews_enabled": false}')" >/dev/null

# 5. Its daily run.
call PUT "/workers/scripts/$NAME/schedules" -H "Content-Type: application/json" \
  --data-binary "$(json "$(jq -n --arg cron "$SCHEDULE" '[{cron: $cron}]')")" >/dev/null

URL="https://$NAME.$subdomain.workers.dev"
# A new workers.dev address can take a minute or two to answer.
answered=""
for ((try = 0; try < ${TELEMETRY_CHECK_TRIES:-12}; try++)); do
  if [ "$try" -gt 0 ]; then sleep 10; fi
  if [ "$(curl -sS --max-time 10 "$URL/" 2>/dev/null)" = "Cartouche telemetry" ]; then
    answered=yes
    break
  fi
done
if [ -n "$answered" ]; then
  echo "The telemetry server answers at $URL"
else
  echo "::warning::$URL does not answer yet: a new workers.dev address can take a few minutes."
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "The telemetry server is at $URL: \`CARTOUCHE_TELEMETRY_URL=$URL\` in app/config.env." >>"$GITHUB_STEP_SUMMARY"
  echo "Problems: $problems." >>"$GITHUB_STEP_SUMMARY"
fi
