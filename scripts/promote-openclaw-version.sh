#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: bun run openclaw:promote -- <openclaw-version>"
  exit 2
fi

SAFE_VERSION="$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '_')"
LOCAL_SUMMARY="$(find ".validation/openclaw/${SAFE_VERSION}" -path '*/summary.json' -not -path '*-railway/*' -not -path '*-sentinel/*' -not -path '*-channel-smoke/*' -print 2>/dev/null | sort | tail -1 || true)"
RAILWAY_SUMMARY="$(find ".validation/openclaw/${SAFE_VERSION}" -path '*-railway/summary.json' -print 2>/dev/null | sort | tail -1 || true)"
CHANNEL_SUMMARY="$(find ".validation/openclaw/${SAFE_VERSION}" -path '*-channel-smoke/summary.json' -print 2>/dev/null | sort | tail -1 || true)"

if [[ -z "$LOCAL_SUMMARY" || -z "$RAILWAY_SUMMARY" || -z "$CHANNEL_SUMMARY" ]]; then
  echo "ERROR: promotion requires passing local, Railway staging, and channel-scope validation artifacts."
  echo "Local summary:   ${LOCAL_SUMMARY:-missing}"
  echo "Railway summary: ${RAILWAY_SUMMARY:-missing}"
  echo "Channel summary: ${CHANNEL_SUMMARY:-missing}"
  exit 1
fi

node - "$LOCAL_SUMMARY" "$RAILWAY_SUMMARY" "$CHANNEL_SUMMARY" <<'NODE'
const fs = require('fs');
const [localPath, railwayPath, channelPath] = process.argv.slice(2);
const local = JSON.parse(fs.readFileSync(localPath, 'utf8'));
const railway = JSON.parse(fs.readFileSync(railwayPath, 'utf8'));
const channel = JSON.parse(fs.readFileSync(channelPath, 'utf8'));
for (const [path, summary] of [[localPath, local], [railwayPath, railway]]) {
  if (summary.status !== 'pass') {
    console.error(`ERROR: validation summary is not passing: ${path}`);
    process.exit(1);
  }
}
if (local.target !== 'local-docker' || railway.target !== 'railway-staging' || channel.target !== 'staging-channel-smoke') {
  console.error('ERROR: validation artifact target types are invalid.');
  process.exit(1);
}
if (
  local.version !== railway.version ||
  local.repoCommit !== railway.repoCommit ||
  local.workspaceFingerprint !== railway.workspaceFingerprint
) {
  console.error('ERROR: local and Railway evidence do not describe the same candidate and repository state.');
  process.exit(1);
}
if (railway.externalHealth !== 'pass') {
  console.error('ERROR: Railway staging external health evidence is missing.');
  process.exit(1);
}
if (!['pass', 'not_in_scope'].includes(channel.status)) {
  console.error('ERROR: staging channel smoke evidence is missing.');
  process.exit(1);
}
for (const key of ['version', 'repoCommit', 'workspaceFingerprint']) {
  if (channel[key] !== local[key]) {
    console.error(`ERROR: channel evidence does not match local and Railway evidence: ${key}.`);
    process.exit(1);
  }
}
if (channel.railwaySummary !== railwayPath) {
  console.error('ERROR: channel evidence was recorded against a different Railway staging run.');
  process.exit(1);
}
NODE

CURRENT_CONTEXT="$(node scripts/lib/release-sentinel-contract.js context "$ROOT_DIR")"
node - "$LOCAL_SUMMARY" "$CURRENT_CONTEXT" "$VERSION" <<'NODE'
const fs = require('fs');
const [path, rawContext, version] = process.argv.slice(2);
const summary = JSON.parse(fs.readFileSync(path, 'utf8'));
const context = JSON.parse(rawContext);
if (summary.version !== version) {
  console.error(`ERROR: evidence is for ${summary.version}, not ${version}.`);
  process.exit(1);
}
if (summary.repoCommit !== context.repoCommit || summary.workspaceFingerprint !== context.workspaceFingerprint) {
  console.error('ERROR: validation evidence is stale for the current repository state.');
  process.exit(1);
}
NODE

CURRENT="$(node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync('.openclaw-version.json','utf8')).version)")"

node - "$VERSION" <<'NODE'
const fs = require('fs');
const { execFileSync } = require('child_process');
const version = process.argv[2];
const path = '.openclaw-version.json';
const data = JSON.parse(fs.readFileSync(path, 'utf8'));
const previous = data.version;
let latest = '';
try {
  const raw = execFileSync('bun', ['pm', 'view', 'openclaw', 'dist-tags', '--json'], { encoding: 'utf8' });
  latest = JSON.parse(raw).latest || '';
} catch {
  latest = '';
}
data.version = version;
data.channel = version === latest || !version.includes('-') ? 'stable' : 'prerelease';
data.promotedAt = new Date().toISOString().slice(0, 10);
data.validatedBy = 'local-docker+railway-staging';
data.notes = `Promoted after local Docker and Railway staging validation. Previous version: ${previous}.`;
fs.writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
NODE

node - "$VERSION" <<'NODE'
const fs = require('fs');
const version = process.argv[2];
const path = 'Dockerfile';
let text = fs.readFileSync(path, 'utf8');
text = text.replace(/^ARG OPENCLAW_VERSION=.*$/m, `ARG OPENCLAW_VERSION=${version}`);
fs.writeFileSync(path, text);
NODE

cat <<EOF
Promoted OpenClaw ${CURRENT} -> ${VERSION}

Updated:
- Dockerfile
- .openclaw-version.json

Evidence:
- ${LOCAL_SUMMARY}
- ${RAILWAY_SUMMARY}
- ${CHANNEL_SUMMARY}
EOF
