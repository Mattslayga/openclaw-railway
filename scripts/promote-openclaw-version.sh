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
LOCAL_SUMMARY="$(find ".validation/openclaw/${SAFE_VERSION}" -path '*/summary.json' -not -path '*-railway/*' -print 2>/dev/null | sort | tail -1 || true)"
RAILWAY_SUMMARY="$(find ".validation/openclaw/${SAFE_VERSION}" -path '*-railway/summary.json' -print 2>/dev/null | sort | tail -1 || true)"

if [[ -z "$LOCAL_SUMMARY" || -z "$RAILWAY_SUMMARY" ]]; then
  echo "ERROR: promotion requires passing local and Railway staging validation artifacts."
  echo "Local summary:   ${LOCAL_SUMMARY:-missing}"
  echo "Railway summary: ${RAILWAY_SUMMARY:-missing}"
  exit 1
fi

node - "$LOCAL_SUMMARY" "$RAILWAY_SUMMARY" <<'NODE'
const fs = require('fs');
for (const path of process.argv.slice(2)) {
  const summary = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (summary.status !== 'pass') {
    console.error(`ERROR: validation summary is not passing: ${path}`);
    process.exit(1);
  }
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
EOF
