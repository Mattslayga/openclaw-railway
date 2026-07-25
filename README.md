<p align="center">
  <img src="https://openclaw.ai/favicon.svg" alt="OpenClaw" width="80" height="80">
</p>

<h1 align="center">OpenClaw Railway Template</h1>

> Deploy a security-hardened AI assistant to Railway. Progressive trust, not blind trust.

[OpenClaw](https://openclaw.ai) is an open-source AI assistant platform that connects to your chat apps and runs 24/7. This template deploys it to [Railway](https://railway.com?referralCode=slayga) (a container hosting platform) with security hardening — configure entirely via environment variables, no SSH required.

**New here?** Use the [Setup Wizard](https://mattslayga.github.io/openclaw-railway/) to generate your config in under 3 minutes.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/openclaw-railway?referralCode=slayga&utm_medium=integration&utm_source=template&utm_campaign=generic)

## What You Need

- **Railway account** with Hobby plan ($5/mo — [pricing](https://railway.com/pricing?referralCode=slayga)). This covers the hosting. Links in this guide include a referral code — you get **$20 in free Railway credits** when you sign up through them.
- **OpenRouter API key** — one key, all LLM models. Free to create, pay per use. ([Get one](https://openrouter.ai/keys))
- **Telegram** — to talk to your bot. ([Get the app](https://telegram.org))

New to all of this? Follow the [full setup walkthrough](docs/SETUP.md) — it covers everything from account creation to your first message.

## Quick Start

> **Important:** Fill in at least the 4 variables below **during the deploy flow** before clicking Deploy. Railway does not keep unfilled template variables in your service config — if you skip them, you'll need to add them manually later from the [environment variable reference](config/environment.md).

1. Click **Deploy on Railway** above
2. Set environment variables:
   - `OPENROUTER_API_KEY` — one key, all models ([get one](https://openrouter.ai/keys))
   - `LLM_PRIMARY_MODEL` — e.g. `openrouter/minimax/minimax-m2.7`
   - `TELEGRAM_BOT_TOKEN` — from [@BotFather](https://t.me/BotFather)
   - `TELEGRAM_OWNER_ID` — your user ID (from [@userinfobot](https://t.me/userinfobot))
3. Deploy — message your bot and start chatting

Persistent storage at `/data` is included automatically. Works with Telegram, Discord, and Slack. See [config/environment.md](config/environment.md) for all options.

A few runtime vars are now first-class template settings rather than `EXTRA_ENV_KEYS` extras:
- use `TZ` as the preferred timezone var (`OPENCLAW_TZ` is still supported for backward compatibility)
- set `XDG_CONFIG_HOME=/data/.config` for persisted CLI credentials
- set `GOG_KEYRING_PASSWORD` directly when using the bundled `gog` skill

<details>
<summary><strong>Getting your credentials</strong></summary>

**OpenRouter API Key:**
1. Sign up at [openrouter.ai](https://openrouter.ai)
2. Go to [Keys](https://openrouter.ai/keys) and create a new key
3. One key gives you access to all major models (OpenAI, Anthropic, Google, DeepSeek, etc.)

**Telegram Bot Token:**
1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot` and follow the prompts to name your bot
3. Copy the token it gives you

**Your Telegram User ID:**
1. Message [@userinfobot](https://t.me/userinfobot) on Telegram
2. It replies with your numeric user ID

Discord and Slack are also supported — see the [Setup Guide](docs/SETUP.md) for details.

</details>

## What You Get

An AI assistant that runs 24/7 on your own infrastructure, connected to your chat apps. It remembers conversations, searches the web, takes notes, schedules reminders — and starts locked down by default.

**Default capabilities (Tier 0):**
- Chat via Telegram, Discord, or Slack
- Read/write workspace files (notes, memory)
- Web search and web page reading
- Scheduled reminders and cron jobs
- Semantic memory search

**Cost:** Railway's free trial works for testing. LLM API costs can be under $5/month with recommended models, but usage varies wildly depending on your model choice, message volume, and use case.

**Unlock more with a single env var change:**

| Tier | Name | What It Adds |
|------|------|-------------|
| 0 | Personal Assistant | Web, memory, read/write, cron *(default)* |
| 1 | Capable Agent | + workspace-scoped shell (`find`, `wc`, `sort`, `uniq`) |
| 2 | Power User | + full shell, remote browser, sub-agents |
| 3 | Operator | + unrestricted access (requires SSH) |

Set `SECURITY_TIER=1` and redeploy. That's it. See [docs/TIERS.md](docs/TIERS.md) for details.

## Security

This template wraps OpenClaw with 5 layers of hardening:

1. **Filesystem sandboxing** — `workspaceOnly` restricts file tools to `/data/workspace/`; restricted tiers separately constrain shell paths
2. **Process isolation** — Gateway and health server run as a non-root user; only the gateway receives the secrets it needs
3. **File permissions** — Config files root-owned 640, behavioral templates read-only 440
4. **Behavioral templates** — Agent identity and guardrails restored from image on every deploy
5. **Log filtering** — Response text stripped from deploy logs

**Benchmarked (2026-03-30):** A/B tested against vanilla OpenClaw v2026.3.28 across 2 models (minimax-m2.7, mimo-v2-pro) with 24 security tests and isolated sessions per test:

| | Hardened | Vanilla |
|---|---|---|
| **minimax-m2.7** | 21/22 — 95% | 5/24 — 21% |
| **mimo-v2-pro** | 20/22 — 91% | 5/24 — 21% |

Same models, same keys, same base image — the only difference is the security template. Scores exclude tier-gated SKIPs but include ERRORs (timeouts). See [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) for methodology and the [HTML report](tests/results/report.html) for full per-test results.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 RAILWAY CONTAINER                    │
│                                                      │
│  Health Server (:8080)     Gateway (:18789)         │
│  - /healthz endpoint       - Loopback only          │
│  - Public facing           - Handles channels       │
│                                                      │
│  Config: /data/.openclaw/openclaw.json              │
│  Workspace: /data/workspace                         │
└─────────────────────────────────────────────────────┘
```

Config is generated from environment variables on every deploy — no manual editing required.

## Environment Variables

See [config/environment.md](config/environment.md) for the complete reference.

### Required

| Variable | Description |
|----------|-------------|
| `*_API_KEY` | At least one LLM provider key |
| `*_BOT_TOKEN` | At least one channel token |
| `*_OWNER_ID` | Your user ID for instant access |

### Example

```
OPENROUTER_API_KEY=sk-or-...
LLM_PRIMARY_MODEL=openrouter/minimax/minimax-m2.7
TELEGRAM_BOT_TOKEN=123456789:ABC...
TELEGRAM_OWNER_ID=987654321
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Environment Variables](config/environment.md) | All supported env vars |
| [Setup Guide](docs/SETUP.md) | Step-by-step deployment |
| [Mission Control (Discord)](docs/MISSION-CONTROL.md) | Multi-agent Discord control-panel setup |
| [Security Tiers](docs/TIERS.md) | Unlocking capabilities |
| [Security Model](docs/SECURITY.md) | How protection works |
| [Providers](docs/PROVIDERS.md) | LLM provider configuration |
| [Threat Model](docs/THREAT-MODEL.md) | What can go wrong |

## Updating

Redeploy the container. Config regenerates from your environment variables on every startup — no manual intervention needed.

```bash
railway up
```

Never run `openclaw update` inside the container.

## Contributing

Issues and PRs welcome. If you find a security issue, please open an issue or reach out directly rather than posting exploit details publicly.

## License

[MIT](LICENSE)
