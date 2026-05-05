#!/bin/bash
# =============================================================================
# OpenClaw Railway Entrypoint
# Builds config from env vars, starts gateway, then health server
# =============================================================================

set -e

echo "[entrypoint] Starting OpenClaw Railway..."
echo "[entrypoint] OpenClaw version: $(openclaw --version 2>/dev/null || echo 'unknown')"

# -----------------------------------------------------------------------------
# 1. Create data directories with secure permissions
# -----------------------------------------------------------------------------
mkdir -p /data/.openclaw /data/workspace /data/bin
chmod 700 /data/.openclaw
chown -R openclaw:openclaw /data

# /data/bin/ — custom binaries installed via SSH. Root-owned so the agent
# can't replace them, but group-executable so the gateway can run them.
chown root:openclaw /data/bin
chmod 750 /data/bin
# Ensure any binaries already on the volume are root-owned + group-executable
if ls /data/bin/* >/dev/null 2>&1; then
  chown root:openclaw /data/bin/*
  chmod 750 /data/bin/*
  # Symlink custom binaries into /usr/local/bin so the skills system
  # (which checks standard PATH) can discover them via requires.bins
  for bin in /data/bin/*; do
    ln -sf "$bin" /usr/local/bin/"$(basename "$bin")"
  done
fi

# Reverse-symlink media: real files live in workspace, gateway writes through symlink.
# The image tool uses realpath() to check paths against workspaceOnly. By making
# /data/.openclaw/media a symlink pointing INTO /data/workspace/media, files
# resolve to workspace paths and pass the sandbox check. This preserves
# workspaceOnly while enabling vision at all tiers.
mkdir -p /data/workspace/media/inbound
chown openclaw:openclaw /data/workspace/media /data/workspace/media/inbound
# Move any existing media files into workspace (first deploy migration)
if [ -d "/data/.openclaw/media/inbound" ] && [ ! -L "/data/.openclaw/media" ]; then
  cp -a /data/.openclaw/media/inbound/* /data/workspace/media/inbound/ 2>/dev/null
  rm -rf /data/.openclaw/media
fi
# Create or refresh the symlink
ln -sfn /data/workspace/media /data/.openclaw/media

# Copy skills into workspace so the agent can read SKILL.md files under workspaceOnly.
# The gateway loads skill metadata internally, but the agent needs to read the full
# SKILL.md for detailed instructions (command syntax, flags, examples). Copies are
# refreshed every startup so they stay in sync with the installed version.
mkdir -p /data/workspace/skills
# Managed skills (e.g. core-edge, installed via clawhub) — copy subdirectories only,
# skip stray files at the managed skills root level.
if [ -d "/data/.openclaw/skills" ]; then
  for skill_dir in /data/.openclaw/skills/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    mkdir -p "/data/workspace/skills/$skill_name"
    cp -a "$skill_dir"* "/data/workspace/skills/$skill_name/" 2>/dev/null
  done
fi
# Bundled skills — copy eligible ones whose requirements are met on this container.
# Use mkdir + cp contents to avoid nesting if dir already exists from managed skills.
for skill in gog weather healthcheck node-connect skill-creator; do
  src="/usr/local/lib/node_modules/openclaw/skills/$skill"
  if [ -d "$src" ]; then
    mkdir -p "/data/workspace/skills/$skill"
    cp -a "$src"/* "/data/workspace/skills/$skill/" 2>/dev/null
  fi
done
chown -R openclaw:openclaw /data/workspace/skills
echo "[entrypoint] Skills copied to workspace ($(ls /data/workspace/skills/ | wc -w) skills)"

echo "[entrypoint] Data directories ready"

# -----------------------------------------------------------------------------
# 1a. Normalize timezone env vars
#     TZ is the POSIX-standard user-facing variable. OPENCLAW_TZ is kept for
#     backward compatibility and mirrored so gateway scheduling/logs stay in
#     sync with the broader process environment.
# -----------------------------------------------------------------------------
if [ -n "${TZ:-}" ] && [ -z "${OPENCLAW_TZ:-}" ]; then
  export OPENCLAW_TZ="$TZ"
fi
if [ -n "${OPENCLAW_TZ:-}" ] && [ -z "${TZ:-}" ]; then
  export TZ="$OPENCLAW_TZ"
fi

# -----------------------------------------------------------------------------
# 1b. Linear CLI credentials
#     Write credentials.toml on the persistent /data volume so the Linear CLI
#     can switch workspaces via -w. Supported formats:
#       LINEAR_API_KEYS=workspace:key,workspace:key
#       LINEAR_API_KEYS=lin_api_single_key
#     Legacy fallback (still supported):
#       LINEAR_API_KEY + MOTUS_LINEAR_API_KEY
# -----------------------------------------------------------------------------
LINEAR_CONFIG_DIR="/data/.config/linear"
LINEAR_CREDENTIALS_FILE="${LINEAR_CONFIG_DIR}/credentials.toml"
LINEAR_TMP_FILE="${LINEAR_CREDENTIALS_FILE}.tmp"
LINEAR_KEYS_SOURCE=""

if [ -n "${LINEAR_API_KEYS:-}" ]; then
  LINEAR_KEYS_SOURCE="LINEAR_API_KEYS"
elif [ -n "${LINEAR_API_KEY:-}" ]; then
  LINEAR_KEYS_SOURCE="legacy"
fi

if [ -n "$LINEAR_KEYS_SOURCE" ]; then
  mkdir -p "$LINEAR_CONFIG_DIR"
  : > "$LINEAR_TMP_FILE"
  LINEAR_DEFAULT_WORKSPACE=""
  WORKSPACE_COUNT=0

  if [ "$LINEAR_KEYS_SOURCE" = "LINEAR_API_KEYS" ]; then
    IFS=',' read -ra LINEAR_KEY_ENTRIES <<< "$LINEAR_API_KEYS"
    for raw_entry in "${LINEAR_KEY_ENTRIES[@]}"; do
      entry="$(echo "$raw_entry" | xargs)"
      [ -z "$entry" ] && continue

      if printf '%s' "$entry" | grep -q ':'; then
        workspace="$(printf '%s' "${entry%%:*}" | xargs)"
        api_key="$(printf '%s' "${entry#*:}" | xargs)"
      else
        workspace="slaytek-systems"
        api_key="$entry"
      fi

      if [ -z "$workspace" ] || [ -z "$api_key" ]; then
        echo "[entrypoint] WARNING: Skipping invalid LINEAR_API_KEYS entry '$entry'"
        continue
      fi

      if [ -z "$LINEAR_DEFAULT_WORKSPACE" ]; then
        LINEAR_DEFAULT_WORKSPACE="$workspace"
      fi

      printf '%s = "%s"\n' "$workspace" "$api_key" >> "$LINEAR_TMP_FILE"
      WORKSPACE_COUNT=$((WORKSPACE_COUNT + 1))
    done
  else
    LINEAR_DEFAULT_WORKSPACE="slaytek-systems"
    printf 'slaytek-systems = "%s"\n' "$LINEAR_API_KEY" >> "$LINEAR_TMP_FILE"
    WORKSPACE_COUNT=1
    if [ -n "${MOTUS_LINEAR_API_KEY:-}" ]; then
      printf 'motuscapital = "%s"\n' "$MOTUS_LINEAR_API_KEY" >> "$LINEAR_TMP_FILE"
      WORKSPACE_COUNT=2
    fi
    echo "[entrypoint] Linear credentials: using legacy LINEAR_API_KEY / MOTUS_LINEAR_API_KEY env vars"
  fi

  if [ "$WORKSPACE_COUNT" -gt 0 ] && [ -n "$LINEAR_DEFAULT_WORKSPACE" ]; then
    {
      printf 'default = "%s"\n' "$LINEAR_DEFAULT_WORKSPACE"
      cat "$LINEAR_TMP_FILE"
    } > "$LINEAR_CREDENTIALS_FILE"
    chmod 600 "$LINEAR_CREDENTIALS_FILE"
    chown -R openclaw:openclaw /data/.config
    echo "[entrypoint] Linear credentials: ${WORKSPACE_COUNT} workspace(s) configured (default: ${LINEAR_DEFAULT_WORKSPACE})"
  else
    echo "[entrypoint] WARNING: LINEAR_API_KEYS was set but no valid entries were found — credentials file not written"
  fi

  rm -f "$LINEAR_TMP_FILE"
fi

# -----------------------------------------------------------------------------
# 1c. Surface persistent config dirs under the gateway user's HOME
#     The gateway runs with HOME=/home/openclaw. Symlinking /data/.config/*
#     into ~/.config makes persisted CLI credentials available to exec
#     subprocesses without relying on XDG_CONFIG_HOME propagation.
# -----------------------------------------------------------------------------
if [ -d "/data/.config" ]; then
  mkdir -p /home/openclaw/.config
  for dir in /data/.config/*/; do
    [ -d "$dir" ] || continue
    ln -sfnT "$dir" "/home/openclaw/.config/$(basename "$dir")"
  done
  chown -R openclaw:openclaw /home/openclaw/.config
