#!/usr/bin/env bash
# Container entrypoint: translates the external env-var contract into the
# .env file every benchmarks/<name>/run.sh already expects (`set -a; source .env;
# set +a`), then dispatches based on the arguments docker was run with.
#
# Usage (see deployment/README.md for full examples):
#   docker run -e API_KEY=... -e OPENAI_BASE_URL=... -e MODEL_NAME=... \
#     image [general] [coding] [agentic]        # run_main_benchmark.sh categories
#   docker run ... image gpqa [args...]          # one benchmark by name (benchmarks/<name>/run.sh)
#   docker run ... image benchmarks/gpqa/run.sh  # same, by path (any script under scripts/ also works)
set -euo pipefail
cd /app

: "${API_KEY:?API_KEY is required}"
: "${OPENAI_BASE_URL:?OPENAI_BASE_URL is required}"
: "${MODEL_NAME:?MODEL_NAME is required}"

cat > /app/.env <<EOF
API_KEY=${API_KEY}
OPENAI_BASE_URL=${OPENAI_BASE_URL}
MODEL_NAME=${MODEL_NAME}
HF_TOKEN=${HF_TOKEN:-}
EOF

# HLE judge knobs: only written when actually passed with -e. Writing an unset
# one as an empty line is not neutral -- benchmarks/hle/run.sh reads HLE_SECOND_JUDGE=
# (set but empty) as "no second judge", which silently dropped the default
# cross-check judge in every container run.
for _v in HLE_MAIN_JUDGE HLE_SECOND_JUDGE HLE_SELF_JUDGE \
          HLE_JUDGE_BASE_URL HLE_JUDGE_API_KEY; do
  if [[ -n "${!_v+x}" ]]; then
    printf '%s=%s\n' "$_v" "${!_v}" >> /app/.env
  fi
done

# --- Jobs dir ----------------------------------------------------------------
# SWE-bench Pro eval and DeepSWE (pier) bind-mount subdirs of the jobs dir into
# sibling containers via the host docker socket. The HOST daemon resolves those
# source paths on the host, so a container-only path like /app/jobs/... makes
# it silently mount an empty dir (entryscript exit 127, RewardFileNotFoundError).
# Mount the jobs dir at the same absolute path inside and out:
#   -v "$PWD/jobs:$PWD/jobs" -e JOBS_ROOT="$PWD/jobs"
# /app/jobs then symlinks to it so every other benchmark lands there too.
JOBS_ROOT="${JOBS_ROOT:-/app/jobs}"
export JOBS_ROOT
if [[ "$JOBS_ROOT" != /app/jobs ]]; then
  if [[ ! -d "$JOBS_ROOT" ]]; then
    echo "ERROR: JOBS_ROOT=$JOBS_ROOT is not a directory; mount it with" >&2
    echo "  -v \"$JOBS_ROOT:$JOBS_ROOT\"" >&2
    exit 1
  fi
  if mountpoint -q /app/jobs 2>/dev/null; then
    echo "ERROR: both /app/jobs and JOBS_ROOT=$JOBS_ROOT are mounted; drop the /app/jobs mount." >&2
    exit 1
  fi
  ln -sfn "$JOBS_ROOT" /app/jobs
fi

# Ask the host daemon to mount JOBS_ROOT into a throwaway container and check
# it sees a marker we just wrote. Fails when the paths differ between here and
# the host (e.g. the old `-v jobs:/app/jobs` mount).
check_jobs_root_visible_to_host() {
  local image marker ok=0
  image="$(docker inspect -f '{{.Config.Image}}' "$HOSTNAME" 2>/dev/null)" || {
    echo "WARNING: couldn't identify this container's image; skipping JOBS_ROOT host-visibility check." >&2
    return 0
  }
  mkdir -p "$JOBS_ROOT"
  marker=".host-visibility-probe-$HOSTNAME-$$"
  : > "$JOBS_ROOT/$marker"
  docker run --rm --network none -v "$JOBS_ROOT:/probe:ro" --entrypoint /bin/sh \
    "$image" -c "test -f /probe/$marker" >/dev/null 2>&1 || ok=1
  rm -f "$JOBS_ROOT/$marker"
  if [[ $ok -ne 0 ]]; then
    echo "ERROR: the host docker daemon can't see JOBS_ROOT=$JOBS_ROOT at the same path." >&2
    echo "Nested containers would mount an empty dir and every instance would score 0." >&2
    echo "Re-run with: -v \"\$PWD/jobs:\$PWD/jobs\" -e JOBS_ROOT=\"\$PWD/jobs\"" >&2
    exit 1
  fi
}

needs_docker() {
  case " $* " in
    *" agentic "*|*" swebench_pro "*|*" deepswe "*|*benchmarks/swebench_pro/*|*benchmarks/deepswe/*) return 0 ;;
    *) return 1 ;;
  esac
}

if needs_docker "$@"; then
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: this task launches per-instance/per-task Docker containers," >&2
    echo "but /var/run/docker.sock isn't reachable from inside this container." >&2
    echo "Re-run with: -v /var/run/docker.sock:/var/run/docker.sock" >&2
    exit 1
  fi
  check_jobs_root_visible_to_host
  case " $* " in
    *" agentic "*|*" swebench_pro "*|*benchmarks/swebench_pro/*)
      bash /app/benchmarks/swebench_pro/prepare_data.sh
      ;;
  esac
fi

# Direct invocation: a benchmark by name (`image gpqa`, `image deepswe 20 8`) or
# a script by path (`image benchmarks/gpqa/run.sh`, `image scripts/progress.sh`).
if [[ "${1:-}" =~ ^(scripts|benchmarks)/.*\.sh$ ]]; then
  exec bash "$@"
fi
if [[ -n "${1:-}" && "$1" != _* && -f "benchmarks/$1/run.sh" ]]; then
  _b="$1"; shift
  exec bash "benchmarks/$_b/run.sh" "$@"
fi

# Otherwise treat args as run_main_benchmark.sh category names
# (general/coding/agentic); defaults to all three (the Dockerfile's CMD).
exec bash scripts/run_main_benchmark.sh "$@"
