#!/usr/bin/env bash
# Uruchamia wszystkie testy SQL z supabase/tests na lokalnej bazie Supabase.
# Użycie: scripts/test-sql.sh [plik.sql ...]
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  files=(supabase/tests/*.sql)
fi

failed=0
for f in "${files[@]}"; do
  echo "== $f"
  if ! docker exec -i "$DB_CONTAINER" psql -U postgres -q -v ON_ERROR_STOP=1 < "$f" 2>&1 \
      | sed -n 's/^.*NOTICE:  //p; /ERROR/p'; then
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "FAIL"
  exit 1
fi
echo "OK"
