# Threat Model: OpenClaw on Railway

This document is brutally honest about what can go wrong, what's at risk, and who should (and shouldn't) use this deployment model.

## The Setup

- OpenClaw agent running in a Railway container
- No Docker sandboxing (Railway doesn't support privileged mode)
- Security relies on: `workspaceOnly` filesystem sandbox, tool policy, exec allowlist, pairing, container boundary
- Agent exec is restricted by allowlist at Tier 0-1 (Tier 2+ has full exec)
- Only approved users can talk to the bot (pairing)

## What Can Actually Go Wrong

### 1. Prompt Injection via Malicious Website

**Attack**: Agent fetches a webpage containing hidden instructions (HTML comments, white text, CSS-hidden content). Agent follows those instructions.

**Real-world precedent**: OpenAI 2025 - agent scanned a malicious email and sent a resignation letter instead of an out-of-office reply.

**Blast radius**: Agent executes unintended commands with whatever permissions it has. If `workspaceOnly` were disabled, agent could read API keys, config files, and all container data.

### 2. Telegram Account Compromise

**Attack**: Attacker gains access to an approved user's Telegram account (phishing, SIM swap, malware).

**What happens**: Attacker messages the bot as the approved user. Pairing only checks Telegram user ID, not account legitimacy. Attacker has full agent access.

**Blast radius**: Full. Attacker can exfiltrate files, make API calls, modify data, steal credentials stored in workspace.

### 3. API Key Exfiltration

**Attack**: Compromised agent reads `/data/.openclaw/openclaw.json` or environment variables, sends API keys to attacker.

**Real-world costs**:
| Incident | Timeframe | Cost |
|----------|-----------|------|
| OpenAI key leaked to GitHub (2024) | 6 hours | $8,400 |
| Operation Bizarre Bazaar (Dec 2025) | 4.5 days | $50,000 |
| AWS cryptomining campaign (2025) | Days | $300,000+ |

**Blast radius**: Unlimited financial exposure if API keys have no spending limits.

### 4. Data Exfiltration

**Attack**: Compromised agent sends all files from `/data/workspace/` to attacker's Telegram bot or external endpoint.

**What's exposed**:
- Any files you gave the agent access to
- Source code, credentials, private keys if stored in workspace
- Conversation history in gateway logs

**Real-world precedent**: Telegram bots are actively used for instant credential exfiltration in phishing campaigns. Data reaches attackers in seconds.

### 5. Denial of Wallet

**Attack**: Agent enters a loop making expensive API calls, or attacker uses stolen keys externally.

**Cost scenarios**:
| Scenario | Calls/day | Monthly cost |
|----------|-----------|--------------|
| Moderate abuse | 100 | $120 |
| Aggressive loop | 1,000 | $4,500 |
| Full takeover | 10,000+ | $15,000+ |

### 6. Supply Chain Attack

**Attack**: A dependency (npm package) is compromised. Malicious code runs during `npm install` in the Dockerfile.

**Real-world precedent**:
- September 2025: 18 npm packages compromised (debug, chalk, ansi-styles)
- November 2025: Shai-Hulud 2.0 affected 25,000+ repositories

**Blast radius**: Critical. Attacker gets code execution during build. Can steal build secrets, modify the OpenClaw binary, persist across restarts.

### 7. Destructive Commands

**Attack**: Agent runs `rm -rf /` or similar.

**Blast radius**: Low. Container filesystem is destroyed, but `/data` is a mounted volume and survives. Railway restarts the container with clean filesystem. Service outage, but no permanent data loss.

## What Data Is At Risk

| Location | Contents | Can Agent Access? |
|----------|----------|-------------------|
| `/data/.openclaw/openclaw.json` | Gateway config and SecretRef metadata | No (`workspaceOnly` blocks file tools; 640 root:openclaw perms) |
| `/data/workspace/*` | User files | Yes (sandboxed here) |
| Gateway environment | API keys and channel tokens required for SecretRef resolution | Not at Tiers 0-1; Tier 2+ full shell can inspect same-user processes |
| `/data/.openclaw/gateway.log` | Message history, commands | No (`workspaceOnly` blocks access) |

## Financial Risk

### API Costs (Realistic Scenarios)

**You will lose money if**:
- API keys have no spending limits
- You don't monitor usage
- You store production keys in the workspace

**Mitigation**:
- Set spending limits: $50-100/month cap on API keys
- Enable billing alerts at 50%, 80%, 100% of limit
- Use separate keys for this deployment (not production keys)
- Rotate keys monthly

### Railway Costs

- Baseline: $10-20/month (within Pro plan credit)
- If cryptominer deployed: $400-1000/month
- Railway has no per-API-call charges, only compute

## Legal/Reputational Risk

| Scenario | Risk Level | Consequence |
|----------|------------|-------------|
| Bot sends spam | Medium | Telegram ban, reputation damage |
| Bot generates harmful content | High | Potential criminal liability |
| Data breach exposing customer data | Critical | GDPR fines (€10-20M), lawsuits |
| Bot used to attack other systems | Critical | Computer fraud charges |

## Realistic Worst-Case Timeline

1. **Hour 0**: Agent fetches webpage with hidden prompt injection
2. **Hour 1**: Agent reads config, extracts API keys and Telegram token
3. **Hour 2**: Agent exfiltrates `/data/workspace/*` to attacker
4. **Hour 4**: Attacker uses keys externally for thousands of API calls
5. **Hour 8**: Attacker finds GitHub credentials in workspace, clones private repos
6. **Day 2**: Attacker uses Telegram token to spam approved users
7. **Day 3**: You notice unusual Anthropic bill ($500+)

**Total damage**: $500 to $50,000+ depending on attacker motivation and what was in your workspace.

> **With this template's defaults (Tier 0):** Steps 1-2 are blocked. `workspaceOnly` prevents config reads, exec arguments cannot address `/proc` or paths outside the workspace, and file permissions block config writes. The gateway still receives the secrets needed to resolve SecretRefs. At Tier 2+ with full exec, process and config inspection become possible again — see the tier system docs for risk details.

---

## Who Should Use This

### Good For

| Use Case | Why It's OK |
|----------|-------------|
| Personal assistant | Only you use it, you trust yourself |
| Learning/experimentation | Low stakes, you can afford the lesson |
| Limited scope tasks | Agent only accesses non-sensitive data |
| Developers who understand risks | You know what you're exposing |

### Bad For

| Use Case | Why It's Risky |
|----------|----------------|
| Customer data | PII in workspace = breach liability |
| Production API keys | No spending limits = unlimited exposure |
| Shared access | Multiple users = larger attack surface |
| Sensitive credentials | SSH keys, AWS creds in workspace = full compromise |
| High-value targets | If someone would pay to attack you, use something else |

---

## What You Should Never Do

1. **Store production API keys in the workspace** - Use separate, limited keys
2. **Put credentials in the workspace** - No SSH keys, no AWS creds, no GitHub tokens
3. **Store customer/user data** - This is not a compliant environment
4. **Share SSH access** - Railway SSH = full container access
5. **Use unlimited spending API keys** - Set caps, always

## What You Should Do

1. **Set API spending limits** - $50-100/month cap
2. **Keep workspace disposable** - Nothing you can't afford to lose
3. **Monitor usage** - Billing alerts at 50%, 80%, 100%
4. **Rotate keys** - Monthly at minimum
5. **Keep `workspaceOnly` enabled** - Blocks all file access outside `/data/workspace/`
6. **Enable pairing** - Approve users explicitly
7. **Treat as semi-trusted** - Not secure, but bounded

---

## What Railway Cannot Provide

Railway is a fantastic platform, but it has architectural constraints:

| Capability | Railway Support | Why |
|------------|-----------------|-----|
| Docker-in-Docker | No | No privileged mode |
| Firecracker microVMs | No | Not their architecture |
| Custom seccomp profiles | No | Managed infrastructure |
| Custom AppArmor/SELinux | No | Managed infrastructure |
| Docker socket access | No | Security risk for multi-tenant |

**This means**: OpenClaw's Docker-based sandboxing will never work on Railway. However, the exec allowlist IS enforced at Tier 0-1 via `exec-approvals.json` (gateway-level, not Docker-dependent). Combined with `workspaceOnly`, tool policy, and file permissions, there are multiple hard isolation layers beyond just the container boundary.

## When to Use Something Else

Consider alternatives if you need:

| Requirement | Alternative |
|-------------|-------------|
| Docker-based sandboxing | VPS with Docker (DigitalOcean, Hetzner) |
| Hardware-level isolation | Fly.io Machines (Firecracker) |
| Managed sandbox API | E2B, Modal |
| Full compliance | GCP/AWS with your own security controls |
| Maximum control | Local hardware (Beelink, home server) |

---

## Security Layers Explained

### What Actually Protects You

| Layer | What It Does | Effective? |
|-------|--------------|------------|
| Railway container | Can't escape to Railway host | Yes |
| Non-root user | Can't modify system files | Yes |
| `workspaceOnly` sandbox | Blocks all file access outside `/data/workspace/` | Yes (enabled by default) |
| Tool policy | Can disable tools entirely | Yes |
| Pairing | Only approved users | Yes, but account compromise bypasses |
| File permissions (640/750) | Config root-owned, agent can read but not write | Yes |

### What Does NOT Protect You

| "Protection" | Reality |
|--------------|---------|
| Exec allowlist alone | Bypassed at Tier 2+. At Tier 0-1, enforced by gateway via `exec-approvals.json` |
| Restricted shells (rbash) | Not used. Exec-approvals operates at the binary-path level instead |
| Gateway on loopback | Agent runs inside container but `workspaceOnly` blocks file-based gateway access. Gateway token auth still applies for HTTP. |
| Behavioral templates alone | Proven effective (91–95% hardened vs 21% vanilla, A/B tested 2026-03-30 with isolated sessions, 2 models, 24 tests) but bypassable by determined prompt injection. Defense in depth with technical controls is the actual strategy. |

---

## Summary

**Railway OpenClaw is a personal tool, not an enterprise solution.**

It's like keeping your house key under the doormat - fine if you live alone in a low-crime area, terrible if you're storing valuables or have roommates you don't fully trust.

Use it for:
- Your own personal AI assistant
- Learning and experimentation
- Low-stakes automation

Don't use it for:
- Anything with customer data
- Anything with production credentials
- Anything where a breach would hurt

If you need more, look at:
- Local hardware (full control)
- VPS with Docker (enforced sandboxing)
- Fly.io (hardware isolation)
- E2B/Modal (managed sandboxes)
- GCP/AWS (compliance, audit trails)

---

## Further Reading

- [OWASP LLM Top 10 - Prompt Injection](https://genai.owasp.org/llmrisk/llm01-prompt-injection/)
- [Operation Bizarre Bazaar - LLM API Key Theft](https://www.bleepingcomputer.com/news/security/hackers-hijack-exposed-llm-endpoints-in-bizarre-bazaar-operation/)
- [Railway Security Docs](https://docs.railway.com/reference/security)
- [OpenClaw Sandboxing Docs](https://docs.openclaw.ai/concepts/sandboxing)
