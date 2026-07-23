# OpenClaw Railway Template

## Open Backlog (remove when resolved)

- [SLA-205](https://linear.app/slaytek-systems/issue/SLA-205) — Refactor `entrypoint.sh` (~800 lines, 12+ jobs) into `lib/` helpers. Triggered by upstream-churn patches needing edits across 4 sections.

## Overview

Secure OpenClaw deployment for Railway. Zero SSH required - configure entirely via environment variables.

## Quick Start

1. Deploy to Railway
2. Set environment variables:
   - `OPENROUTER_API_KEY` (recommended — one key, all models)
   - `LLM_PRIMARY_MODEL` (e.g., `openrouter/minimax/MiniMax-M2.5`)
   - `TELEGRAM_BOT_TOKEN` (or Discord/Slack)
   - `TELEGRAM_OWNER_ID` (your user ID)
3. Deploy - bot is ready

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 RAILWAY CONTAINER                    │
│                                                      │
│  Health Server (:8080)     Gateway (:18789)         │
│  - /healthz for Railway    - Runs on loopback       │
│  - No sensitive info       - Handles channels       │
│                            - Runs agents            │
│                                                      │
│  Config: /data/.openclaw/openclaw.json (600)        │
│  Workspace: /data/workspace                         │
└─────────────────────────────────────────────────────┘
```

## How It Works

1. Container starts
2. `entrypoint.sh` runs `build-config.js`
3. Config generated from environment variables
4. Secure defaults applied (Tier 0)
5. Gateway starts automatically
6. Owner pre-approved in allowlist

## Security Model

**Default (Tier 0):**
- Tools: read/write/edit/memory + exec (ls only)
- Blocked: browser, process, nodes, web
- Gateway: Loopback only, token auth
- Sessions: Isolated per user
- Access: Owner allowlisted, others pair

**See:** docs/TIERS.md for unlocking more capabilities

## Files

```
openclaw-railway/
├── Dockerfile           # Single-stage, npm install
├── railway.toml         # Railway config
├── entrypoint.sh        # Builds config, starts gateway
├── config-watcher.sh    # Fallback for manual onboard
├── package.json         # No dependencies
├── src/
│   ├── server.js        # Health check (~30 lines)
│   └── build-config.js  # Env vars → config
└── config/
    ├── defaults.json    # Secure base config
    ├── environment.md   # Env var reference
    ├── exec-approvals-tier0.json  # Exec allowlist for Tier 0
    ├── exec-approvals-tier1.json  # Exec allowlist for Tier 1
    └── tier-inject/     # Tier-specific markdown injected into AGENTS.md & TOOLS.md at deploy
        ├── agents-tier{0,1,2,3}.md  # Injected at <!-- TIER_INJECT -->
        └── tools-tier{0,1,2,3}.md   # Injected at <!-- TOOLS_TIER_INJECT -->
```

## Environment Variables

See config/environment.md for full list.

**Required:**
- One LLM provider key
- One channel token
- Owner ID for that channel

**Optional:**
- Model selection (primary, heartbeat, subagent)
- Multiple channels
- Gateway token override

## Commands (SSH)

Only needed for debugging or manual config:

```bash
# View logs
cat /data/.openclaw/gateway.log

# Security audit
openclaw security audit --deep

# Restart gateway
pkill -f "openclaw gateway"
openclaw gateway run --port 18789 &
```

## Updating

Redeploy the container:
```bash
railway up
```

Never run `openclaw update` inside the container.

## OpenClaw Version Upgrade Protocol

Do not update `OPENCLAW_VERSION` directly or rely on upstream auto-updates. Follow the harness-agnostic workflow in [`docs/OPENCLAW-UPGRADE-PROTOCOL.md`](docs/OPENCLAW-UPGRADE-PROTOCOL.md).

Minimum gates before promotion:

1. Confirm the candidate package exists.
2. Run local Docker validation: `bun run openclaw:validate:local -- <version>`.
3. Run Railway staging validation: `bun run openclaw:validate:railway -- <version>`.
4. Verify plugin discovery and configured channels, especially Discord.
5. Promote only after all gates pass, then monitor production.
6. Tag the known-good template release after production passes.

## Internal Directory (`/internal/`)

The `internal/` directory is gitignored and contains local-only development docs that are NOT shipped with the public template:

- `VISION.md` — Project ethos, design principles, target audience, the "why" behind everything
- `RESEARCH.md` — Original deployment research, hypotheses, experiments
- `THREAT-MODEL.md` — Detailed threat model (root-level version with full architecture diagrams)
- `IDEAS.md` — Content ideas, use cases, product roadmap
- `FUTURE-ARCHITECTURE.md` — Multi-environment deployment strategy, commercial plans
- `openclaw.example.json` — Example config reference

These files contain valuable context for development but are not relevant to template users. Do not move them back into tracked directories.

## Key Docs

- https://docs.openclaw.ai/gateway/security
- https://docs.openclaw.ai/gateway/configuration
- https://docs.openclaw.ai/tools
