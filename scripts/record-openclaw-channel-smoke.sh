#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
RESULT="${2:-}"
if [[ -z "$VERSION" || ( "$RESULT" != "pass" && "$RESULT" != "not_in_scope" ) ]]; then
  echo "Usage: OPENCLAW_STAGING_CHANNEL_SMOKE_CONFIRMED=1 OPENCLAW_STAGING_CHANNEL_SMOKE_EVIDENCE='<note>' bun run openclaw:record:channel-smoke -- <version> <pass|not_in_scope>"
  exit 2
fi

if [[ "${OPENCLAW_STAGING_CHANNEL_SMOKE_CONFIRMED:-}" != "1" ]]; then
  echo "ERROR: refusing to record channel evidence without OPENCLAW_STAGING_CHANNEL_SMOKE_CONFIRMED=1"
  exit 1
fi

EVIDENCE="${OPENCLAW_STAGING_CHANNEL_SMOKE_EVIDENCE:-}"
if [[ -z "$EVIDENCE" ]]; then
  echo "ERROR: OPENCLAW_STAGING_CHANNEL_SMOKE_EVIDENCE must describe the observed smoke result or why channels are out of scope"
  exit 1
fi

SAFE_VERSION="$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '_')"
RAILWAY_SUMMARY="$(find ".validation/openclaw/${SAFE_VERSION}" -path '*-railway/summary.json' -print 2>/dev/null | sort | tail -1 || true)"
if [[ -z "$RAILWAY_SUMMARY" ]]; then
  echo "ERROR: passing Railway staging evidence is required before recording channel smoke"
  exit 1
fi

CONTEXT_JSON="$(node scripts/lib/release-sentinel-contract.js context "$ROOT_DIR")"
node - "$RAILWAY_SUMMARY" "$CONTEXT_JSON" "$VERSION" <<'NODE'
const fs = require('fs');
const [path, rawContext, version] = process.argv.slice(2);
const railway = JSON.parse(fs.readFileSync(path, 'utf8'));
const context = JSON.parse(rawContext);
if (railway.target !== 'railway-staging' || railway.status !== 'pass' || railway.version !== version || railway.externalHealth !== 'pass') {
  console.error('ERROR: Railway staging evidence is not passing for this candidate.');
  process.exit(1);
}
if (railway.repoCommit !== context.repoCommit || railway.workspaceFingerprint !== context.workspaceFingerprint) {
  console.error('ERROR: Railway staging evidence is stale for the current repository state.');
  process.exit(1);
}
NODE

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
ARTIFACT_DIR=".validation/openclaw/${SAFE_VERSION}/${RUN_ID}-channel-smoke"
mkdir -p "$ARTIFACT_DIR"
CONTEXT_JSON="$CONTEXT_JSON" VERSION="$VERSION" RESULT="$RESULT" EVIDENCE="$EVIDENCE" RAILWAY_SUMMARY="$RAILWAY_SUMMARY" ARTIFACT_DIR="$ARTIFACT_DIR" bun - <<'NODE'
const fs = require('fs');
const context = JSON.parse(process.env.CONTEXT_JSON);
const summary = {
  target: 'staging-channel-smoke',
  version: process.env.VERSION,
  status: process.env.RESULT,
  evidence: process.env.EVIDENCE,
  railwaySummary: process.env.RAILWAY_SUMMARY,
  ...context,
  recordedAt: new Date().toISOString(),
};
fs.writeFileSync(`${process.env.ARTIFACT_DIR}/summary.json`, `${JSON.stringify(summary, null, 2)}\n`);
fs.writeFileSync(`${process.env.ARTIFACT_DIR}/report.md`, [
  `# OpenClaw Staging Channel Smoke: ${summary.version}`,
  '',
  `Status: ${summary.status.toUpperCase()}`,
  `Evidence: ${summary.evidence}`,
  `Railway summary: ${summary.railwaySummary}`,
  `Repository commit: ${summary.repoCommit}`,
  `Workspace fingerprint: ${summary.workspaceFingerprint}`,
  '',
].join('\n'));
NODE

echo "Recorded staging channel smoke: ${RESULT}"
echo "Report: ${ARTIFACT_DIR}/report.md"
