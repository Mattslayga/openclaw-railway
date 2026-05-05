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

mkdir -p "$ARTIFACT_DIR"

finish() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap finish EXIT

write_summary() {
  local status="$1"
  local reason="$2"
  node - "$SUMMARY_JSON" "$VERSION" "$status" "$reason" "$RUN_ID" <<'NODE'
const fs = require('fs');
const [path, version, status, reason, runId] = process.argv.slice(2);
fs.writeFileSync(path, JSON.stringify({
  target: 'local-docker',
  version,
  status,
  reason,
  runId,
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

echo "[validate-local] Booting container"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 0:8080 \
  -e PORT=8080 \
  -e OPENROUTER_API_KEY="validation-openrouter-key" \
  -e LLM_PRIMARY_MODEL="openrouter/openai/gpt-4o-mini" \
  -e SECURITY_TIER="0" \
  "$IMAGE_TAG" >/dev/null || fail "container failed to start"

HEALTH_URL=""
for _ in $(seq 1 45); do
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

echo "[validate-local] Inspecting generated config and permissions"
docker exec "$CONTAINER_NAME" test -f /data/.openclaw/openclaw.json || fail "config file missing"
CONFIG_MODE="$(docker exec "$CONTAINER_NAME" stat -c '%U:%G %a' /data/.openclaw/openclaw.json 2>/dev/null || true)"
if [[ "$CONFIG_MODE" != "root:openclaw 640" ]]; then
  echo "$CONFIG_MODE" > "${ARTIFACT_DIR}/config-mode.txt"
  fail "config permissions changed"
fi

docker exec "$CONTAINER_NAME" node -e "
const fs = require('fs');
const config = JSON.parse(fs.readFileSync('/data/.openclaw/openclaw.json', 'utf8'));
if (config.tools?.exec?.security !== 'allowlist') throw new Error('Tier 0 exec security is not allowlist');
if (!config.tools?.fs?.workspaceOnly) throw new Error('workspaceOnly fs policy is not enabled');
" || fail "security config assertions failed"

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
  echo
  echo "Gates:"
  echo "- npm package exists"
  echo "- Docker image builds"
  echo "- installed version matches"
  echo "- container boots"
  echo "- /healthz passes"
  echo "- config exists with root:openclaw 640"
  echo "- Tier 0 exec allowlist and workspaceOnly assertions pass"
  echo "- blocker log scan passes"
} > "$REPORT_MD"

echo "PASS: local Docker validation passed"
echo "Report: $REPORT_MD"
