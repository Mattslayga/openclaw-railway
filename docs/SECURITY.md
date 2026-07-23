# Security Model

This template ships with secure defaults. This document explains what's protected and how.

## The Three Security Layers

OpenClaw has three complementary security mechanisms:

| Layer | What It Does | Works on Railway? |
|-------|--------------|-------------------|
| **Tool Policy** | Controls which tools agents can use | Yes |
| **Sandbox** | Isolates execution in Docker containers | No (requires Docker-in-Docker) |
| **Elevated Mode** | Escape hatch for host exec when sandboxed | Yes (disabled by default) |

Since Railway doesn't support Docker-in-Docker, this template relies on **Tool Policy** and **Linux File Permissions** as the primary security mechanisms.

## Default Configuration (Tier 0)

Out of the box, your agent can:
- Chat via messaging channels
- Read/write files in the workspace
- Fetch and read web pages
- Search memories (auto-configured with OpenRouter/OpenAI)
- List directories (`ls` only)
- Schedule cron jobs

Everything else is blocked:

```json5
{
  agents: {
    defaults: {
      tools: {
        allow: ["read", "write", "edit", "memory_get", "memory_search", "web_search", "web_fetch", "exec", "cron", "image"],
        deny: ["process", "browser", "nodes", "gateway", "agents_list", "sessions_spawn"]
      }
    }
  }
}
```

### Filesystem Protection

This template uses two complementary mechanisms to protect sensitive files:

#### 1. Workspace-Only Sandbox (`tools.fs.workspaceOnly`)

The agent's `read`, `write`, and `edit` tools are restricted to the workspace directory (`/data/workspace/`). Any attempt to access files outside the workspace is rejected by the gateway with "Path escapes sandbox root."

```json5
{
  tools: {
    fs: {
      workspaceOnly: true
    }
  }
}
```

This blocks:
- Reading `/proc/self/environ` (API keys, tokens)
- Reading `/data/.openclaw/openclaw.json` (config and SecretRef metadata)
- Writing to either exec approvals file through agent filesystem tools (exec policy)
- Any file access outside `/data/workspace/`

The gateway must receive provider and channel secrets in its process environment
so OpenClaw can resolve the SecretRef objects in `openclaw.json`. Those values are
not written as plaintext to the config file. Tier 0-1 exec rules prevent absolute
paths and path traversal, including reads from `/proc`; Tier 2+ full shell access
can read same-user process environments and must be treated as trusted access.

#### 2. Linux File Permissions (defense in depth)

The entrypoint also hardens file ownership as a second layer. Even if `workspaceOnly` were bypassed, OS permissions prevent writes to critical files:

| Path | Owner | Perms | Purpose |
|------|-------|-------|---------|
| `/data/.openclaw/openclaw.json` | root:openclaw | 640 | Config — gateway reads, agent can't write |
| `/data/.openclaw/` directory | root:openclaw | 1770 | Runtime can atomically update state; sticky bit protects root-owned config |
| `/home/openclaw/.openclaw/` | root:openclaw | 750 | Agent can't create new files |
| `/data/.openclaw/exec-approvals.json` | openclaw:openclaw | 600 | Current runtime atomically updates approvals metadata |
| `/home/openclaw/.openclaw/exec-approvals.json` | root:openclaw | 660 | Compatibility path for older pinned runtimes |
| `/data/workspace/AGENTS.md` etc. | root:openclaw | 440 | Shipped templates — read-only |
| `/data/workspace/MEMORY.md` etc. | openclaw:openclaw | 644 | User files — read/write |

Behavioral template files (`AGENTS.md`, `TOOLS.md`, `PROGRESSION.md`, `PROJECTS.md`) are locked to `root:openclaw 440` and forcibly restored from the container image on every startup. This prevents a prompt injection from persistently rewriting the agent's safety instructions.

#### 3. Runtime User Isolation

The entrypoint starts the gateway and health server as the `openclaw` user
(`uid 1001`). A root-owned `su` wrapper can appear in process listings, but the
actual `openclaw` and health-server processes are non-root. Child processes,
including scheduled and heartbeat work, inherit that non-root user. Local
release validation checks this ownership on every candidate.

## What Each Blocked Tool Does

These tools are blocked at Tier 0 (default). See [TIERS.md](docs/TIERS.md) for what each tier unlocks.

