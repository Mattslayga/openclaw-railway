# OpenClaw Upstream Updates

This template pins OpenClaw. Redeploying the Railway service must not silently
install a newly published upstream runtime.

## Policy

- `main` contains only a version that has already passed validation.
- New upstream releases are candidates, not deployments.
- Beta/prerelease versions can be tested in staging, but should not be promoted
  for public template users without an explicit override decision.
- Any failed gate blocks promotion.
- Any unknown warning blocks promotion until classified.
- Any config, permission, plugin, channel, or secret-handling change in upstream
  release notes requires manual review before promotion.

## Local Docker Validation

```bash
bun run openclaw:validate:local -- 2026.5.2-beta.2
```

The local gate checks:

- package exists on npm
- Docker image builds with `OPENCLAW_VERSION`
- installed `openclaw --version` matches the candidate
- container boots
- `/healthz` passes
- generated config exists at `root:openclaw 640`
- Tier 0 keeps exec allowlist and `workspaceOnly`
- logs do not contain known blocker patterns

Artifacts are written under `.validation/openclaw/<version>/<run-id>/`.

## Railway Staging Validation

Use the `openclaw-railway` Railway project with a dedicated staging
environment/service, never the production service.

```bash
RAILWAY_ENVIRONMENT=staging \
OPENCLAW_RAILWAY_STAGING_CONFIRMED=1 \
OPENCLAW_STAGING_HEALTH_URL=https://your-staging-service.up.railway.app \
bun run openclaw:validate:railway -- 2026.5.2-beta.2
```

The staging gate requires a passing local validation artifact first. It deploys
the candidate from a temporary deploy bundle with that candidate baked into the
Dockerfile, checks health when a staging URL is provided, captures Railway logs,
and blocks on known failure patterns. Set `OPENCLAW_RAILWAY_STAGING_SERVICE` if
your linked Railway service is not the staging service.

Before promotion, also run a live channel smoke test with staging credentials:

- send a message to the staging bot
- confirm a real response
- confirm deploy/runtime logs do not expose secrets
- restart or redeploy once and confirm the gateway returns healthy

## Promotion

Promotion is blocked until both local and Railway validation artifacts exist and
are passing:

```bash
bun run openclaw:promote -- 2026.5.2-beta.2
```

That updates:

- `Dockerfile`
- `.openclaw-version.json`

Open a PR with links or pasted excerpts from the validation reports. Merge only
after reviewing the evidence and confirming rollback.

## Rollback

Rollback is a normal version-pin revert:

1. Set `ARG OPENCLAW_VERSION` back to the previous known-good version.
2. Set `.openclaw-version.json.version` back to the same version.
3. Redeploy.

Never run `openclaw update` inside the container.
