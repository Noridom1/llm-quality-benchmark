#!/usr/bin/env bash
# Container entrypoint: translates the external env-var contract into the
# .env file every scripts/run_*.sh already expects (`set -a; source .env;
# set +a`), then dispatches based on the arguments docker was run with.
#
# Usage (see deployment/README.md for full examples):
#   docker run -e API_KEY=... -e OPENAI_BASE_URL=... -e MODEL_NAME=... \
#     image [general] [coding] [agentic]        # run_main_benchmark.sh categories
#   docker run ... image scripts/run_gpqa.sh    # a single benchmark script directly
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
HLE_MAIN_JUDGE=${HLE_MAIN_JUDGE:-}
HLE_SECOND_JUDGE=${HLE_SECOND_JUDGE:-}
HLE_SELF_JUDGE=${HLE_SELF_JUDGE:-}
EOF

needs_docker() {
  case " $* " in
    *" agentic "*|*" swebench_pro "*|*" deepswe "*|*run_swebench_pro.sh*|*run_deepswe*) return 0 ;;
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
  case " $* " in
    *" agentic "*|*" swebench_pro "*|*run_swebench_pro.sh*)
      bash /app/deployment/prepare-swebench-pro-data.sh
      ;;
  esac
fi

# Direct single-script invocation, e.g. `docker run ... image scripts/run_gpqa.sh`.
if [[ "${1:-}" == scripts/*.sh ]]; then
  exec bash "$@"
fi

# Otherwise treat args as run_main_benchmark.sh category names
# (general/coding/agentic); defaults to all three (the Dockerfile's CMD).
exec bash scripts/run_main_benchmark.sh "$@"
