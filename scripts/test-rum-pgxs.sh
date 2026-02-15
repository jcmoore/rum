#!/usr/bin/env bash
set -euo pipefail

QUIET=0
IMAGE="${RUM_PGXS_IMAGE:-postgres:17-bookworm}"
PG_MAJOR="${RUM_PG_MAJOR:-17}"
PGPORT="${RUM_PGXS_PORT:-55435}"
INSTALLCHECK_ARGS=()

while (($#)); do
	case "$1" in
		-q|--quiet)
			QUIET=1
			shift
			;;
		--image)
			IMAGE="$2"
			shift 2
			;;
		--image=*)
			IMAGE="${1#*=}"
			shift
			;;
		--pg-major)
			PG_MAJOR="$2"
			shift 2
			;;
		--pg-major=*)
			PG_MAJOR="${1#*=}"
			shift
			;;
		--port)
			PGPORT="$2"
			shift 2
			;;
		--port=*)
			PGPORT="${1#*=}"
			shift
			;;
		--)
			shift
			INSTALLCHECK_ARGS+=("$@")
			break
			;;
		*)
			INSTALLCHECK_ARGS+=("$1")
			shift
			;;
	esac
done

if ! command -v docker >/dev/null 2>&1; then
	echo "error: docker is required" >&2
	exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUM_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

BIG_VALUES=0
if [[ "${PG_TEST_EXTRA:-}" =~ (^|[[:space:]])big_values($|[[:space:]]) ]]; then
	BIG_VALUES=1
fi

# For big_values runs, default to copying sources into VM-local storage to keep
# huge temporary test data off the host bind mount.
BIG_VALUES_WORKDIR_IN_VM="${RUM_PGXS_BIG_VALUES_WORKDIR_IN_VM:-1}"

docker_cmd=(
	docker run --rm -i
)

if (( BIG_VALUES == 1 )) && [[ "$BIG_VALUES_WORKDIR_IN_VM" == "1" ]]; then
	docker_cmd+=(
		-v "$RUM_DIR":/host/rum:ro
		-w /tmp
		-e RUM_PGXS_SOURCE_DIR=/host/rum
		-e RUM_PGXS_WORK_DIR=/work/rum
	)
else
	docker_cmd+=(
		-v "$RUM_DIR":/work/rum
		-w /work/rum
		-e RUM_PGXS_WORK_DIR=/work/rum
	)
fi

if [[ "${PG_TEST_EXTRA+set}" == "set" ]]; then
	docker_cmd+=( -e "PG_TEST_EXTRA=$PG_TEST_EXTRA" )
	if (( BIG_VALUES == 1 )); then
		BIG_VALUES_SHM_SIZE="${RUM_PGXS_BIG_VALUES_SHM_SIZE:-6g}"
		docker_cmd+=( --shm-size "$BIG_VALUES_SHM_SIZE" )
	fi
fi

if [[ "${RUM_PGXS_BIG_VALUES_MIN_FREE_GB+set}" == "set" ]]; then
	docker_cmd+=( -e "RUM_PGXS_BIG_VALUES_MIN_FREE_GB=$RUM_PGXS_BIG_VALUES_MIN_FREE_GB" )
fi

for v in RUM_PGLIST_SHARED_BUFFERS RUM_PGLIST_MAINTENANCE_WORK_MEM RUM_PGLIST_MAX_WAL_SIZE RUM_PGLIST_WORK_MEM; do
	if [[ "${!v+set}" == "set" ]]; then
		docker_cmd+=( -e "$v=${!v}" )
	fi
done

docker_cmd+=(
	"$IMAGE"
	bash -s -- "$QUIET" "$PG_MAJOR" "$PGPORT"
)