| Tool | Risk | Why It's Blocked |
|------|------|------------------|
| `process` | Critical | Manage background processes, bypass approval |
| `browser` | High | Access logged-in sessions, run JavaScript |
| `nodes` | High | Camera/screen capture, device control |
| `gateway` | Critical | Modify gateway configuration |
| `agents_list` | Medium | Enumerate other agents |
| `sessions_spawn` | Medium | Create unlimited subagents |

**Allowed at Tier 0** (with restrictions): `read`, `write`, `edit`, `exec` (ls only), `memory_get`, `memory_search`, `web_search`, `web_fetch`, `cron`.

## Access Control

### Owner Allowlist

When you set `TELEGRAM_OWNER_ID` (or Discord/Slack equivalent), you're added to the allowlist. You can message the bot immediately without pairing. For Telegram, that owner is also the only sender allowed to trigger the bot in groups; group access is disabled when no owner ID is configured.

### Pairing for Others

Anyone else who messages the bot gets a pairing code. They must share it with you, and you approve via SSH:

```bash
openclaw pairing approve telegram <CODE>
```

Or set `dmPolicy: "allowlist"` and manually add user IDs.

### Session Isolation

Each user gets their own conversation context:

```json5
{
  session: {
    dmScope: "per-channel-peer"
  }
}
```

User A cannot see User B's conversation history.

## Gateway Security

The gateway is bound to loopback only:

```json5
{
  gateway: {
    bind: "loopback",
    auth: { mode: "token" }
  }
}
```

This means:
- Gateway is not accessible from outside the container
- Token authentication required for any connection
- Health endpoint (`/healthz`) reveals nothing sensitive

## What Railway Protects

Railway's container provides hard boundaries:

| Protection | Description |
|------------|-------------|
| Container isolation | Agent cannot escape to Railway host |
| Network isolation | No access to other Railway services |
| Volume isolation | `/data` is your persistent storage only |
| Secret injection | Env vars injected at runtime, not stored in image |

## What Railway Cannot Protect

| Risk | Mitigation |
|------|------------|
| Prompt injection | Tool policy limits blast radius |
| API key theft | `workspaceOnly` blocks filesystem-tool reads; config contains SecretRefs instead of plaintext; Tier 0-1 exec arguments cannot reach `/proc`; Tier 2+ remains trusted |
| Data exfiltration via `web_fetch` | `web_fetch` is GET-only (limits payload size to URL parameters); `workspaceOnly` restricts what can be read; behavioral templates instruct refusal of exfil requests. **No URL allowlist** — accepted residual risk, see below |
| Data exfiltration via `exec` | Tiers 0-1 constrain both executable paths and arguments; `strictInlineEval` blocks hidden command execution; Tier 2+ is unrestricted by design |
| Resource exhaustion | Railway's resource limits apply |

## Upstream Security Hardening (v2026.2.12–2026.2.17)

OpenClaw v2026.2.12 through v2026.2.17 included several security fixes that strengthen this template's defenses. These are built into the base image — no configuration needed.

| Fix | Versions | What It Does |
|-----|----------|-------------|
| **OC-09: Exec credential theft** | v2026.2.14, .17 | Blocks `$VAR` injection in exec scripts, fixes `safeBins` shell expansion bypass, removes `node_modules/.bin` from PATH |
| **SSRF hardening** | v2026.2.12, .13, .14 | `web_fetch` blocks loopback/internal hostnames, IPv4-mapped IPv6 bypass patched, private network blocking |
| **Session transcript permissions** | v2026.2.14, .17 | New transcripts created with `0o600` (user-only) permissions |
| **`$include` config traversal** | v2026.2.14, .17 | Config includes confined to config directory, symlink checks hardened |
| **Sandbox Docker injection** | v2026.2.13, .15 | Blocks dangerous Docker config (bind mounts, host networking) |
| **High-risk tools via HTTP** | v2026.2.13 | `sessions_spawn` etc. blocked from `/tools/invoke` HTTP endpoint |
| **`apply_patch` traversal** | v2026.2.14 | Enforces workspace-root path bounds |

### Accepted residual risk: `web_fetch` exfiltration

This template does not enforce a URL/domain allowlist on `web_fetch` or `web_search`. A prompt-injected agent can be induced to send workspace contents (notes, memory files, conversation history) to an attacker-controlled URL via GET parameters.

**Upstream status:** Two attempts have been made and abandoned — PR #18584 was merged then reverted in v2026.2.17, and PR #19042 was closed stale on 2026-04-03. No further attempts are tracked upstream.

**Why this template does not provide its own allowlist:**

