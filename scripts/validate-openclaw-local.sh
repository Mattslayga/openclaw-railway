#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: bun run openclaw:validate:local -- <openclaw-version>"
  exit 2
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1"
    exit 1
  fi
}

require_cmd bun
require_cmd docker
require_cmd node

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
SAFE_VERSION="$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '_')"
ARTIFACT_DIR=".validation/openclaw/${SAFE_VERSION}/${RUN_ID}"
IMAGE_TAG="openclaw-railway:validate-${SAFE_VERSION}"
CONTAINER_NAME="openclaw-railway-validate-${SAFE_VERSION}-${RUN_ID}"
LOG_FILE="${ARTIFACT_DIR}/container.log"
SUMMARY_JSON="${ARTIFACT_DIR}/summary.json"
REPORT_MD="${ARTIFACT_DIR}/report.md"
CONTEXT_JSON="${ARTIFACT_DIR}/context.json"

mkdir -p "$ARTIFACT_DIR"
node scripts/lib/release-sentinel-contract.js context "$ROOT_DIR" > "$CONTEXT_JSON"

finish() {
  local exit_code=$?
  if [[ "$exit_code" -ne 0 && ! -f "$SUMMARY_JSON" ]]; then
    write_summary "fail" "validation exited unexpectedly with status ${exit_code}"
    cat > "$REPORT_MD" <<EOF
# OpenClaw Local Validation: ${VERSION}

Status: FAIL
Reason: validation exited unexpectedly with status ${exit_code}
Evidence context: ${CONTEXT_JSON}
EOF
  fi
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap finish EXIT

write_summary() {
  local status="$1"
  local reason="$2"
  node - "$SUMMARY_JSON" "$CONTEXT_JSON" "$VERSION" "$status" "$reason" "$RUN_ID" <<'NODE'
const fs = require('fs');
const [path, contextPath, version, status, reason, runId] = process.argv.slice(2);
const context = JSON.parse(fs.readFileSync(contextPath, 'utf8'));
fs.writeFileSync(path, JSON.stringify({
  target: 'local-docker',
  version,
  status,
  reason,
  runId,
  ...context,
  generatedAt: new Date().toISOString(),
}, null, 2) + '\n');
NODE
}

capture_container_artifacts() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker logs "$CONTAINER_NAME" >"$LOG_FILE" 2>&1 || true
    mkdir -p "${ARTIFACT_DIR}/stability"
    docker cp "${CONTAINER_NAME}:/data/.openclaw/logs/stability/." "${ARTIFACT_DIR}/stability/" >/dev/null 2>&1 || true
    docker cp "${CONTAINER_NAME}:/data/.openclaw/openclaw.json" "${ARTIFACT_DIR}/openclaw.json" >/dev/null 2>&1 || true
  fi
}

fail() {
  local reason="$1"
  capture_container_artifacts
  write_summary "fail" "$reason"
  {
    echo "# OpenClaw Local Validation: ${VERSION}"
    echo
    echo "Status: FAIL"
    echo "Reason: ${reason}"
    echo
    echo "Artifacts:"
    echo "- ${LOG_FILE}"
    echo "- ${SUMMARY_JSON}"
    echo "- ${CONTEXT_JSON}"
    echo "- ${ARTIFACT_DIR}/stability/"
  } > "$REPORT_MD"
  echo "FAIL: $reason"
  echo "Report: $REPORT_MD"
  exit 1
}

echo "[validate-local] Checking npm package exists: openclaw@${VERSION}"
VERSIONS_JSON="$(bun pm view openclaw versions --json)"
node - "$VERSION" "$VERSIONS_JSON" <<'NODE' || fail "openclaw@${VERSION} does not exist on npm"
const [version, raw] = process.argv.slice(2);
const versions = JSON.parse(raw);
if (!versions.includes(version)) process.exit(1);
NODE

echo "[validate-local] Building Docker image with OPENCLAW_VERSION=${VERSION}"
docker build \
  --build-arg "OPENCLAW_VERSION=${VERSION}" \
  -t "$IMAGE_TAG" \
  . >"${ARTIFACT_DIR}/docker-build.log" 2>&1 || fail "docker build failed"

