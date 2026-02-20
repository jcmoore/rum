#!/usr/bin/env bash
set -euo pipefail

VERBOSE=0
IMAGE="postgres:17-bookworm"

usage() {
  cat <<'EOF'
Run RUM regression tests against native PostgreSQL 17 in Docker.

Usage:
  scripts/run-pg17-installcheck.sh [-v|--verbose]

Options:
  -v, --verbose   Stream full logs to stdout
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/.logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/pg17-installcheck-$(date +%Y%m%d-%H%M%S).log"

DOCKER_SCRIPT='set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ "${VERBOSE:-0}" = "1" ]; then
  apt-get update
  apt-get install -y --no-install-recommends make gcc libc6-dev postgresql-server-dev-17 postgresql-17 libipc-run-perl
else
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends make gcc libc6-dev postgresql-server-dev-17 postgresql-17 libipc-run-perl >/dev/null
fi

# Always start from a fresh in-container workspace to avoid stale files/permissions.
rm -rf /tmp/rum-src /tmp/rum-pgdata
cp -a /work/rum /tmp/rum-src
mkdir -p /tmp/rum-pgdata
chown -R postgres:postgres /tmp/rum-src /tmp/rum-pgdata

# Build as postgres so TAP can write tmp_check and related files.
gosu postgres bash -lc "cd /tmp/rum-src && make USE_PGXS=1 clean && make USE_PGXS=1 -j\"\$(nproc)\""

# Install as root into the image PostgreSQL location.
make -C /tmp/rum-src USE_PGXS=1 install

# Start isolated test cluster.
gosu postgres /usr/lib/postgresql/17/bin/initdb -D /tmp/rum-pgdata >/dev/null
gosu postgres /usr/lib/postgresql/17/bin/pg_ctl -D /tmp/rum-pgdata -o "-k /tmp -F" -w start >/dev/null
trap "gosu postgres /usr/lib/postgresql/17/bin/pg_ctl -D /tmp/rum-pgdata -m fast stop >/dev/null || true" EXIT

# Run full installcheck (REGRESS + TAP) as postgres.
gosu postgres bash -lc "export PATH=/usr/lib/postgresql/17/bin:\$PATH PGHOST=/tmp PGPORT=5432 PGUSER=postgres; cd /tmp/rum-src && make USE_PGXS=1 installcheck"
'

if [[ "$VERBOSE" -eq 1 ]]; then
  docker run --rm \
    -e VERBOSE=1 \
    -v "$SCRIPT_DIR":/work/rum:rw \
    -w /work/rum \
    "$IMAGE" \
    bash -lc "$DOCKER_SCRIPT"
else
  echo "Running PG17 installcheck in Docker (quiet mode)..."
  if docker run --rm \
    -e VERBOSE=0 \
    -v "$SCRIPT_DIR":/work/rum:rw \
    -w /work/rum \
    "$IMAGE" \
    bash -lc "$DOCKER_SCRIPT" >"$LOG_FILE" 2>&1; then
    echo "PASS: RUM PG17 installcheck"
    echo "Log: $LOG_FILE"
  else
    echo "FAIL: RUM PG17 installcheck" >&2
    echo "Log: $LOG_FILE" >&2
    echo "Last 80 log lines:" >&2
    tail -n 80 "$LOG_FILE" >&2 || true
    exit 1
  fi
fi
