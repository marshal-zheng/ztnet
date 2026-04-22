#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_TEMPLATE="${ENV_TEMPLATE:-.env.example}"
ENV_FILE="${ENV_FILE:-.env}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-ztnet-dev-postgres}"
POSTGRES_VOLUME="${POSTGRES_VOLUME:-ztnet-dev-postgres-data}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15.2-alpine}"
POSTGRES_HOST="${POSTGRES_HOST:-127.0.0.1}"
POSTGRES_PORT="${POSTGRES_PORT:-55432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-ztnet}"
MIGRATE_POSTGRES_DB="${MIGRATE_POSTGRES_DB:-shaddow_ztnet}"
ZT_ADDR="${ZT_ADDR:-http://127.0.0.1:9994}"
ZT_CONTAINER_NAME="${ZT_CONTAINER_NAME:-myztplanet}"
APP_PORT="${APP_PORT:-${PORT:-4000}}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
NEXTAUTH_URL="${NEXTAUTH_URL:-}"
NEXTAUTH_SECRET="${NEXTAUTH_SECRET:-}"

log() {
  printf '[dev-server] %s\n' "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

upsert_env() {
  local key="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 {
      print key "=\"" value "\""
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key "=\"" value "\""
      }
    }
  ' "$ENV_FILE" > "$tmp_file"

  mv "$tmp_file" "$ENV_FILE"
}

detect_public_host() {
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [ -z "$host_ip" ]; then
    host_ip="$(hostname -i 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$host_ip" ]; then
    host_ip="127.0.0.1"
  fi
  printf '%s' "$host_ip"
}

detect_zt_secret() {
  if [ -n "${ZT_SECRET:-}" ]; then
    printf '%s' "$ZT_SECRET"
    return 0
  fi

  if docker ps --format '{{.Names}}' | grep -qx "$ZT_CONTAINER_NAME"; then
    docker exec "$ZT_CONTAINER_NAME" cat /var/lib/zerotier-one/authtoken.secret
    return 0
  fi

  printf 'Could not read ZT_SECRET from container "%s". Set ZT_SECRET before running.\n' "$ZT_CONTAINER_NAME" >&2
  exit 1
}

ensure_env_file() {
  if [ ! -f "$ENV_TEMPLATE" ]; then
    printf 'Missing env template: %s\n' "$ENV_TEMPLATE" >&2
    exit 1
  fi

  if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    log "Created $ENV_FILE from $ENV_TEMPLATE"
  fi
}

ensure_postgres() {
  local existing_container
  existing_container="$(docker ps -a --format '{{.Names}}' | grep -x "$POSTGRES_CONTAINER" || true)"

  if [ -z "$existing_container" ]; then
    log "Starting PostgreSQL container $POSTGRES_CONTAINER on ${POSTGRES_HOST}:${POSTGRES_PORT}"
    docker run -d \
      --name "$POSTGRES_CONTAINER" \
      --restart unless-stopped \
      -e POSTGRES_USER="$POSTGRES_USER" \
      -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
      -e POSTGRES_DB="$POSTGRES_DB" \
      -p "${POSTGRES_HOST}:${POSTGRES_PORT}:5432" \
      -v "${POSTGRES_VOLUME}:/var/lib/postgresql/data" \
      "$POSTGRES_IMAGE" >/dev/null
  else
    if [ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER")" != "true" ]; then
      log "Starting existing PostgreSQL container $POSTGRES_CONTAINER"
      docker start "$POSTGRES_CONTAINER" >/dev/null
    fi
  fi

  log "Waiting for PostgreSQL to accept connections"
  until docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
    sleep 1
  done
}

require_command docker
require_command npm
require_command npx
require_command openssl
require_command awk

ensure_env_file

if [ -z "$NEXTAUTH_URL" ]; then
  if [ -n "$PUBLIC_HOST" ]; then
    NEXTAUTH_URL="http://${PUBLIC_HOST}:${APP_PORT}"
  else
    NEXTAUTH_URL="http://$(detect_public_host):${APP_PORT}"
  fi
fi

if [ -z "$NEXTAUTH_SECRET" ]; then
  NEXTAUTH_SECRET="$(openssl rand -base64 32)"
fi

ZT_SECRET="$(detect_zt_secret)"

upsert_env "NEXTAUTH_URL" "$NEXTAUTH_URL"
upsert_env "NEXTAUTH_SECRET" "$NEXTAUTH_SECRET"
upsert_env "POSTGRES_HOST" "$POSTGRES_HOST"
upsert_env "POSTGRES_USER" "$POSTGRES_USER"
upsert_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
upsert_env "POSTGRES_PORT" "$POSTGRES_PORT"
upsert_env "POSTGRES_DB" "$POSTGRES_DB"
upsert_env "PORT" "$APP_PORT"
upsert_env "DATABASE_URL" "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?schema=public"
upsert_env "MIGRATE_POSTGRES_DB" "$MIGRATE_POSTGRES_DB"
upsert_env "MIGRATE_DATABASE_URL" "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${MIGRATE_POSTGRES_DB}?schema=public"
upsert_env "ZT_ADDR" "$ZT_ADDR"
upsert_env "ZT_SECRET" "$ZT_SECRET"

log "Configured $ENV_FILE with NEXTAUTH_URL=$NEXTAUTH_URL, PORT=$APP_PORT and ZT_ADDR=$ZT_ADDR"

ensure_postgres

log "Installing dependencies"
npm install

log "Applying Prisma migrations"
npx prisma migrate deploy

log "Seeding database"
npx prisma db seed

log "Starting Next.js dev server on port $APP_PORT"
PORT="$APP_PORT" npm run dev
