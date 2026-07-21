# OpenClaw Version Upgrade Protocol

This repository pins OpenClaw intentionally. Do not update the runtime by hand in a live container, and do not ship a new upstream version until it has passed the gates below.

This document is agent-harness agnostic: any human or automation system can follow it.

The authority ladder and evidence identity contract are documented in
[`OPENCLAW-RELEASE-AUTONOMY.md`](OPENCLAW-RELEASE-AUTONOMY.md).

## Non-negotiables

- Never run `openclaw update` inside the Railway container.
- Treat every upstream OpenClaw release as a candidate until validated.
- Promote from evidence, not optimism: local Docker + Railway staging must pass.
- Any config-schema, permission, plugin, channel, provider, or secret-handling warning blocks promotion until understood.
- Use a PR or explicit review checkpoint for the version bump.
- Reject validation artifacts that do not match the current commit and workspace fingerprint.
- Treat a complete `BLOCK` report and repair packet as a successful observer run.
- After production passes, tag the known-good template state.

## Standard upgrade flow

### 1. Pick the candidate

Confirm the target OpenClaw version exists on npm and review upstream release notes/changelog if available.

```bash
npm view openclaw@<version> version
```

### 2. Validate locally before editing the pin

```bash
bun run openclaw:validate:local -- <version>
```

Expected result:

- Docker image builds with the candidate version.
- `openclaw --version` matches the candidate.
- Container boots.
- `/healthz` passes.
- Generated config validates.
- Config permissions remain hardened.
- Logs contain no known blocker patterns.

Validation artifacts are written to:

```text
.validation/openclaw/<version>/<run-id>/
```

### 3. Validate on Railway staging

Use only the dedicated staging Railway service/environment, never production.

```bash
RAILWAY_ENVIRONMENT=staging \
OPENCLAW_RAILWAY_STAGING_CONFIRMED=1 \
OPENCLAW_STAGING_HEALTH_URL=https://<staging-domain>/healthz \
bun run openclaw:validate:railway -- <version>
```

Expected result:

- Staging deploy succeeds.
- Staging `/healthz` returns `OK`.
- Railway logs contain no blocker patterns.
- Generated config validates on staging.

### 4. Check plugins and channels

For Discord-enabled deployments, OpenClaw 2026.5.x requires the external Discord plugin.

Verify on staging:

```bash
openclaw plugins list --json
openclaw channels list --json
openclaw channels status --deep --json
```

Discord gate:

- `discord` plugin is present.
- `discord` plugin is enabled and loaded.
- dependency status has no missing required dependencies.
- Discord account is configured, running, and connected.
- every configured Discord guild/channel is visible to the bot.
- send at least one Discord smoke message to a staging channel.

After observing the response, record commit-bound evidence:

```bash
OPENCLAW_STAGING_CHANNEL_SMOKE_CONFIRMED=1 \
OPENCLAW_STAGING_CHANNEL_SMOKE_EVIDENCE="Discord staging message and response observed" \
bun run openclaw:record:channel-smoke -- <version> pass
```

If no channels are configured for this template lane, use `not_in_scope` and
state the reason in `OPENCLAW_STAGING_CHANNEL_SMOKE_EVIDENCE`.

### 5. Promote the version pin

Only after local and staging validation pass:

```bash
bun run openclaw:promote -- <version>
```

This updates the repository version pin files. Review the diff.

### 6. Open PR / review checkpoint

The PR or review note should include:

- target OpenClaw version
- local validation report path
- Railway staging validation report path
- plugin/channel status summary
- known warnings and classification
- rollback version

Do not merge if any warning is unexplained.

### 7. Merge and monitor production

After merge to `main`, production may auto-deploy.

Check:

```bash
railway service status --json
curl -fsS https://<production-domain>/healthz
```

Then verify Discord if configured:

```bash
openclaw plugins list --json
openclaw channels status --deep --json
```

### 8. Tag known-good template release

After production is healthy and channel checks pass, tag the repository state.

Suggested format:

```text
v<openclaw-version>-template.<n>
```

Example:

```bash
git tag v2026.5.5-template.1
git push origin v2026.5.5-template.1
```

## Rollback

Rollback is a normal version-pin revert:

1. Revert the promotion commit, or set the pin back to the previous known-good version.
2. Redeploy Railway.
3. Confirm `/healthz`.
4. Confirm Discord plugin/channel health if Discord is configured.

Do not attempt rollback by running `openclaw update` or manual package edits inside the production container.

## Current Discord-specific regression checks

Because Discord was externalized from the bundled OpenClaw runtime, keep these checks in every upgrade until upstream behavior is stable:

- With `DISCORD_BOT_TOKEN` set, `src/build-config.js` must write `plugins.entries.discord.enabled = true`.
- `entrypoint.sh` must create writable plugin install directories before locking `/data/.openclaw`.
- Boot must install `@openclaw/discord` if missing.
- After boot, the gateway must discover Discord as a loaded plugin.
- Configured Discord channels must be visible by Discord API or `openclaw channels status` evidence.