if ((${#INSTALLCHECK_ARGS[@]})); then
	docker_cmd+=("${INSTALLCHECK_ARGS[@]}")
fi

"${docker_cmd[@]}" <<'EOF'
set -euo pipefail

quiet="$1"
pg_major="$2"
pgport="$3"
shift 3
installcheck_args=("$@")

export PATH="/usr/lib/postgresql/${pg_major}/bin:$PATH"

work_dir="${RUM_PGXS_WORK_DIR:-/work/rum}"
source_dir="${RUM_PGXS_SOURCE_DIR:-}"

if [[ -n "$source_dir" ]]; then
	rm -rf "$work_dir"
	mkdir -p "$(dirname "$work_dir")"
	cp -a "$source_dir" "$work_dir"
fi

if [[ "$quiet" == "1" ]]; then
	apt-get update -qq
	apt-get install -y -qq "postgresql-server-dev-${pg_major}" build-essential perl libipc-run-perl wget > /dev/null
	make_flags=(-s)
else
	apt-get update
	apt-get install -y "postgresql-server-dev-${pg_major}" build-essential perl libipc-run-perl wget
	make_flags=()
fi

if [[ "${PG_TEST_EXTRA:-}" =~ (^|[[:space:]])big_values($|[[:space:]]) ]]; then
	min_free_gb="${RUM_PGXS_BIG_VALUES_MIN_FREE_GB:-12}"
	if ! [[ "$min_free_gb" =~ ^[0-9]+$ ]]; then
		echo "error: RUM_PGXS_BIG_VALUES_MIN_FREE_GB must be an integer (got: $min_free_gb)" >&2
		exit 2
	fi
	avail_kb="$(df -Pk "$work_dir" | awk 'NR==2{print $4}')"
	need_kb="$((min_free_gb * 1024 * 1024))"
	if (( avail_kb < need_kb )); then
		echo "error: PG_TEST_EXTRA=big_values requires at least ${min_free_gb}GB free in $work_dir." >&2
		echo "error: available: $((avail_kb / 1024 / 1024))GB. Increase VM/disk space or lower RUM_PGXS_BIG_VALUES_MIN_FREE_GB." >&2
		exit 2
	fi

	# Constrained-memory default profile for t/002_pglist.pl, overridable via env.
	: "${RUM_PGLIST_SHARED_BUFFERS:=1GB}"
	: "${RUM_PGLIST_MAINTENANCE_WORK_MEM:=512MB}"
	: "${RUM_PGLIST_MAX_WAL_SIZE:=2GB}"
	: "${RUM_PGLIST_WORK_MEM:=32MB}"
fi

cd "$work_dir"
make "${make_flags[@]}" USE_PGXS=1 clean
make "${make_flags[@]}" USE_PGXS=1 install

chown -R postgres:postgres "$work_dir"
su postgres -c "export PATH=/usr/lib/postgresql/${pg_major}/bin:\$PATH; initdb -D /tmp/pgdata >/tmp/initdb.log"
su postgres -c "echo port=${pgport} >> /tmp/pgdata/postgresql.conf"
su postgres -c "export PATH=/usr/lib/postgresql/${pg_major}/bin:\$PATH; pg_ctl -D /tmp/pgdata -l /tmp/pg.log -w start"

cleanup() {
	su postgres -c "export PATH=/usr/lib/postgresql/${pg_major}/bin:\$PATH; pg_ctl -D /tmp/pgdata -m fast stop" >/dev/null 2>&1 || true
}
trap cleanup EXIT

make_flags_str=""
if ((${#make_flags[@]})); then
	printf -v make_flags_str ' %q' "${make_flags[@]}"
fi

installcheck_args_str=""
if ((${#installcheck_args[@]})); then
	printf -v installcheck_args_str ' %q' "${installcheck_args[@]}"
fi

pg_test_extra_str=""
if [[ "${PG_TEST_EXTRA+set}" == "set" ]]; then
	printf -v pg_test_extra_str ' PG_TEST_EXTRA=%q' "$PG_TEST_EXTRA"
fi

pglist_env_str=""
for v in RUM_PGLIST_SHARED_BUFFERS RUM_PGLIST_MAINTENANCE_WORK_MEM RUM_PGLIST_MAX_WAL_SIZE RUM_PGLIST_WORK_MEM; do
	if [[ "${!v+set}" == "set" ]]; then
		printf -v pglist_env_str '%s %s=%q' "$pglist_env_str" "$v" "${!v}"
	fi
done

work_dir_quoted=""
printf -v work_dir_quoted '%q' "$work_dir"

set +e
su postgres -c "cd ${work_dir_quoted} && export PATH=/usr/lib/postgresql/${pg_major}/bin:\$PATH; PGPORT=${pgport} PGUSER=postgres${pg_test_extra_str}${pglist_env_str} make${make_flags_str} USE_PGXS=1 installcheck${installcheck_args_str}"
status=$?
set -e

if (( status != 0 )); then
	log_dir="$work_dir/tmp_check/log"
	if [[ -d "$log_dir" ]]; then
		echo "--- begin failing TAP logs (if present) ---" >&2
		for f in \
			"$log_dir/regress_log_002_pglist" \
			"$log_dir/002_pglist_master.log" \
			"$log_dir/regress_log_003_rum_debug_funcs" \
			"$log_dir/regress_log_001_wal"; do
			if [[ -f "$f" ]]; then
				echo "--- $f ---" >&2
				tail -n 200 "$f" >&2 || true
			fi
		done
		echo "--- end failing TAP logs ---" >&2
	fi
	exit "$status"
fi
EOF
