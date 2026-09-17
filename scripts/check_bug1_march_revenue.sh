#!/usr/bin/env bash
#
# check_bug1_march_revenue.sh
#
# Investigates Client A (Sunset Properties)'s complaint:
#   "The revenue numbers on your dashboard don't match our internal records."
#
# Root cause (Option A - dashboard shows ALL-TIME revenue per property,
# no monthly filtering): the revenue endpoint could never connect to
# Postgres (bad connection string -> wrong async pool class -> async def
# on a non-awaiting method), so every request silently fell through to a
# hardcoded mock-data dict instead of hitting the real database.
#
# What this script does, in one shot:
#   1. Finds the running db/backend containers for this compose project.
#   2. Logs in as Sunset Properties via the real API to get a bearer token.
#   3. Reads the backend's OpenAPI spec to find revenue/report endpoints
#      automatically.
#   4. Calls the discovered endpoint for each of the tenant's properties
#      (all-time revenue, no date params).
#   5. Independently recomputes the same all-time total straight from
#      Postgres with a plain SUM (no date filtering) for comparison.
#   6. Prints both so a mismatch (e.g. API still returning mock data) is
#      obvious.
#
# Usage:
#   ./check_bug1_march_revenue.sh

set -euo pipefail

# ---------- config ----------
API_BASE="${API_BASE:-http://localhost:8000}"
EMAIL="${EMAIL:-sunset@propertyflow.com}"
PASSWORD="${PASSWORD:-client_a_2024}"

RESERVATIONS_TABLE="${RESERVATIONS_TABLE:-reservations}"
PROPERTIES_TABLE="${PROPERTIES_TABLE:-properties}"
AMOUNT_COLUMN="${AMOUNT_COLUMN:-total_amount}"
TENANT_ID="${TENANT_ID:-tenant-a}"          # Sunset Properties

echo "=============================================="
echo " BUG #1 CHECK: revenue matches real DB data (Client A)"
echo "=============================================="

# ---------- 1. find containers ----------
DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E 'db-1$|_db_1$' | head -n1)
BACKEND_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E 'backend-1$|_backend_1$' | head -n1)

if [[ -z "$DB_CONTAINER" || -z "$BACKEND_CONTAINER" ]]; then
  echo "Could not auto-detect containers. Running containers:"
  docker ps --format '  {{.Names}}'
  exit 1
fi
echo "DB container:      $DB_CONTAINER"
echo "Backend container:  $BACKEND_CONTAINER"

DB_ENV=$(docker exec "$DB_CONTAINER" env)
PGUSER=$(echo "$DB_ENV" | grep -m1 '^POSTGRES_USER=' | cut -d= -f2- || true)
PGDATABASE=$(echo "$DB_ENV" | grep -m1 '^POSTGRES_DB=' | cut -d= -f2- || true)
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-propertyflow}"
echo "Postgres user/db:   $PGUSER / $PGDATABASE"
echo

# ---------- 2. log in via real API ----------
echo "--- Logging in as $EMAIL via API ---"
LOGIN_RESPONSE=$(curl -s -X POST "$API_BASE/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.access_token // .token // empty')

if [[ -z "$TOKEN" ]]; then
  echo "Could not extract token automatically. Raw login response:"
  echo "$LOGIN_RESPONSE" | jq . 2>/dev/null || echo "$LOGIN_RESPONSE"
  exit 1
fi
echo "Got token: ${TOKEN:0:20}..."
echo

# ---------- 3. discover revenue endpoint ----------
echo "--- Discovering revenue-related endpoints from $API_BASE/openapi.json ---"
OPENAPI=$(curl -s "$API_BASE/openapi.json")
REVENUE_PATHS=$(echo "$OPENAPI" | jq -r '.paths | keys[] | select(test("revenue|report|dashboard|summary"; "i"))')
echo "$REVENUE_PATHS"
echo

if [[ -z "$REVENUE_PATHS" ]]; then
  echo "No obviously-named revenue endpoint found - inspect $API_BASE/docs manually."
  API_TOTAL="unknown"
else
  FIRST_PATH=$(echo "$REVENUE_PATHS" | head -n1)
  echo "--- $FIRST_PATH requires a property_id, so fetching this tenant's property IDs ---"
  PROPERTY_IDS=$(docker exec "$DB_CONTAINER" psql -U "$PGUSER" -d "$PGDATABASE" -t -A -c \
    "SELECT id FROM ${PROPERTIES_TABLE} WHERE tenant_id = '${TENANT_ID}';")
  echo "Properties for $TENANT_ID:"
  echo "$PROPERTY_IDS" | sed 's/^/  /'
  echo

  echo "--- Calling $FIRST_PATH per property (all-time, no date params) and summing ---"
  API_TOTAL=0
  while IFS= read -r PID; do
    [[ -z "$PID" ]] && continue
    RESP=$(curl -s -H "Authorization: Bearer $TOKEN" \
      "$API_BASE${FIRST_PATH}?property_id=$PID")
    echo "  property_id=$PID -> $(echo "$RESP" | jq -c . 2>/dev/null || echo "$RESP")"
    AMT=$(echo "$RESP" | jq -r '.revenue // .total_revenue // .total // empty' 2>/dev/null) || AMT=""
    if [[ -n "$AMT" && "$AMT" != "null" ]]; then
      API_TOTAL=$(echo "$API_TOTAL + $AMT" | bc)
    else
      echo "    (no numeric total parsed from this response - not included in sum)"
    fi
  done <<< "$PROPERTY_IDS"
  echo
  echo "  ==> API all-time total for $TENANT_ID (summed across properties): $API_TOTAL"
fi
echo

# ---------- 4. recompute independently from raw DB data (no date filter) ----------
echo "--- Recomputing all-time total directly from Postgres ---"
echo "Table/column assumptions: ${RESERVATIONS_TABLE}.${AMOUNT_COLUMN}, tenant_id"
echo "(If wrong, run: docker exec -it $DB_CONTAINER psql -U $PGUSER -d $PGDATABASE -c '\\d $RESERVATIONS_TABLE')"
echo

SQL="SELECT ROUND(SUM(${AMOUNT_COLUMN}), 2) AS all_time_total FROM ${RESERVATIONS_TABLE} WHERE tenant_id = '${TENANT_ID}';"

echo "$SQL" | docker exec -i "$DB_CONTAINER" psql -U "$PGUSER" -d "$PGDATABASE" || {
  echo "Query failed - table/column names likely don't match your schema."
  echo "Inspect with: docker exec -it $DB_CONTAINER psql -U $PGUSER -d $PGDATABASE -c '\\d $RESERVATIONS_TABLE'"
  exit 1
}

echo
echo "=============================================="
echo " Compare the API total above against the SQL"
echo " all_time_total."
echo " - BEFORE the database_pool.py fix: API total"
echo "   was hardcoded mock data (12076.00 for the"
echo "   3 Sunset properties), unrelated to real DB rows."
echo " - AFTER the fix: the API total should match the"
echo "   SQL all_time_total exactly, confirming the"
echo "   revenue endpoint now reads real reservation data."
echo " Tip: if you just applied the fix and still see"
echo " stale numbers, flush redis first:"
echo "   docker exec -it \$(docker ps --format '{{.Names}}' | grep redis) redis-cli FLUSHALL"
echo "=============================================="