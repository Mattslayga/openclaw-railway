#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: bun run openclaw:validate:railway -- <openclaw-version>"
  exit 2
fi

if ! command -v railway >/dev/null 2>&1; then
  echo "ERROR: railway CLI is required for staging validation"
  exit 1
fi

if [[ "${RAILWAY_ENVIRONMENT:-}" != "staging" && "${OPENCLAW_RAILWAY_STAGING_CONFIRMED:-}" != "1" ]]; then
  cat <<'EOF'
ERROR: refusing to deploy without explicit staging confirmation.

Set Railway CLI context to the openclaw-railway staging environment, then run:

  RAILWAY_ENVIRONMENT=staging OPENCLAW_RAILWAY_STAGING_CONFIRMED=1 \
    bun run openclaw:validate:railway -- <version>

This script is intentionally conservative so it does not touch production by
accident.
EOF
  exit 1
fi

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
SAFE_VERSION="$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '_')"
ARTIFACT_DIR=".validation/openclaw/${SAFE_VERSION}/${RUN_ID}-railway"
TMP_DIR="$(mktemp -d)"
mkdir -p "$ARTIFACT_DIR"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[validate-railway] Confirming local candidate passed first"
LATEST_LOCAL_SUMMARY="$(find ".validation/openclaw/${SAFE_VERSION}" -path '*/summary.json' -not -path '*-railway/*' -print 2>/dev/null | sort | tail -1 || true)"
if [[ -z "$LATEST_LOCAL_SUMMARY" ]]; then
  echo "ERROR: no local validation summary found for ${VERSION}"
  echo "Run: bun run openclaw:validate:local -- ${VERSION}"
  exit 1
fi
node - "$LATEST_LOCAL_SUMMARY" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
const summary = JSON.parse(fs.readFileSync(path, 'utf8'));
if (summary.status !== 'pass') {
  console.error(`ERROR: latest local validation is not passing: ${path}`);
  process.exit(1);
}
NODE

echo "[validate-railway] Staging deploy for OpenClaw ${VERSION}"
echo "[validate-railway] This uses Railway's current project/service/environment context."

rsync -a \
  --exclude '.git' \
  --exclude '.validation' \
  --exclude 'internal' \
  --exclude 'node_modules' \
  --exclude '.DS_Store' \
  ./ "$TMP_DIR"/

node - "$TMP_DIR/Dockerfile" "$VERSION" <<'NODE'
const fs = require('fs');
const [path, version] = process.argv.slice(2);
let text = fs.readFileSync(path, 'utf8');
text = text.replace(/^ARG OPENCLAW_VERSION=.*$/m, `ARG OPENCLAW_VERSION=${version}`);
fs.writeFileSync(path, text);
NODE

RAILWAY_ARGS=(up --detach --environment staging --path-as-root --message "Validate OpenClaw ${VERSION}")
if [[ -n "${OPENCLAW_RAILWAY_STAGING_SERVICE:-}" ]]; then
  RAILWAY_ARGS+=(--service "$OPENCLAW_RAILWAY_STAGING_SERVICE")
fi
if [[ -n "${OPENCLAW_RAILWAY_PROJECT_ID:-}" ]]; then
  RAILWAY_ARGS+=(--project "$OPENCLAW_RAILWAY_PROJECT_ID")
fi
RAILWAY_ARGS+=("$TMP_DIR")

railway "${RAILWAY_ARGS[@]}" > "${ARTIFACT_DIR}/railway-up.log" 2>&1

echo "[validate-railway] Waiting for health"
echo "[validate-railway] Waiting for Railway deployment to become active"
SERVICE_NAME="${OPENCLAW_RAILWAY_STAGING_SERVICE:-openclaw-railway-staging}"
STATUS_JSON="${ARTIFACT_DIR}/service-status.json"
ACTIVE="false"
for _ in $(seq 1 90); do
  if railway service status --environment staging --service "$SERVICE_NAME" --json > "$STATUS_JSON" 2>"${ARTIFACT_DIR}/service-status.err"; then
    if node - "$STATUS_JSON" <<'NODE'
const fs = require('fs');
const status = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (status.status === 'SUCCESS' && status.stopped === false) process.exit(0);
process.exit(1);
NODE
    then
      ACTIVE="true"
      break
    fi
  fi
  sleep 10
done

if [[ "$ACTIVE" != "true" ]]; then
  echo "ERROR: staging deployment did not become active"
  cat "$STATUS_JSON" 2>/dev/null || true
  exit 1
fi

HEALTH_URL="${OPENCLAW_STAGING_HEALTH_URL:-}"
if [[ -z "$HEALTH_URL" ]]; then
  echo "OPENCLAW_STAGING_HEALTH_URL is not set; external health URL check skipped."
else
  for _ in $(seq 1 60); do
    if curl -sf "$HEALTH_URL/healthz" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  curl -sf "$HEALTH_URL/healthz" > "${ARTIFACT_DIR}/healthz.txt" || {
    echo "ERROR: staging health check failed"
    exit 1
  }
fi

echo "[validate-railway] Capturing Railway logs"
railway logs --lines 500 > "${ARTIFACT_DIR}/railway.log" 2>&1 || true

if grep -Ei 'openclaw\.json\.clobbered|SECRETREF_FAIL|permission denied|EACCES|Cannot find module|Module not found|ready \(0 plugins\)|Gateway exited immediately|Watchdog: gateway process gone|UnhandledPromiseRejection|CIAO PROBING CANCELLED' "${ARTIFACT_DIR}/railway.log" \
  | grep -Eiv "failed to persist plugin auto-enable changes|failed to promote config last-known-good backup" \
  > "${ARTIFACT_DIR}/blockers.txt"; then
  echo "ERROR: blocker log pattern found"
  exit 1
fi

cat > "${ARTIFACT_DIR}/summary.json" <<EOF
{
  "target": "railway-staging",
  "version": "${VERSION}",
  "status": "pass",
  "reason": "staging deploy/log gates passed",
  "runId": "${RUN_ID}",
  "generatedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

cat > "${ARTIFACT_DIR}/report.md" <<EOF
# OpenClaw Railway Staging Validation: ${VERSION}

Status: PASS
Run: ${RUN_ID}

Gates:
- Prior local Docker validation found
- Railway staging deploy completed
- Railway deployment became active
- Health check passed when OPENCLAW_STAGING_HEALTH_URL was provided
- blocker log scan passed

Manual live-channel smoke test is still required before promotion unless the
staging service is wired with a dedicated test bot and observer automation.
EOF

echo "PASS: Railway staging validation passed"
echo "Report: ${ARTIFACT_DIR}/report.md"
