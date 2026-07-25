# Sandboxing Guide

Sandboxing isolates agent execution in Docker containers, preventing compromised agents from accessing your system.

## Why Sandbox?

Without sandboxing, an agent can:
- Read/write any file the `openclaw` user can access
- Execute any command
- Access network resources
- Read your API keys and secrets

With sandboxing:
- Agent runs in isolated Docker container
- Limited filesystem access
- Network can be restricted
- Cannot access host system

## Enable Sandboxing

### Via CLI

```bash
openclaw configure --section sandbox
```

### Via Config

In `openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "non-main",
        "workspaceAccess": "rw"
      }
    }
  }
}
```

## Sandbox Modes

### `off` (Default)

No sandboxing. Agent runs directly on host.

```json
{
  "sandbox": {
    "mode": "off"
  }
}
```

**Use when:** You trust the input source (e.g., only you use the bot).

### `non-main` (Recommended)

Sandbox channel sessions (Telegram, Discord) but not direct CLI usage.

```json
{
  "sandbox": {
    "mode": "non-main"
  }
}
```

**Use when:** Multiple people use your bot via channels.

### `all`

Sandbox everything, including CLI sessions.

```json
{
  "sandbox": {
    "mode": "all"
  }
}
```

**Use when:** Maximum isolation required.

## Workspace Access

Controls what files the sandboxed agent can access.

### `none`

Agent cannot access any workspace files.

```json
{
  "sandbox": {
    "mode": "non-main",
    "workspaceAccess": "none"
  }
}
```

### `ro` (Read-Only)

Agent can read but not modify workspace files.

```json
{
  "sandbox": {
    "mode": "non-main",
    "workspaceAccess": "ro"
  }
}
```

### `rw` (Read-Write)

Agent can read and write workspace files.

```json
{
  "sandbox": {
    "mode": "non-main",
    "workspaceAccess": "rw"
  }
}
```

## Sandbox Scope

### `agent` Scope

Sandbox persists for the agent's lifetime. Shared workspace at:
```
~/.openclaw/agents/<id>/sandbox-workspace
```

### `session` Scope

New sandbox per conversation. Temporary directory cleaned up after session ends.

## Per-Channel Configuration

Different sandbox settings per channel:

```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "off"
      }
    }
  },
  "channels": {
    "telegram": {
      "sandbox": {
        "mode": "non-main",
        "workspaceAccess": "ro"
      }
    },
    "discord": {
      "sandbox": {
        "mode": "all",
        "workspaceAccess": "none"
      }
    }
  }
}
```

## Railway: The Container IS Your Sandbox

On Railway, OpenClaw's Docker-based sandboxing won't work because Railway doesn't expose Docker to your container. But here's the thing: **the Railway container itself is already a sandbox**.

Your agent cannot:
- Escape the container
- Access Railway's host system
- Affect other Railway users
- Touch your local machine

What OpenClaw's sandboxing would add is isolating *each agent session* in its own throwaway container - useful if multiple untrusted users share your bot. For a personal bot, the Railway container boundary is sufficient.

**The security model for Railway:**

| Layer | What It Does |
|-------|--------------|
| Railway container | Hard boundary - agent can't escape |
| Tool restrictions | Limits what agent can do inside |
| Pairing | Controls who can use the bot |

This is a reasonable security posture for personal use.

## Tool Restrictions (Railway's Alternative)

Instead of Docker sandboxing, this template uses three complementary mechanisms:

### 1. Workspace-Only Filesystem Sandbox

The most important protection. Restricts the agent's `read`, `write`, and `edit` tools to the workspace directory only:

```json
{
  "tools": {
    "fs": {
      "workspaceOnly": true
    }
  }
}
```

Any attempt to access files outside `/data/workspace/` is rejected with "Path escapes sandbox root." This blocks reading secrets (`/proc/self/environ`, config files) and writing to security-critical files (`exec-approvals.json`, `openclaw.json`).

**Note:** `exec` does not use the filesystem tool sandbox. At Tiers 0-1, both command names and arguments are restricted to workspace-relative operations. At Tier 2+, exec is unrestricted — the behavioral template is the primary defense against config and process reads.

### 2. Tool Policy (openclaw.json)

Controls which tools the agent can use. Configured via `SECURITY_TIER` env var:

```json
{
  "agents": {
    "defaults": {
      "tools": {
        "allow": ["read", "write", "edit", "memory_get", "memory_search", "web_search", "web_fetch", "exec", "cron"],
        "deny": ["process", "browser", "nodes", "gateway", "agents_list", "sessions_spawn"]
      }
    }
  }
}
```

### 3. Linux File Permissions (defense in depth)

The entrypoint hardens file ownership as a backup layer:

| What's protected | How |
|-----------------|-----|
| `openclaw.json` (config) | `root:openclaw 640` — agent cannot write |
| `/data/.openclaw/` | `root:openclaw 1770` — sticky bit protects root-owned config while the runtime atomically updates state |
| `/home/openclaw/.openclaw/` | `root:openclaw 750` — legacy approvals directory is not writable |
| `/data/.openclaw/exec-approvals.json` | `openclaw:openclaw 600` — current runtime updates approvals atomically |
| `/home/openclaw/.openclaw/exec-approvals.json` | `root:openclaw 660` — compatibility path for older runtimes |
| Behavioral templates | `root:openclaw 440` — restored from image on every startup |
| Non-essential env vars | Scrubbed from environment after config generation |

### 4. Upstream SSRF Hardening (built into OpenClaw v2026.2.12+)

The gateway blocks `web_fetch` requests to private/internal hostnames, loopback addresses, and IPv4-mapped IPv6 literals. This is enforced at the gateway level — no configuration needed.

**No URL allowlist (accepted residual risk):** Neither upstream nor this template provides a domain allowlist for `web_fetch`/`web_search`. Upstream attempted it twice (PRs #18584 and #19042, both abandoned). Data exfiltration via `web_fetch` GET parameters to external URLs remains possible — mitigated by `workspaceOnly` (restricts what can be read), `web_fetch` being GET-only (limits payload size), and behavioral templates (instruct refusal). See [SECURITY.md](SECURITY.md#accepted-residual-risk-web_fetch-exfiltration) for the full rationale and when this template is not appropriate.

### Exec Allowlist (exec-approvals.json)

Controls which shell commands the agent can run, deployed as a separate file at `~/.openclaw/exec-approvals.json` (resolves to `/home/openclaw/.openclaw/exec-approvals.json` in the container — this is the `openclaw` user's home directory, **not** the state directory at `/data/.openclaw/`). See [TIERS.md](TIERS.md) for per-tier allowlists.

## Recommended Configuration

For Railway with channel access, the default Tier 0 configuration is recommended. It provides:

- Tool policy limiting available tools
- Exec restricted to `ls` only via allowlist
- Config files write-locked via Linux permissions
- Pairing required for non-owner users

See [TIERS.md](TIERS.md) for how to progressively unlock more capabilities.

## Further Reading

- [OpenClaw Sandboxing Docs](https://docs.openclaw.ai/concepts/sandboxing)
- [Tool Security](https://docs.openclaw.ai/tools/security)
