#!/usr/bin/env bash
# Wdraża migracje (i opcjonalnie dane demo) na chmurowy projekt Supabase "Portfolio".
# Wymaga w .env.local: SUPABASE_CLOUD_REF oraz SUPABASE_DB_PASSWORD (wzór: env.local.example).
# Użycie:
#   scripts/deploy-db.sh              pokazuje, co zostałoby zastosowane (dry run)
#   scripts/deploy-db.sh --apply      stosuje migracje
#   scripts/deploy-db.sh --apply --seed   dodatkowo wgrywa supabase/seed.sql (tylko do pustej bazy)
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env.local ] && { set -a; . ./.env.local; set +a; }

# Ten skrypt nigdy nie dotyka projektu BazAPP.
BLOCKED_REFS="oboijsuuncwzgthsxgdg"
ref="${SUPABASE_CLOUD_REF:-}"
if [ -z "$ref" ] || [ -z "${SUPABASE_DB_PASSWORD:-}" ]; then
  echo "Ustaw SUPABASE_CLOUD_REF i SUPABASE_DB_PASSWORD w .env.local (wzór: env.local.example)." >&2
  exit 1
fi
case " $BLOCKED_REFS " in *" $ref "*) echo "Odmowa: $ref to projekt BazAPP, a nie Portfolio." >&2; exit 1;; esac

apply=0; seed=0
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --seed) seed=1 ;;
    *) echo "Nieznana opcja: $a" >&2; exit 1 ;;
  esac
done

export SUPABASE_DB_PASSWORD
supabase link --project-ref "$ref" --password "$SUPABASE_DB_PASSWORD" >/dev/null

if [ "$apply" -eq 0 ]; then
  echo "Dry run dla projektu $ref:"
  supabase db push --linked --dry-run
  echo "Aby zastosować: scripts/deploy-db.sh --apply"
  exit 0
fi

if [ "$seed" -eq 1 ]; then
  supabase db push --linked --include-seed --yes
else
  supabase db push --linked --yes
fi
echo "OK: migracje zastosowane na $ref"
