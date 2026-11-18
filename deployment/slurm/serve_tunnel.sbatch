#!/bin/bash
# Serve a model with SGLang inside a Slurm job and expose it on the benchmark host via a reverse SSH tunnel.
#
#   job node:  sglang on 127.0.0.1:$PORT (never a public port)
#              ssh -N -R 127.0.0.1:$REMOTE_PORT:127.0.0.1:$PORT  -> benchmark host
#   bench host: http://127.0.0.1:$REMOTE_PORT/v1  (run the benchmark container with --network host)
#
# Usage (from the Slurm login node):
#   sbatch -p hardware-hcm -w hgx-h200-01 --gres=gpu:1 \
#     --export=ALL,MODEL=Qwen/Qwen3-8B,EXTRA_ARGS="--reasoning-parser qwen3 --tool-call-parser qwen25" \
#     deployment/slurm/serve_tunnel.sbatch
#
# Env params:
#   MODEL        HF repo id (resolved in $HF_CACHE) or an absolute model dir      (required)
#   SERVED_NAME  name exposed by /v1/models                                         (default: $MODEL)
#   TP           tensor parallel size; should match --gres=gpu:N                   (default: GPUs allocated)
#   SQSH         SGLang enroot image   (default: v0.5.23 on hgx /mnt/sqsh or b300 /mnt/containers)
#   EXTRA_ARGS   extra sglang.launch_server args (parsers, context length, ...)
#   REMOTE_PORT  port on the benchmark host; must match the key's permitlisten     (default: 18000)
#   TUNNEL_HOST / TUNNEL_PORT / TUNNEL_KEY   benchmark host ssh target
#
# The API key is generated per job and written to /shared/phucnlt2/serve/<jobid>.key (mode 600).
# Tunnel key setup (one-time): /shared/phucnlt2/.ssh/tunnel_key, whose public half sits in the
# benchmark host's authorized_keys as
#   restrict,port-forwarding,permitlisten="127.0.0.1:18000",command="/bin/false" ssh-ed25519 ...
#SBATCH --job-name=serve-tunnel
#SBATCH --nodes=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=120G
#SBATCH --time=01:00:00
#SBATCH --output=/shared/phucnlt2/job-logs/serve-tunnel_%j.out
#SBATCH --error=/shared/phucnlt2/job-logs/serve-tunnel_%j.out
set -uo pipefail

: "${MODEL:?MODEL is required}"
HF_CACHE=${HF_CACHE:-/mnt/hf_hub_cache}
REMOTE_PORT=${REMOTE_PORT:-18000}
TUNNEL_HOST=${TUNNEL_HOST:-phucnlt2@61.28.228.170}
TUNNEL_PORT=${TUNNEL_PORT:-234}
TUNNEL_KEY=${TUNNEL_KEY:-/shared/phucnlt2/.ssh/tunnel_key}
TUNNEL_KNOWN_HOSTS=${TUNNEL_KNOWN_HOSTS:-/shared/phucnlt2/.ssh/known_hosts_tunnel}
EXTRA_ARGS=${EXTRA_ARGS:-}
JOB=${SLURM_JOB_ID:-$$}
NGPU=$(echo "${CUDA_VISIBLE_DEVICES:-0}" | tr ',' '\n' | wc -l)
TP=${TP:-$NGPU}

R=/mnt/phucnlt2                       # node-local scratch (models/images never go to /shared)
CTMP=$R/ctmp/$JOB
mkdir -p "$CTMP" $R/enroot/{cache,data,tmp} /shared/phucnlt2/serve
export ENROOT_CACHE_PATH=$R/enroot/cache ENROOT_DATA_PATH=$R/enroot/data TMPDIR=$R/enroot/tmp
export NVIDIA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-all}   # only the GPUs Slurm gave us

if [[ -z "${SQSH:-}" ]]; then
  for c in /mnt/sqsh/lmsysorg_sglang_v0.5.23.sqsh /mnt/containers/lmsysorg_sglang_v0.5.23.sqsh; do
    [[ -f $c ]] && { SQSH=$c; break; }
  done
