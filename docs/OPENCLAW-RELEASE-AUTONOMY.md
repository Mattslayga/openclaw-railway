# OpenClaw Release Autonomy

OpenClaw upgrades use staged autonomy. The release system earns additional
authority only after its existing stage produces reliable evidence.

## Authority stages

| Stage | May do | Must not do |
|---|---|---|
| Observe | Detect the stable/latest candidate, deduplicate completed evaluations, validate locally, report a verdict | Edit repository files, deploy staging, open or merge PRs |
| Plan repair | Classify a failed gate and write a repair packet | Implement the repair |
| Repair PR | Create a branch, edit code, run local checks, open a PR | Merge or deploy production |
| Prove | Deploy the exact repair commit to Railway staging and run required smoke checks | Change the production pin |
| Promote | Advance the pin after explicit approval and verified evidence | Publish an untested candidate |
| Managed stable | Advance a downstream stable image channel after trust thresholds are met | Bypass canary, soak, or rollback policy |

The scheduled sentinel currently has **Observe + Plan repair** authority only.
It is a maintainer-owned Codex automation outside this public repository. The
former GitHub Actions observer was removed because it tested the existing pin
while labeling newly discovered versions compatible, creating false evidence.

## Terminal run states

Every scheduled run must finish with one of these states:

- `CHECK_FAILED`: required upstream metadata or the current pin could not be
  read. Report the missing evidence and retry on the next schedule.
- `NO_CANDIDATE`: the pin already matches stable/latest.
- `UNCHANGED`: the candidate, requested gates, and repository fingerprint match
  a completed evaluation, so validation was not repeated.
- `BLOCK`: a required compatibility gate failed. A repair packet is required.
- `HOLD`: available checks passed, but required staging, channel, or review
  evidence is missing.
- `PROMOTE`: all required automated gates passed. Human promotion authority is
  still required at the current trust stage.

A reported validation failure is a successfully completed observer run. The
automation itself should fail only when it cannot determine or persist a result.

## Evidence identity

Local, Railway, and promotion evidence must agree on:

- OpenClaw candidate version
- repository commit
- workspace fingerprint, including tracked changes and untracked source files
- requested gate level

Artifacts from another commit or workspace state are stale and cannot authorize
promotion. Railway evidence must include an external `/healthz` pass. Channel
smoke evidence must be `pass` or explicitly `not_in_scope` before promotion.
Record it with `openclaw:record:channel-smoke`; never edit generated summaries
by hand.

## Deduplication

The observer stores the last completed evaluation key outside the public
template repository. If candidate, pin, workspace fingerprint, and requested
gates are unchanged, it reports `UNCHANGED` and links to the previous artifacts.
Changing the repository or requesting Railway staging creates a new key and
unlocks evaluation.

## Current human gates

Explicit human approval remains required for:

- repair implementation
- Railway staging deployment
- real-channel smoke messages
- version promotion and PR merge
- production deployment
- Railway template publication
- downstream stable-channel movement

Never run `openclaw update` inside a deployment.