fi

# -----------------------------------------------------------------------------
# 2. Copy workspace templates (only files that don't already exist)
# -----------------------------------------------------------------------------
if [ -d "/app/workspace-templates" ]; then
  for tmpl in /app/workspace-templates/*; do
    basename="$(basename "$tmpl")"
    if [ ! -e "/data/workspace/$basename" ]; then
      echo "[entrypoint] Copying template: $basename"
      cp -r "$tmpl" "/data/workspace/$basename"
      chown -R openclaw:openclaw "/data/workspace/$basename"
    fi
  done
fi

# -----------------------------------------------------------------------------
# 2b. Workspace file protection (three categories)
#
#     LOCKED (always overwrite from image + root:openclaw 440):
#       AGENTS.md  — safety boundary, tier-injected
#       TOOLS.md   — tool reference, tier-injected
#       PROGRESSION.md — upgrade guidance
#     These are force-restored every startup to undo tampering. The agent
#     can read them but cannot overwrite them.
#
#     SEED-ONLY (copy if missing, openclaw-owned, agent can edit):
#       PROJECTS.md — project ideas, not security-critical
#     Handled by the seed-if-missing loop above (step 2). Not in
#     PROTECTED_TEMPLATES, so the agent can customize it.
#
#     AGENT-OWNED (seed if missing, never overwrite):
#       IDENTITY.md, USER.md, SOUL.md, HEARTBEAT.md, BOOTSTRAP.md
#     Also handled by the seed-if-missing loop. These are the agent's
#     personalization files — they survive redeploys on the volume.
# -----------------------------------------------------------------------------
SECURITY_TIER="${SECURITY_TIER:-0}"

# Determine tier metadata and load injection templates from config/tier-inject/
TIER_INJECT_DIR="/app/config/tier-inject"

case "$SECURITY_TIER" in
  0)
    TIER_NAME="Personal Assistant"
    TIER_EXEC_COMMANDS="ls"
    ;;
  1)
    TIER_NAME="Capable Agent"
    TIER_EXEC_COMMANDS="ls, find, wc, sort, uniq, git"
    ;;
  2)
    TIER_NAME="Power User"
    TIER_EXEC_COMMANDS="any"
    ;;
  3)
    TIER_NAME="Operator"
    TIER_EXEC_COMMANDS="any"
    ;;
esac

# Load tier-specific injection templates from files
AGENTS_INJECT_SRC="${TIER_INJECT_DIR}/agents-tier${SECURITY_TIER}.md"
TOOLS_INJECT_SRC="${TIER_INJECT_DIR}/tools-tier${SECURITY_TIER}.md"

if [ ! -f "$AGENTS_INJECT_SRC" ] || [ ! -f "$TOOLS_INJECT_SRC" ]; then
  echo "[entrypoint] ERROR: Missing tier-inject template for tier ${SECURITY_TIER}"
  echo "[entrypoint] Expected: ${AGENTS_INJECT_SRC} and ${TOOLS_INJECT_SRC}"
  exit 1
fi

echo "[entrypoint] Tier ${SECURITY_TIER} (${TIER_NAME})"

# Copy and lock protected templates
PROTECTED_TEMPLATES="AGENTS.md TOOLS.md PROGRESSION.md"
for fname in $PROTECTED_TEMPLATES; do
  src="/app/workspace-templates/$fname"
  dst="/data/workspace/$fname"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
  fi
done

# Inject tier-specific content into AGENTS.md before locking
AGENTS_DST="/data/workspace/AGENTS.md"
if [ -f "$AGENTS_DST" ]; then
  awk '
    /<!-- TIER_INJECT -->/ { while ((getline line < "'"$AGENTS_INJECT_SRC"'") > 0) print line; next }
    { print }
  ' "$AGENTS_DST" > "${AGENTS_DST}.tmp"
  mv "${AGENTS_DST}.tmp" "$AGENTS_DST"
  echo "[entrypoint] Tier ${SECURITY_TIER} injected into AGENTS.md"

  # FOCUS.md lives in the workspace as a standalone file the agent reads directly.
  # No injection needed — the focus blackboard on Core Edge is the source of truth,
  # and FOCUS.md just tells the agent how to find it.
fi

# Inject tier-specific content into TOOLS.md before locking
TOOLS_DST="/data/workspace/TOOLS.md"
if [ -f "$TOOLS_DST" ]; then
  awk '
    /<!-- TOOLS_TIER_INJECT -->/ { while ((getline line < "'"$TOOLS_INJECT_SRC"'") > 0) print line; next }
    { print }
  ' "$TOOLS_DST" > "${TOOLS_DST}.tmp"
  mv "${TOOLS_DST}.tmp" "$TOOLS_DST"
  echo "[entrypoint] Tier ${SECURITY_TIER} injected into TOOLS.md"
fi

# Write .tier marker file to workspace
cat > /data/workspace/.tier <<TIEREOF
SECURITY_TIER=${SECURITY_TIER}
TIER_NAME=${TIER_NAME}
EXEC_COMMANDS=${TIER_EXEC_COMMANDS}
TIEREOF

# Lock all protected templates + .tier (root:openclaw 440)
for fname in $PROTECTED_TEMPLATES; do
  dst="/data/workspace/$fname"
  if [ -f "$dst" ]; then
    chown root:openclaw "$dst"
    chmod 440 "$dst"
  fi
done
chown root:openclaw /data/workspace/.tier
chmod 440 /data/workspace/.tier

# Docs directory: same treatment
if [ -d "/app/docs" ]; then
  cp -r /app/docs /data/workspace/
  chown -R root:openclaw /data/workspace/docs
  chmod -R u=rwX,g=rX,o= /data/workspace/docs
fi
echo "[entrypoint] Behavioral templates locked (root:openclaw 440)"

# -----------------------------------------------------------------------------
# 3. Deploy exec-approvals (tier-aware)
#    Tier 0: ls only, ask off
#    Tier 1: curated list (find, git, wc, sort, uniq), ask off
#    Tier 2+: full exec, no allowlist needed
#    Note: exec-approvals.json lives at ~/.openclaw/ (user home), NOT $OPENCLAW_STATE_DIR
# -----------------------------------------------------------------------------
APPROVALS_HOME="/home/openclaw/.openclaw/exec-approvals.json"

mkdir -p /home/openclaw/.openclaw

case "$SECURITY_TIER" in
  0)
    APPROVALS_SRC="/app/config/exec-approvals-tier0.json"
    echo "[entrypoint] Deploying exec-approvals for Tier 0 (ls only)..."
    ;;
  1)
    APPROVALS_SRC="/app/config/exec-approvals-tier1.json"
    echo "[entrypoint] Deploying exec-approvals for Tier 1 (curated list)..."
    ;;
  *)
    APPROVALS_SRC=""
    echo "[entrypoint] Tier ${SECURITY_TIER}: full exec mode, no exec-approvals needed"
    # Remove stale approvals file if upgrading from a lower tier
    rm -f "$APPROVALS_HOME"
    ;;
esac

if [ -n "$APPROVALS_SRC" ] && [ -f "$APPROVALS_SRC" ]; then
  cp "$APPROVALS_SRC" "$APPROVALS_HOME"
fi

# Append EXEC_EXTRA_COMMANDS to exec-approvals (for custom binaries on the volume)
# e.g. EXEC_EXTRA_COMMANDS=core-edge,my-tool → allows /data/bin/core-edge, /data/bin/my-tool
if [ -n "$EXEC_EXTRA_COMMANDS" ] && [ -f "$APPROVALS_HOME" ]; then
  IFS=',' read -ra EXTRA_CMDS <<< "$EXEC_EXTRA_COMMANDS"
  for cmd in "${EXTRA_CMDS[@]}"; do
    cmd="$(echo "$cmd" | xargs)"  # trim whitespace
    [ -z "$cmd" ] && continue
    # Validate: alphanumeric, dash, underscore only — blocks shell injection and path traversal
    if ! echo "$cmd" | grep -qE '^[a-zA-Z0-9_-]+$'; then
      echo "[entrypoint] WARNING: Invalid EXEC_EXTRA_COMMANDS value '$cmd' — must be alphanumeric/dash/underscore only. Skipping."
      continue
    fi
    # Inject entry into the allowlist array using node (no python3 in container)
    node -e "
      const fs = require('fs');
      const f = '$APPROVALS_HOME';
      const a = JSON.parse(fs.readFileSync(f, 'utf-8'));
      const id = 'custom-' + '$cmd';
      if (!a.agents.main.allowlist.some(e => e.id === id)) {
        a.agents.main.allowlist.push({ id, pattern: '/data/bin/$cmd', lastUsedCommand: '$cmd' });
        fs.writeFileSync(f, JSON.stringify(a, null, 2));
      }
    "
    echo "[entrypoint] Exec extra: added '$cmd' (/data/bin/$cmd) to exec-approvals"
  done
fi

# Harden exec-approvals permissions (tier-aware):
#   File: root:openclaw 660 — root owns, gateway (openclaw group) can read+write
#     (gateway updates lastUsedCommand metadata at runtime on each exec call)
#   Dir permissions differ by tier:
#     Tier 0-1: 750 — gateway can traverse+read, cannot create new files
#               (exec-approvals.json already deployed by entrypoint above)
#     Tier 2+:  770 — gateway needs to create exec-approvals.json at runtime
#               (we deleted it at line 310 since full exec doesn't use allowlists,
#                but the gateway still creates it for internal state tracking)
# Always harden the directory, regardless of whether exec-approvals file exists.
# Tier 0-1: 750 — gateway can traverse+read but not create files (entrypoint deploys the file).
# Tier 2+:  770 — gateway must create exec-approvals.json at runtime for internal state tracking.
#   v2026.3.23+ made this mandatory: EACCES on the approvals file now blocks all exec calls.
#   At Tier 2 exec is already unrestricted, so group-write on this dir doesn't weaken security.
chown root:openclaw /home/openclaw/.openclaw
if [ "$SECURITY_TIER" -ge 2 ] 2>/dev/null; then
  chmod 770 /home/openclaw/.openclaw
else
  chmod 750 /home/openclaw/.openclaw
fi

if [ -f "$APPROVALS_HOME" ]; then
  chown root:openclaw "$APPROVALS_HOME"
  chmod 660 "$APPROVALS_HOME"
  echo "[entrypoint] Exec-approvals hardened (root:openclaw 660, dir 750)"
fi

# -----------------------------------------------------------------------------
# 4. Build config from environment variables (always regenerate)
# -----------------------------------------------------------------------------
CONFIG_FILE="/data/.openclaw/openclaw.json"

# Clear gateway baselines before regenerating config.
# In v2026.4.x the gateway compares each freshly-read openclaw.json against a
# `lastKnownGood` fingerprint (stored in logs/config-health.json). If the new
# config differs in suspicious ways — e.g. missing the `meta` field that the
# gateway itself wrote on a previous boot — it treats the file as "clobbered",
# moves our entrypoint-generated config aside as openclaw.json.clobbered.<ts>,
# and restores from openclaw.json.bak. That silently reverts every redeploy.
#
# Since our entrypoint is the source of truth (re-derived from env vars on
# every boot), there is no recovery scenario where reverting to .bak helps.
# Wiping baselines and stale snapshots forces the gateway to accept whatever
# build-config.js produces.
rm -f \
  /data/.openclaw/openclaw.json.bak \
  /data/.openclaw/openclaw.json.bak.* \
  /data/.openclaw/openclaw.json.clobbered.* \
  /data/.openclaw/openclaw.json.last-good \
  /data/.openclaw/logs/config-health.json \
  /data/.openclaw/logs/config-audit.jsonl 2>/dev/null
echo "[entrypoint] Cleared gateway config baselines (.bak, .clobbered.*, config-health.json)"

# Always regenerate config from env vars to pick up changes
echo "[entrypoint] Building config from environment variables..."
node /app/src/build-config.js

# -----------------------------------------------------------------------------
# 4a. Merge config overlay (optional)
#     Users can place a config-overlay.json on the persistent volume to add
#     settings that build-config.js doesn't generate — e.g. agents.list,
#     bindings, tools.agentToAgent, subagent depth config.
#     The overlay is deep-merged into the generated config. Overlay values
#     win on conflict. The overlay file is never modified by the entrypoint.
# -----------------------------------------------------------------------------
CONFIG_OVERLAY="/data/config-overlay.json"
if [ -f "$CONFIG_OVERLAY" ]; then
  echo "[entrypoint] Merging config overlay from $CONFIG_OVERLAY..."
  node -e "
    const fs = require('fs');
    const configPath = '$CONFIG_FILE';
    const overlayPath = '$CONFIG_OVERLAY';

    function deepMerge(target, source) {
      for (const key of Object.keys(source)) {
        if (
          source[key] !== null &&
          typeof source[key] === 'object' &&
          !Array.isArray(source[key]) &&
          target[key] !== null &&
          typeof target[key] === 'object' &&
          !Array.isArray(target[key])
        ) {
          deepMerge(target[key], source[key]);
        } else {
          target[key] = source[key];
        }
      }
      return target;
    }

    const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    const overlay = JSON.parse(fs.readFileSync(overlayPath, 'utf-8'));
    const merged = deepMerge(config, overlay);
    fs.writeFileSync(configPath, JSON.stringify(merged, null, 2), { mode: 0o600 });
    const keys = Object.keys(overlay);
    console.log('[entrypoint] Config overlay merged (' + keys.join(', ') + ')');
  "
else
  echo "[entrypoint] No config overlay found (optional: place config-overlay.json on volume)"
fi

if [ -f "$CONFIG_OVERLAY" ]; then
  chown root:openclaw "$CONFIG_OVERLAY"
  chmod 640 "$CONFIG_OVERLAY"
  echo "[entrypoint] Config overlay hardened (root:openclaw 640)"
fi

# -----------------------------------------------------------------------------
# 4b. Harden config file permissions
#     Config is 640 root:openclaw — gateway can read, agent cannot write.
#     This blocks the privilege escalation attack (agent overwriting config).
#     Read access stays open because the gateway re-reads config for health checks.
# -----------------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
  chown root:openclaw "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"

  # Pre-create gateway runtime directories — the gateway runs as openclaw and
  # needs to write to these at runtime (devices, cron, sessions, canvas, etc).
  # We create them before locking the parent dir so the gateway doesn't need
  # mkdir permission on /data/.openclaw itself.
  #
  # plugin-runtime-deps was added in v2026.4.x — gateway stages bundled plugin
  # node_modules into a per-version subdir at boot. Without this dir, every
  # plugin fails to install runtime deps (EACCES) and the gateway loads
  # `ready (0 plugins)` — silently broken (no telegram, no discord, etc.).
  GATEWAY_DIRS="agents canvas cron devices identity sessions tasks logs plugin-runtime-deps"
  for dir in $GATEWAY_DIRS; do
    mkdir -p "/data/.openclaw/$dir"
    chown openclaw:openclaw "/data/.openclaw/$dir"
    chmod 700 "/data/.openclaw/$dir"
  done
  echo "[entrypoint] Gateway runtime directories created (${GATEWAY_DIRS})"

  # Lock the .openclaw directory — openclaw can traverse and read, not create files
  chown root:openclaw /data/.openclaw
  chmod 750 /data/.openclaw

  echo "[entrypoint] Config set to 640 root:openclaw (read-only for gateway, no agent write)"
fi

# Note: exec-approvals permissions already set in step 3 (single pass).
# Accepted tradeoff: 660 means the agent's write tool could modify exec-approvals
# to expand the allowlist, but the tool policy in openclaw.json (which IS locked
# at 640 root:openclaw) still governs which tools are available.

# -----------------------------------------------------------------------------
# 4c. Build secrets env file for SecretRef resolution
#     Config uses SecretRef objects ({ source: "env", id: "KEY" }) instead of
#     literal secrets. The gateway resolves these from its own process.env at
#     startup, then holds them in-memory only. We pass them via env -i so they
#     appear in the gateway's environment for resolution.
#
#     Trade-off: secrets are in the gateway's /proc/self/environ, but this is
#     protected by workspaceOnly (agent can't read /proc via read tool) and
#     exec allowlist (no cat/head/tail at Tier 0-1). At Tier 2+ this is an
#     accepted risk (same as before — full exec can read anything).
#
#     The config file on disk contains only SecretRef objects, not plaintext.
#     This is strictly better than the old approach where literals sat in
#     openclaw.json (a persistent, on-disk attack surface).
# -----------------------------------------------------------------------------
SECRETS_ENV_FILE="/data/.openclaw/.secrets.env"
trap 'rm -f "$SECRETS_ENV_FILE"' EXIT

# Collect all secret env vars into a sourceable file
install -m 600 /dev/null "$SECRETS_ENV_FILE"

# Dynamic provider keys — extract from OpenClaw's own provider-env-vars module.
# This auto-discovers all API keys, tokens, and plan keys that OpenClaw recognises,
# so new providers added upstream are passed through without entrypoint changes.
# Provider API keys — use a static list. v2026.4.9+ loads most provider env vars
# from plugin manifests at runtime, so grepping dist/ files is unreliable.
# This list covers all providers OpenClaw supports. Duplicates with the
# template-specific section below are harmless (printf won't double-write
# because we dedup at the end).
for key in ANTHROPIC_API_KEY OPENAI_API_KEY GROQ_API_KEY \
           TOGETHER_API_KEY DEEPSEEK_API_KEY XAI_API_KEY MISTRAL_API_KEY \
           MINIMAX_API_KEY MINIMAX_CODE_PLAN_KEY MINIMAX_CODING_API_KEY \
           KIMI_API_KEY MOONSHOT_API_KEY \
           VENICE_API_KEY DEEPGRAM_API_KEY GEMINI_API_KEY GOOGLE_API_KEY \
           STEPFUN_API_KEY ARCEEAI_API_KEY CEREBRAS_API_KEY DASHSCOPE_API_KEY \
           VOYAGE_API_KEY; do
  val="$(eval echo "\${${key}:-}")"
  [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$SECRETS_ENV_FILE"
done

# Router/template-specific keys not in OpenClaw's provider list.
# OPENROUTER_API_KEY is always here — OpenRouter is a router, not a native
# provider, so it never appears in provider-env-vars.
for key in OPENROUTER_API_KEY BRAVE_API_KEY \
           GOOGLE_AI_API_KEY LLM_API_KEY VERCEL_GATEWAY_API_KEY \
           FIREWORKS_API_KEY CLOUDFLARE_API_KEY \
           AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION; do
  val="$(eval echo "\${${key}:-}")"
  [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$SECRETS_ENV_FILE"
done

# Channel tokens
for key in TELEGRAM_BOT_TOKEN DISCORD_BOT_TOKEN SLACK_BOT_TOKEN SLACK_APP_TOKEN; do
  val="$(eval echo "\${${key}:-}")"
  [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$SECRETS_ENV_FILE"
done

# Gateway token (only if user-specified; random tokens are written literally)
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  printf 'GATEWAY_TOKEN=%s\n' "$GATEWAY_TOKEN" >> "$SECRETS_ENV_FILE"
fi

# Core runtime env vars — first-class passthroughs, not EXTRA_ENV_KEYS extras.
# TZ is the preferred user-facing timezone var; OPENCLAW_TZ is mirrored above
# for backward compatibility. XDG_CONFIG_HOME and GOG_KEYRING_PASSWORD are used
# by bundled runtime integrations like gog and persisted CLI config directories.
FIRST_CLASS_RUNTIME_KEYS="TZ OPENCLAW_TZ XDG_CONFIG_HOME GOG_KEYRING_PASSWORD"
for key in $FIRST_CLASS_RUNTIME_KEYS; do
  val="$(eval echo "\${${key}:-}")"
  [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$SECRETS_ENV_FILE"
done

# Extra env keys (for genuinely user-custom binaries/integrations)
if [ -n "${EXTRA_ENV_KEYS:-}" ]; then
  IFS=',' read -ra EXTRA_KEY_LIST <<< "$EXTRA_ENV_KEYS"
  for key in "${EXTRA_KEY_LIST[@]}"; do
    key="$(echo "$key" | xargs)"
    [ -z "$key" ] && continue
    case " $FIRST_CLASS_RUNTIME_KEYS " in
      *" $key "*) continue ;;
    esac
    val="$(eval echo "\${${key}:-}")"
    [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$SECRETS_ENV_FILE"
  done
fi

# Lock the secrets file — root-only, deleted after gateway starts
chmod 600 "$SECRETS_ENV_FILE"
chown root:root "$SECRETS_ENV_FILE"

SECRET_COUNT=$(wc -l < "$SECRETS_ENV_FILE" | xargs)
echo "[entrypoint] Secrets env file: ${SECRET_COUNT} vars collected for SecretRef resolution"

# -----------------------------------------------------------------------------
# 4d. Doctor --fix disabled — was corrupting gateway state on volumes where
#     /data/.openclaw is root-owned (doctor can't write as openclaw user).
#     Run manually via SSH if needed: openclaw doctor --fix
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 5. Start OpenClaw gateway (if configured)
# -----------------------------------------------------------------------------
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

start_gateway() {
  echo "[entrypoint] Starting gateway on port ${GATEWAY_PORT}..."

  # Start gateway with env -i + secret env vars for SecretRef resolution.
  # The config file contains SecretRef objects (not plaintext). The gateway
  # resolves them from its process.env at startup, then holds values in-memory.
  #
  # Security model:
  #   - Config on disk: SecretRef objects only (no plaintext secrets)
  #   - Gateway /proc/self/environ: has secret env vars (needed for resolution)
  #   - Protected by: workspaceOnly (can't read /proc), exec allowlist (Tier 0-1)
  #   - Tier 2+: accepted risk (full exec can read anything)
  #
  # Gateway stdout is piped through log-bridge.js which:
  # - Passes through lines containing '[' to stdout (same as old grep chain)
  # - When TOOL_OBSERVER_ENABLED=true, also extracts tool events and batches
  #   them to the configured channel (Telegram/Discord)

  # Build log-bridge CLI args
  LOG_BRIDGE_ARGS=""
  if [ "${TOOL_OBSERVER_ENABLED:-false}" = "true" ]; then
    # Auto-detect channel and credentials
    OBSERVER_CHANNEL=""
    OBSERVER_TOKEN=""
    OBSERVER_CHAT_ID="${TOOL_OBSERVER_CHAT_ID:-}"

    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
      OBSERVER_CHANNEL="telegram"
      OBSERVER_TOKEN="$TELEGRAM_BOT_TOKEN"
      OBSERVER_CHAT_ID="${OBSERVER_CHAT_ID:-$TELEGRAM_OWNER_ID}"
    elif [ -n "$DISCORD_BOT_TOKEN" ]; then
      OBSERVER_CHANNEL="discord"
      OBSERVER_TOKEN="$DISCORD_BOT_TOKEN"
      OBSERVER_CHAT_ID="${OBSERVER_CHAT_ID:-$DISCORD_OWNER_ID}"
    fi

    if [ -n "$OBSERVER_CHANNEL" ] && [ -n "$OBSERVER_TOKEN" ] && [ -n "$OBSERVER_CHAT_ID" ]; then
      # Pass token via temp file instead of CLI arg — CLI args are visible in /proc/pid/cmdline
      OBSERVER_TOKEN_FILE=$(mktemp /tmp/observer-token.XXXXXX)
      printf '%s' "$OBSERVER_TOKEN" > "$OBSERVER_TOKEN_FILE"
      chmod 600 "$OBSERVER_TOKEN_FILE"
      LOG_BRIDGE_ARGS="--observer=true --channel=${OBSERVER_CHANNEL} --token-file=${OBSERVER_TOKEN_FILE} --chat-id=${OBSERVER_CHAT_ID}"
      [ -n "${TOOL_OBSERVER_THREAD_ID:-}" ] && LOG_BRIDGE_ARGS="${LOG_BRIDGE_ARGS} --thread-id=${TOOL_OBSERVER_THREAD_ID}"
      [ -n "${TOOL_OBSERVER_VERBOSITY:-}" ] && LOG_BRIDGE_ARGS="${LOG_BRIDGE_ARGS} --verbosity=${TOOL_OBSERVER_VERBOSITY}"
      echo "[entrypoint] Tool Observer enabled (channel: ${OBSERVER_CHANNEL}, chat: ${OBSERVER_CHAT_ID})"
    else
      echo "[entrypoint] WARNING: TOOL_OBSERVER_ENABLED=true but missing channel credentials — observer disabled"
    fi
  fi

  # Build the env var passthrough from the secrets file.
  # Each line in .secrets.env is KEY=VALUE — store as array elements so values
  # containing spaces or special characters are preserved (no word-splitting).
  SECRETS_ARGS=()
  if [ -f "$SECRETS_ENV_FILE" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      SECRETS_ARGS+=("$line")
    done < "$SECRETS_ENV_FILE"
  fi

  # Bonjour/mDNS gateway discovery is useless on Railway (no LAN multicast)
  # and crashes the gateway with `CIAO PROBING CANCELLED` unhandled rejections
  # when the advertiser gets stuck in the probing state. Disable by default;
  # users on a multicast-capable network can opt back in via OPENCLAW_ENABLE_BONJOUR=1.
  BONJOUR_ENV_ARG=""
  if [ "${OPENCLAW_ENABLE_BONJOUR:-0}" != "1" ]; then
    BONJOUR_ENV_ARG="OPENCLAW_DISABLE_BONJOUR=1"
  fi

  env -i \
    HOME=/home/openclaw \
    PATH=/data/bin:/usr/local/bin:/usr/bin:/bin \
    OPENCLAW_STATE_DIR=/data/.openclaw \
    NODE_ENV=production \
    ${BONJOUR_ENV_ARG} \
    "${SECRETS_ARGS[@]}" \
    su openclaw -c "cd /data/workspace && openclaw gateway run --port ${GATEWAY_PORT} --compact 2>&1" | node /app/src/log-bridge.js ${LOG_BRIDGE_ARGS} &
  GATEWAY_PID=$!

  sleep 3

  if kill -0 $GATEWAY_PID 2>/dev/null; then
    echo "[entrypoint] Gateway running (PID: $GATEWAY_PID)"

    # Delete the secrets env file — gateway has already resolved SecretRefs
    # into its in-memory snapshot. The file is no longer needed.
    rm -f "$SECRETS_ENV_FILE"
    echo "[entrypoint] Secrets env file deleted (resolved into gateway memory)"

    # --- SecretRef validation ---
    # Verify the config file on disk has no plaintext secrets.
    # SecretRef fields should be objects with "source" key, not strings.
    # This catches regressions where we accidentally write literals.
    #
    # Previous implementation piped node output through `while read` which
    # ran in a subshell — SECRETREF_VALIDATION_FAILED never propagated.
    # Now we capture into a variable so the parent shell can act on it.
    if [ -f "$CONFIG_FILE" ]; then
      SECRETREF_RESULT=$(node -e "
        const fs = require('fs');
        const config = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
        const errors = [];

        // Helper: check if a value is a SecretRef object or absent
        function checkRef(path, val) {
          if (val === undefined || val === null) return;
          if (typeof val === 'object' && val.source) return; // valid SecretRef
          if (typeof val === 'string') {
            errors.push(path + ': plaintext string found (expected SecretRef object)');
          }
        }

        // Channel credentials
        if (config.channels?.telegram?.botToken)
          checkRef('channels.telegram.botToken', config.channels.telegram.botToken);
        if (config.channels?.discord?.token)
          checkRef('channels.discord.token', config.channels.discord.token);
        if (config.channels?.slack?.botToken)
          checkRef('channels.slack.botToken', config.channels.slack.botToken);
        if (config.channels?.slack?.appToken)
          checkRef('channels.slack.appToken', config.channels.slack.appToken);

        // Search API key
        if (config.tools?.web?.search?.apiKey)
          checkRef('tools.web.search.apiKey', config.tools.web.search.apiKey);

        // Embeddings API key
        if (config.agents?.defaults?.memorySearch?.remote?.apiKey)
          checkRef('agents.defaults.memorySearch.remote.apiKey', config.agents.defaults.memorySearch.remote.apiKey);

        // Gateway token (allowed to be literal string if randomly generated)
        // Only check if GATEWAY_TOKEN env var was set (meaning we should have a SecretRef)
        if (process.env.GATEWAY_TOKEN && config.gateway?.auth?.token)
          checkRef('gateway.auth.token', config.gateway.auth.token);

        // Check config.env for leaked provider keys
        if (config.env) {
          const sensitivePatterns = /API_KEY|BOT_TOKEN|SECRET/i;
          for (const [key, val] of Object.entries(config.env)) {
            if (sensitivePatterns.test(key) && typeof val === 'string') {
              errors.push('config.env.' + key + ': secret leaked into config.env block');
            }
          }
        }

        if (errors.length > 0) {
          console.log('SECRETREF_FAIL');
          errors.forEach(e => console.log('  - ' + e));
        } else {
          console.log('SECRETREF_OK');
        }
      " 2>/dev/null)

      if echo "$SECRETREF_RESULT" | grep -q "SECRETREF_FAIL"; then
        echo "[entrypoint] ERROR: SecretRef validation FAILED — plaintext secrets in config!"
        echo "$SECRETREF_RESULT" | grep "^  -" | while IFS= read -r detail; do
          echo "[entrypoint] $detail"
        done
        echo "[entrypoint] FATAL: Refusing to run with plaintext secrets. Fix build-config.js."
        kill $GATEWAY_PID 2>/dev/null
        rm -f "$SECRETS_ENV_FILE"
        exit 1
      elif echo "$SECRETREF_RESULT" | grep -q "SECRETREF_OK"; then
        echo "[entrypoint] SecretRef validation: OK (no plaintext secrets in config)"
      fi
    fi

    # Config stays at 640 root:openclaw (set in step 4b).
    # Gateway re-reads config periodically for health snapshots, so the
    # openclaw group must retain read access. Write is blocked (root-owned).
    # Config now contains SecretRef objects, not plaintext secrets.
    echo "[entrypoint] Config contains SecretRef objects (no plaintext secrets on disk)"
  else
    echo "[entrypoint] ERROR: Gateway exited immediately"
    rm -f "$SECRETS_ENV_FILE"
    exit 1
  fi
}

if [ -f "$CONFIG_FILE" ]; then
  start_gateway

  # Watchdog: if the gateway dies, kill PID 1 so Railway sees a container exit
  # and respawns cleanly. Without this, the gateway can crash silently while
  # the health server keeps the container alive returning 503 — Railway will
  # only retry restartPolicyMaxRetries times before giving up entirely.
  (
    sleep 30  # Grace period for gateway to fully boot
    while true; do
      if ! pgrep -f "openclaw gateway run|openclaw-gateway" >/dev/null 2>&1; then
        echo "[entrypoint] Watchdog: gateway process gone — exiting container so Railway respawns"
        kill -TERM 1 2>/dev/null
        sleep 5
        kill -KILL 1 2>/dev/null
        exit 1
      fi
      sleep 10
    done
  ) &
  disown
else
  echo "[entrypoint] =============================================="
  echo "[entrypoint] WARNING: No config generated — fallback mode"
  echo "[entrypoint] =============================================="
  echo "[entrypoint] build-config.js did not produce $CONFIG_FILE."
  echo "[entrypoint] Missing required env vars (LLM provider key + channel token)."
  echo "[entrypoint] The gateway is NOT running. Fix: set env vars and redeploy,"
  echo "[entrypoint] or SSH in and run: openclaw onboard"
  echo "[entrypoint] Starting config-watcher fallback (logs streamed below)..."

  # Stream watcher output to stdout so Railway logs capture it.
  /app/config-watcher.sh 2>&1 | while IFS= read -r line; do
    echo "[config-watcher] $line"
  done &
  disown
fi

# -----------------------------------------------------------------------------
# 6. Start health check server (drops to openclaw user, scrubbed env)
#    Health server only needs PORT — strip everything else to minimize
#    what's visible in /proc/self/environ for this process tree.
# -----------------------------------------------------------------------------
echo "[entrypoint] Starting health server..."
exec env -i HOME=/home/openclaw PATH=/usr/local/bin:/usr/bin:/bin PORT="${PORT:-8080}" \
  su openclaw -c "cd /app && node src/server.js"