echo "[validate-local] Verifying installed OpenClaw version"
INSTALLED_VERSION="$(docker run --rm --entrypoint openclaw "$IMAGE_TAG" --version 2>/dev/null | tr -d '\r' | tail -1 || true)"
if [[ "$INSTALLED_VERSION" != *"$VERSION"* ]]; then
  echo "$INSTALLED_VERSION" > "${ARTIFACT_DIR}/installed-version.txt"
  fail "installed version did not match candidate"
fi

echo "[validate-local] Verifying Telegram group access defaults"
docker run --rm --entrypoint sh \
  -e OPENCLAW_CONFIG_PATH=/tmp/openclaw.json \
  -e OPENROUTER_API_KEY=validation-openrouter-key \
  -e LLM_PRIMARY_MODEL=openrouter/openai/gpt-4o-mini \
  -e TELEGRAM_BOT_TOKEN=validation-telegram-token \
  -e TELEGRAM_OWNER_ID=111111111 \
  "$IMAGE_TAG" -c '
    node /app/src/build-config.js >/dev/null &&
    node -e "
      const fs = require(\"fs\");
      const config = JSON.parse(fs.readFileSync(\"/tmp/openclaw.json\", \"utf8\"));
      const telegram = config.channels?.telegram;
      if (telegram?.groupPolicy !== \"allowlist\") throw new Error(\"Telegram owner group policy is not allowlist\");
      if (!telegram?.groupAllowFrom?.includes(111111111)) throw new Error(\"Telegram owner is missing from groupAllowFrom\");
      if (telegram?.groups?.[\"*\"]?.requireMention !== true) throw new Error(\"Telegram groups do not require mentions\");
    "
  ' || fail "Telegram owner group access is not fail-closed"

docker run --rm --entrypoint sh \
  -e OPENCLAW_CONFIG_PATH=/tmp/openclaw.json \
  -e OPENROUTER_API_KEY=validation-openrouter-key \
  -e LLM_PRIMARY_MODEL=openrouter/openai/gpt-4o-mini \
  -e TELEGRAM_BOT_TOKEN=validation-telegram-token \
  "$IMAGE_TAG" -c '
    node /app/src/build-config.js >/dev/null &&
    node -e "
      const fs = require(\"fs\");
      const config = JSON.parse(fs.readFileSync(\"/tmp/openclaw.json\", \"utf8\"));
      if (config.channels?.telegram?.groupPolicy !== \"disabled\") throw new Error(\"Telegram groups are enabled without an owner\");
    "
  ' || fail "Telegram groups are not disabled without an owner"

echo "[validate-local] Booting container"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 0:8080 \
  -e PORT=8080 \
  -e OPENROUTER_API_KEY="validation-openrouter-key" \
  -e LLM_PRIMARY_MODEL="openrouter/openai/gpt-4o-mini" \
  -e BRAVE_API_KEY="dummy-brave-key" \
  -e SECURITY_TIER="0" \
  -e DISCORD_BOT_TOKEN="dummy-discord-token" \
  -e DISCORD_OWNER_ID="111111111111111111" \
  -e DISCORD_GUILD_ID="222222222222222222" \
  -e DISCORD_GUILD_CHANNELS="333333333333333333,444444444444444444" \
  -e DISCORD_MENTION_NOT_REQUIRED_CHANNELS="444444444444444444" \
  "$IMAGE_TAG" >/dev/null || fail "container failed to start"

HEALTH_URL=""
# Match Railway's cold-start allowance. Candidate CLI/plugin initialization can
# take several minutes on a fresh volume, especially under emulated local Docker.
for _ in $(seq 1 300); do
  docker logs "$CONTAINER_NAME" >"$LOG_FILE" 2>&1 || true
  HOST_PORT="$(docker port "$CONTAINER_NAME" 8080/tcp 2>/dev/null | sed 's/.*://g' | head -1 || true)"
  if [[ -n "$HOST_PORT" ]]; then
    HEALTH_URL="http://127.0.0.1:${HOST_PORT}/healthz"
    if docker exec "$CONTAINER_NAME" curl -sf "http://localhost:8080/healthz" >/dev/null 2>&1; then
      break
    fi
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker logs "$CONTAINER_NAME" >"$LOG_FILE" 2>&1 || true
    fail "container exited before health check passed"
  fi
  sleep 2
done

docker logs "$CONTAINER_NAME" >"$LOG_FILE" 2>&1 || true

if ! docker exec "$CONTAINER_NAME" curl -sf "http://localhost:8080/healthz" >/dev/null 2>&1; then
  fail "healthz did not become healthy"
fi

echo "[validate-local] Verifying runtime process isolation"
docker exec "$CONTAINER_NAME" ps -eo user,uid,pid,ppid,args > "${ARTIFACT_DIR}/processes.txt"
if ! docker exec "$CONTAINER_NAME" sh -c '
  gateway_pids="$(pgrep -x openclaw 2>/dev/null || true)"
  [ -n "$gateway_pids" ] || exit 1
  for pid in $gateway_pids; do
    [ "$(stat -c %u "/proc/$pid")" = "1001" ] || exit 1
  done
  ! pgrep -u 0 -x openclaw >/dev/null 2>&1
'; then
  fail "gateway process is missing or running as root"
fi
if ! docker exec "$CONTAINER_NAME" sh -c '
  found=0
  for pid in $(pgrep -x node 2>/dev/null || true); do
    command="$(tr "\000" " " < "/proc/$pid/cmdline")"
    case "$command" in
      *"node src/server.js"*)
        found=1
        [ "$(stat -c %u "/proc/$pid")" = "1001" ] || exit 1
        ;;
    esac
  done
  [ "$found" = "1" ]
'; then
  fail "health server is missing or running as root"
fi

echo "[validate-local] Inspecting generated config and permissions"
docker exec "$CONTAINER_NAME" test -f /data/.openclaw/openclaw.json || fail "config file missing"
docker exec "$CONTAINER_NAME" su openclaw -c "HOME=/home/openclaw OPENCLAW_STATE_DIR=/data/.openclaw OPENCLAW_CONFIG_PATH=/data/.openclaw/openclaw.json openclaw config validate --json" >"${ARTIFACT_DIR}/config-validate.json" 2>&1 || fail "openclaw config schema validation failed"
CONFIG_MODE="$(docker exec "$CONTAINER_NAME" stat -c '%U:%G %a' /data/.openclaw/openclaw.json 2>/dev/null || true)"
if [[ "$CONFIG_MODE" != "root:openclaw 640" ]]; then
  echo "$CONFIG_MODE" > "${ARTIFACT_DIR}/config-mode.txt"
  fail "config permissions changed"
fi

STATE_DIR_MODE="$(docker exec "$CONTAINER_NAME" stat -c '%U:%G %a' /data/.openclaw 2>/dev/null || true)"
if [[ "$STATE_DIR_MODE" != "root:openclaw 1770" ]]; then
  echo "$STATE_DIR_MODE" > "${ARTIFACT_DIR}/state-dir-mode.txt"
  fail "state directory permissions changed"
fi

APPROVALS_MODE="$(docker exec "$CONTAINER_NAME" stat -c '%U:%G %a' /data/.openclaw/exec-approvals.json 2>/dev/null || true)"
if [[ "$APPROVALS_MODE" != "openclaw:openclaw 600" ]]; then
  echo "$APPROVALS_MODE" > "${ARTIFACT_DIR}/exec-approvals-mode.txt"
  fail "state-dir exec approvals permissions changed"
fi

if docker exec "$CONTAINER_NAME" su openclaw -c "rm /data/.openclaw/openclaw.json" >/dev/null 2>&1; then
  fail "openclaw user could remove root-owned config"
fi

echo "[validate-local] Verifying Discord plugin discovery"
docker exec "$CONTAINER_NAME" timeout 300 su openclaw -c \
  "HOME=/home/openclaw OPENCLAW_STATE_DIR=/data/.openclaw OPENCLAW_CONFIG_PATH=/data/.openclaw/openclaw.json openclaw plugins list --json" \
  >"${ARTIFACT_DIR}/plugins-list.json" 2>&1 || fail "Discord plugin discovery command failed"
EXPECTED_DISCORD_VERSION="$(printf '%s' "$VERSION" | sed -E 's/-[0-9]+$//')"
node - "${ARTIFACT_DIR}/plugins-list.json" "$EXPECTED_DISCORD_VERSION" <<'NODE' || fail "Discord plugin is not enabled, loaded, and version-aligned"
const fs = require('fs');
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expectedVersion = process.argv[3];
const discord = payload.plugins?.find((plugin) => plugin.id === 'discord');
if (!discord || discord.enabled !== true || discord.status !== 'loaded') process.exit(1);
if (discord.version !== expectedVersion) process.exit(1);
if (discord.dependencyStatus?.requiredInstalled !== true) process.exit(1);
NODE

docker exec "$CONTAINER_NAME" node -e "
const fs = require('fs');
const config = JSON.parse(fs.readFileSync('/data/.openclaw/openclaw.json', 'utf8'));
if (config.tools?.exec?.security !== 'allowlist') throw new Error('Tier 0 exec security is not allowlist');
if (config.tools?.exec?.strictInlineEval !== true) throw new Error('Tier 0 strictInlineEval hardening is not enabled');
if (!config.tools?.fs?.workspaceOnly) throw new Error('workspaceOnly fs policy is not enabled');
const guild = config.channels?.discord?.guilds?.['222222222222222222'];
if (!guild) throw new Error('Discord guild config was not generated');
if (!guild.channels?.['333333333333333333'] || typeof guild.channels['333333333333333333'] !== 'object') throw new Error('Discord allowlisted channel entry was not generated');
if (guild.channels?.['333333333333333333']?.allow !== undefined) throw new Error('Discord channel config contains invalid legacy allow property');
if (guild.channels?.['444444444444444444']?.requireMention !== false) throw new Error('Discord mention opt-out channel missing requireMention=false');
if (!config.plugins?.allow?.includes('discord')) throw new Error('Discord plugin trust allowlist was not generated');
if (config.tools?.web?.search?.provider === 'brave') throw new Error('Brave web_search provider should not be configured when unavailable');
" || fail "security config assertions failed"

docker exec "$CONTAINER_NAME" node -e "
const fs = require('fs');
const approvals = JSON.parse(fs.readFileSync('/data/.openclaw/exec-approvals.json', 'utf8'));
const entries = approvals.agents?.main?.allowlist || [];
if (entries.length === 0) throw new Error('Tier 0 approvals are empty');
for (const entry of entries) {
  if (!entry.argPattern) throw new Error(entry.id + ' has unrestricted arguments');
  const pattern = new RegExp(entry.argPattern);
  if (pattern.test('/data/.openclaw')) throw new Error(entry.id + ' allows absolute sensitive paths');
  if (pattern.test('../.openclaw')) throw new Error(entry.id + ' allows path traversal');
}
" || fail "deployed exec approvals are not argument-constrained"

echo "[validate-local] Scanning logs for blocker patterns"
if grep -Ei 'openclaw\.json\.clobbered|SECRETREF_FAIL|permission denied|EACCES|Cannot find module|Module not found|ready \(0 plugins\)|Gateway exited immediately|Watchdog: gateway process gone|UnhandledPromiseRejection|CIAO PROBING CANCELLED' "$LOG_FILE" \
  | grep -Eiv "failed to persist plugin auto-enable changes|failed to promote config last-known-good backup" \
  > "${ARTIFACT_DIR}/blockers.txt"; then
  fail "blocker log pattern found"
fi

write_summary "pass" "all local Docker gates passed"
{
  echo "# OpenClaw Local Validation: ${VERSION}"
  echo
  echo "Status: PASS"
  echo "Run: ${RUN_ID}"
  echo "Image: ${IMAGE_TAG}"
  echo "Health URL: ${HEALTH_URL}"
  echo "Evidence context: ${CONTEXT_JSON}"
  echo
  echo "Gates:"
  echo "- npm package exists"
  echo "- Docker image builds"
  echo "- installed version matches"
  echo "- Telegram group access is owner-only and fails closed without an owner"
  echo "- container boots"
  echo "- /healthz passes"
  echo "- gateway and health server run as non-root uid 1001"
  echo "- config exists with root:openclaw 640"
  echo "- state dir is root:openclaw 1770 and sticky-bit protects root-owned config"
  echo "- state-dir exec approvals are openclaw:openclaw 600 for atomic updates"
  echo "- Discord plugin is explicitly trusted, enabled, loaded, and dependency-complete"
  echo "- OpenClaw config schema validation passes"
  echo "- Tier 0 exec allowlist arguments, strictInlineEval, workspaceOnly, and Discord guild config assertions pass"
  echo "- blocker log scan passes"
} > "$REPORT_MD"

echo "PASS: local Docker validation passed"
echo "Report: $REPORT_MD"