- `workspaceOnly` is the load-bearing defense — the agent cannot read secrets, config files, `/proc/self/environ`, or anything outside `/data/workspace/`. What remains exfiltratable is limited to the user's own workspace content.
- `web_fetch` is GET-only, capping payload size per request to what fits in URL parameters.
- Behavioral templates in `AGENTS.md` instruct the agent to refuse suspicious URL-sending requests (reliability depends on model compliance).
- Building a URL allowlist ourselves (via proxy sidecar or upstream fork) is fragile ongoing work with a small marginal benefit against the threats this template is designed for.

**What this means for you:**

- If your workspace holds only your own notes and chat history, this is a reasonable residual risk. Behavioural guardrails plus `workspaceOnly` are your defense.
- **If your deployment handles third-party data** (e.g. customer messages, shared documents, anything under compliance obligations), the exfiltration surface is material — either wait for upstream to land an allowlist, run behind an egress-filtered proxy, or don't use this template.

### Defense-in-Depth Summary

This template combines upstream gateway hardening with its own security layers:

1. **`tools.fs.workspaceOnly: true`** — Blocks file access outside workspace
2. **Non-root process isolation** — Gateway and health server run as `uid 1001`; only the gateway receives required secrets
3. **Linux file permissions** — Config 640, protected state directory 1770, behavioral templates 440
4. **Exec allowlist** — Tier 0-1 restrict both executable paths and argument shapes
5. **Behavioral templates** — Locked and force-restored on every startup
6. **Upstream SSRF guards** — Gateway blocks private/internal hostnames
7. **Upstream OC-09 fix** — Exec env var injection patched at gateway level

## Skills and Plugins

OpenClaw's extension ecosystem ([ClawHub](https://clawhub.ai/)) is gated by the tier system through exec access:

| Tier | Skill Installation | Skill Usage |
|------|-------------------|-------------|
| 0-1 | Blocked (no exec access to `openclaw` or `clawhub` binaries) | Pre-installed and HTTP-based skills work |
| 2-3 | Available via `openclaw skills install` or `clawhub install` | All skills work |

**What this means for security:**

- **Tiers 0-1 are safe from skill-based attacks.** The agent cannot install new skills because it lacks exec access to the installation binaries. Pre-installed skills (placed in `/data/workspace/skills/` by the operator) work fine.
- **Tier 2+ can self-install skills.** If the agent is socially engineered into running `openclaw skills install <malicious-skill>`, full exec mode means no approval gate — commands run immediately. Treat this the same as the general "full exec" risk at Tier 2.
- **No skill-level allowlist exists.** There's no gateway config to restrict which skills can load. You can disable specific skills with `skills.entries.<name>.enabled: false`, but there's no allowlist equivalent.
- **HTTP-based skills bypass exec restrictions.** A skill that teaches the agent to call an external HTTP API works at Tier 0 via `web_fetch`. This is by design — the skill itself is just instructions, and `web_fetch` is already allowed. The security boundary for these skills is on the external service (authentication, rate limiting, read-only keys).

**Recommendations:**
- Pre-install trusted skills at image build time or via SSH, rather than letting the agent install them at runtime
- Audit ClawHub skills before installation: `openclaw skill audit <skill-name>`
- For external service integrations at Tier 0, use the HTTP API pattern — the agent calls endpoints with `web_fetch`, and the external service enforces its own access control

See [TIERS.md](docs/TIERS.md) for the full skills-by-tier breakdown.

## Unlocking More Capabilities

See [TIERS.md](docs/TIERS.md) for how to progressively enable more agent capabilities.

## Security Audit

SSH in and run:

```bash
openclaw security audit --deep
```

This checks for common misconfigurations.

## Dangerous Configurations

**Never do these:**

| Configuration | Risk |
|---------------|------|
| `gateway.bind: "lan"` | Exposes gateway to network |
| `gateway.bind: "0.0.0.0"` | Exposes gateway to internet |
| `dmPolicy: "open"` | Anyone can use your bot |
| `tools.deny: []` | All tools available |
| `elevated.enabled: true` | Host exec escape available |
| API keys in config file | Stored on disk, potentially leaked |

## Environment Variables

API keys and tokens should always be set as Railway environment variables, not in `openclaw.json`. Railway encrypts these at rest and injects them at runtime.

See [config/environment.md](config/environment.md) for the full list.

## Further Reading

- [OpenClaw Security Docs](https://docs.openclaw.ai/gateway/security)
- [Tool Policy vs Sandbox vs Elevated](https://docs.openclaw.ai/gateway/sandbox-vs-tool-policy-vs-elevated)
- [Threat Model](docs/THREAT-MODEL.md)
