#!/usr/bin/env bash
# Reclaim docker disk for DeepSWE trials that have finished.
#
# pier names every trial's compose project <task>__<7 random chars>, so each
# run creates fresh <trial>-main / <trial>-pier-egress-proxy / <trial>__verifier__*-main
# tags. pier means to `compose down --rmi all` at the end, but the agent env is
# already marked stopped by then (it is stopped with keep_images=True before
# verification), so the images are never removed and pile up across runs.
#
# A trial that has a result.json is finished, so its images are safe to remove.
# Layers shared with other tags (same task, other runs) are kept by docker
# until the last tag goes; `docker rmi` without -f also refuses in-use images.
#
# Only repositories named exactly like pier trial images AND whose task prefix
# is a directory under deep-swe/tasks are touched. quality-bench, jefzda/*,
# base images etc. can never match.
#
# Usage:
#   RUN_ID=<id> bash benchmarks/deepswe/prune_loop.sh    # loop: prune finished trials
#   RUN_ID=<id> bash benchmarks/deepswe/prune_loop.sh --once  # single pass, no loop
#   bash benchmarks/deepswe/prune_loop.sh --sweep        # once: prune ALL stale pier images
#
# Env: INTERVAL (180s), JOBS_ROOT, JOBS_DIR, TASKS_DIR, DRY_RUN=1 (list only),
#      PRUNE_BUILD_CACHE=1 (loop: also `docker builder prune` when the docker data root
#      is above CACHE_PCT, default 85; this cache is host-global, so opt-in).
set -uo pipefail
cd "$(dirname "$0")/../.."

INTERVAL="${INTERVAL:-180}"
# The docker data root is not always /var/lib/docker (here it is /mnt/docker).
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
TASKS_DIR="${TASKS_DIR:-deep-swe/tasks}"
DRY_RUN="${DRY_RUN:-0}"
CACHE_PCT="${CACHE_PCT:-85}"
SUFFIX_RE='__[a-z0-9]{7}(__verifier__[a-z0-9_]+)?-(main|pier-egress-proxy)'

is_task_image() {  # <repo> -> 0 if it looks like a pier trial image of a known task
  local repo="$1" prefix
  [[ "$repo" =~ ^(.+)${SUFFIX_RE}$ ]] || return 1
  prefix="${BASH_REMATCH[1]}"
  [[ -d "$TASKS_DIR" ]] || return 0
  # pier truncates long task names, so compare as a prefix.
  local t
  for t in "$TASKS_DIR"/*/; do
    t="$(basename "$t")"
    [[ "$t" == "$prefix"* ]] && return 0
  done
  return 1
}

rm_image() {
  if [[ "$DRY_RUN" == 1 ]]; then echo "would remove $1"; return; fi
  docker rmi "$1" >/dev/null 2>&1 && echo "removed $1" || echo "kept (in use/shared) $1"
}

# Images of trials with a result.json under $1 (a job dir or a run's deepswe dir).
finished_trial_images() {
  local r trial base
  while IFS= read -r r; do
    trial="$(basename "$(dirname "$r")")"
    base="${trial,,}"
    docker images --format '{{.Repository}}' \
      | grep -E "^${base//./\\.}(__verifier__[a-z0-9_]+)?-(main|pier-egress-proxy)$" || true
  done < <(find "$1" -mindepth 3 -maxdepth 3 -name result.json 2>/dev/null)
}

if [[ "${1:-}" == "--sweep" ]]; then
  # Refuse if a trial is live: the trial containers carry the compose project label.
  while IFS= read -r p; do
    if is_task_image "${p}-main"; then
      echo "a DeepSWE trial is running ($p); refusing to sweep" >&2; exit 1
    fi
  done < <(docker ps --format '{{.Label "com.docker.compose.project"}}' | sort -u)
  while IFS= read -r repo; do
    is_task_image "$repo" && rm_image "$repo:latest"
  done < <(docker images --format '{{.Repository}}' | sort -u)
  docker system df | sed -n '1,3p'
  exit 0
fi

RUN_ID="${RUN_ID:?set RUN_ID (or use --sweep)}"
JOBS_ROOT="${JOBS_ROOT:-jobs}"
JOBS_DIR="${JOBS_DIR:-$JOBS_ROOT/$RUN_ID/deepswe}"

if [[ "${1:-}" == "--once" ]]; then
  # Single pass, no loop/sleep: called by run.sh right after its own
  # pier run/resume returns, when every trial under JOBS_DIR (including the
  # last one) is guaranteed finished. This is what makes cleanup not depend on
  # a sidecar's polling interval still being alive at that exact moment.
  if [[ -d "$JOBS_DIR" ]]; then
    while IFS= read -r repo; do
      is_task_image "$repo" && rm_image "$repo:latest"
    done < <(finished_trial_images "$JOBS_DIR" | sort -u)
  fi
  exit 0
fi

while true; do
  if [[ -d "$JOBS_DIR" ]]; then
    echo "--- $(date '+%F %T') docker disk $(df -h --output=pcent "$DOCKER_ROOT" 2>/dev/null | tail -1 | tr -d ' ')"
    while IFS= read -r repo; do
      is_task_image "$repo" && rm_image "$repo:latest"
    done < <(finished_trial_images "$JOBS_DIR" | sort -u)
    if [[ "${PRUNE_BUILD_CACHE:-0}" == 1 && "$DRY_RUN" != 1 ]]; then
      pct="$(df --output=pcent "$DOCKER_ROOT" 2>/dev/null | tail -1 | tr -dc 0-9)"
      [[ -n "$pct" && "$pct" -ge "$CACHE_PCT" ]] && docker builder prune -f --filter until=1h | tail -1
    fi
  fi
  sleep "$INTERVAL"
done