fi
if [[ "$MODEL" = /* ]]; then
  MODEL_PATH=$MODEL
else
  MODEL_PATH=$(ls -d "$HF_CACHE/models--${MODEL//\//--}"/snapshots/* 2>/dev/null | head -1)
fi
SERVED_NAME=${SERVED_NAME:-$MODEL}
[[ -f "${SQSH:-}" ]] || { echo "✗ no SGLang sqsh found (set SQSH)"; exit 1; }
[[ -f "$MODEL_PATH/config.json" ]] || { echo "✗ model not found: $MODEL ($MODEL_PATH)"; exit 1; }
[[ -f "$TUNNEL_KEY" ]] || { echo "✗ tunnel key missing: $TUNNEL_KEY"; exit 1; }
command -v ssh >/dev/null || { echo "✗ no ssh client on $(hostname)"; exit 1; }

PORT=$(( 20000 + JOB % 20000 ))
API_KEY=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
KEYFILE=/shared/phucnlt2/serve/$JOB.key
( umask 077; printf '%s\n' "$API_KEY" > "$KEYFILE" )
SERVER_LOG=/shared/phucnlt2/job-logs/serve-tunnel_${JOB}.server.log

echo "=== job $JOB on $(hostname) $(date '+%F %T')"
echo "model=$MODEL_PATH served_name=$SERVED_NAME tp=$TP gpus=$NVIDIA_VISIBLE_DEVICES"
echo "sqsh=$SQSH local_port=$PORT remote=127.0.0.1:$REMOTE_PORT@${TUNNEL_HOST#*@}"
echo "api key file: $KEYFILE   server log: $SERVER_LOG"
df -h $R | tail -1

SERVER_PID= TUNNEL_PID=
cleanup() {
  trap - EXIT INT TERM
  echo "=== cleanup $(date +%T)"
  [[ -n $TUNNEL_PID ]] && kill -- -"$TUNNEL_PID" 2>/dev/null
  if [[ -n $SERVER_PID ]]; then
    kill -- -"$SERVER_PID" 2>/dev/null; sleep 10; kill -9 -- -"$SERVER_PID" 2>/dev/null
  fi
  rm -f "$KEYFILE"; rm -rf "$CTMP"
}
trap cleanup EXIT INT TERM

# --- SGLang server (own process group so cleanup can kill the whole tree) ---
# shellcheck disable=SC2086
setsid enroot start \
  --mount "$HF_CACHE:$HF_CACHE" --mount "$R:$R" --mount "$CTMP:/tmp" \
  --env HOME=/tmp --env HF_HUB_OFFLINE=1 \
  "$SQSH" \
  python3 -m sglang.launch_server --model-path "$MODEL_PATH" --served-model-name "$SERVED_NAME" \
    --host 127.0.0.1 --port "$PORT" --tp-size "$TP" --api-key "$API_KEY" --trust-remote-code \
    $EXTRA_ARGS \
  > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

ok=0
for _ in $(seq 360); do   # 5 s each, up to 30 min
  curl -sf -H "Authorization: Bearer $API_KEY" "http://127.0.0.1:$PORT/health" >/dev/null && { ok=1; break; }
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 5
done
if [[ $ok != 1 ]]; then echo "✗ server did not come up; log tail:"; tail -60 "$SERVER_LOG"; exit 1; fi
echo "✓ server up $(date +%T)"
curl -s -H "Authorization: Bearer $API_KEY" "http://127.0.0.1:$PORT/v1/models"; echo

# --- reverse tunnel, reconnecting while the server lives ---
setsid bash -c '
  while kill -0 '"$SERVER_PID"' 2>/dev/null; do
    ssh -N -i "'"$TUNNEL_KEY"'" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o UserKnownHostsFile="'"$TUNNEL_KNOWN_HOSTS"'" -o StrictHostKeyChecking=yes \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -R 127.0.0.1:'"$REMOTE_PORT"':127.0.0.1:'"$PORT"' -p '"$TUNNEL_PORT"' '"$TUNNEL_HOST"'
    echo "tunnel dropped (rc=$?) $(date +%T); retry in 10s"; sleep 10
  done' &
TUNNEL_PID=$!
echo "✓ tunnel started -> ${TUNNEL_HOST#*@}:127.0.0.1:$REMOTE_PORT $(date +%T)"

wait "$SERVER_PID"
echo "server exited rc=$? $(date +%T)"; tail -20 "$SERVER_LOG"
