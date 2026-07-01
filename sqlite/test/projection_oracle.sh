#!/usr/bin/env bash
# Differential oracle for computed SELECT columns (lib.select withColumns).
#
# Builds projection_demo.mdk (native), runs it against a sqlite3-created DB, and
# checks each labelled projection query against sqlite3's own answer for the
# equivalent SELECT <exprs> FROM ... (ORDER BY an ORIGINAL column for
# determinism).  Proves the projection path (projectCells + compileValue over the
# raw row, before decode) agrees with the engine for: a computed arithmetic
# column + a plain column; column reordering/subsetting; a computed column over a
# JOIN; and a computed projection under DISTINCT.
#
# Run from the repo root.  Requires: sqlite3 on PATH, a built native `medaka`
# (./medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT

command -v sqlite3 >/dev/null 2>&1 || { echo "STOP: sqlite3 not on PATH"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/proj.db"
BIN="$TMP/pdemo"

sqlite3 "$DB" "\
  CREATE TABLE nums(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, name TEXT); \
  INSERT INTO nums VALUES (1,10,5,'Carol'),(2,3,7,'Alice'),(3,20,0,'Bob'),(4,1,1,'Dave'); \
  CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT); \
  INSERT INTO users VALUES (1,'Alice'),(2,'Bob'); \
  CREATE TABLE orders(oid INTEGER PRIMARY KEY, uid INTEGER, total INTEGER); \
  INSERT INTO orders VALUES (1,1,100),(2,2,50),(3,1,25);"

"$MEDAKA" build --allow-internal "$ROOT/sqlite/projection_demo.mdk" -o "$BIN" >/dev/null 2>&1 \
  || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

sq() { sqlite3 "$DB" "$1"; }
exp=""
add() { exp+="$1"$'\n'; }
addq() { while IFS= read -r r; do exp+="$r"$'\n'; done < <(sq "$2"); }

# (a) computed arithmetic column + a plain column, ORDER BY the plain column.
add  "-- SELECT a+b, name ORDER BY name --"
addq x "SELECT a+b, name FROM nums ORDER BY name;"
# (b) reordering/subsetting: table is (id,a,b,name); project name,id.
add  "-- SELECT name, id ORDER BY id --"
addq x "SELECT name, id FROM nums ORDER BY id;"
# (c) computed column over an INNER JOIN, ORDER BY an original (unique) column.
add  "-- SELECT users.name, orders.total+10 JOIN ORDER BY orders.total --"
addq x "SELECT users.name, orders.total+10 FROM users JOIN orders ON users.id=orders.uid ORDER BY orders.total;"
# (d) computed projection under DISTINCT: a*0 collapses every row to one 0.
add  "-- SELECT DISTINCT a*0 --"
addq x "SELECT DISTINCT a*0 FROM nums;"

exp="${exp%$'\n'}"

if [ "$got" = "$exp" ]; then
  echo "PASS: computed-column projection output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: computed-column projection output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
