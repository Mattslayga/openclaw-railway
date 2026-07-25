import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { relative, resolve } from 'node:path';

export function isPrerelease(version) {
  return String(version || '').includes('-') && !/-\d+$/.test(String(version || ''));
}

export function compareOpenClawVersions(left, right) {
  const parse = (value) => {
    const match = String(value || '').match(/^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/);
    if (!match) return null;
    return {
      core: match.slice(1, 4).map(Number),
      revision: /^\d+$/.test(match[4] || '') ? Number(match[4]) : 0,
      prerelease: match[4] && !/^\d+$/.test(match[4]) ? match[4] : '',
    };
  };
  const a = parse(left);
  const b = parse(right);
  if (!a || !b) return String(left).localeCompare(String(right));
  for (let index = 0; index < a.core.length; index += 1) {
    if (a.core[index] !== b.core[index]) return a.core[index] - b.core[index];
  }
  if (a.prerelease !== b.prerelease) {
    if (!a.prerelease) return 1;
    if (!b.prerelease) return -1;
    return a.prerelease.localeCompare(b.prerelease);
  }
  return a.revision - b.revision;
}

export function selectCandidate({ currentPin, latestStable }) {
  if (
    !latestStable ||
    !currentPin ||
    currentPin === 'unknown' ||
    isPrerelease(latestStable) ||
    compareOpenClawVersions(latestStable, currentPin) <= 0
  ) {
    return null;
  }
  return latestStable;
}

export function evidenceMatches(left, right) {
  return Boolean(
    left &&
      right &&
      left.version === right.version &&
      left.repoCommit === right.repoCommit &&
      left.workspaceFingerprint === right.workspaceFingerprint,
  );
}

export function evaluationKey({ currentPin, candidate, workspaceFingerprint, stagingRequested = false }) {
  return createHash('sha256')
    .update(JSON.stringify({ currentPin, candidate, workspaceFingerprint, stagingRequested }))
    .digest('hex');
}

export function shouldEvaluate({ key, previousState }) {
  if (!previousState || previousState.evaluationKey !== key) return true;
  return !['BLOCK', 'HOLD', 'PROMOTE'].includes(previousState.verdict);
}

export function classifyFailure(text) {
  const value = String(text || '');
  const rules = [
    {
      id: 'permissions',
      pattern: /EACCES|permission denied|operation not permitted|exec-approvals/i,
      files: ['entrypoint.sh', 'docs/SECURITY.md', 'docs/SANDBOXING.md', 'scripts/validate-openclaw-local.sh'],
      acceptance: ['Local permission assertions pass', 'Root-owned config remains protected', 'Candidate and current pin both boot'],
    },
    {
      id: 'plugin-channel',
      pattern: /discord|plugin|Cannot find module|Module not found|ready \(0 plugins\)/i,
      files: ['entrypoint.sh', 'src/build-config.js', 'scripts/validate-openclaw-local.sh'],
      acceptance: ['Required plugin is version-aligned and loaded', 'Generated channel config validates', 'No plugin blocker appears in logs'],
    },
    {
      id: 'config-schema',
      pattern: /config|schema|unknown key|unrecognized|rejected/i,
      files: ['src/build-config.js', 'config/defaults.json', 'scripts/validate-openclaw-local.sh'],
      acceptance: ['Generated config passes upstream schema validation', 'Security defaults remain intact'],
    },
    {
      id: 'container-build',
      pattern: /docker build|npm|does not exist|package.*(?:missing|not found)|installed version/i,
      files: ['Dockerfile', 'entrypoint.sh', 'scripts/validate-openclaw-local.sh'],
      acceptance: ['Candidate package exists', 'Docker image builds', 'Installed version matches candidate'],
    },
    {
      id: 'runtime-health',
      pattern: /healthz|gateway|container exited|watchdog|UnhandledPromiseRejection/i,
      files: ['entrypoint.sh', 'src/server.js', 'railway.toml', 'scripts/validate-openclaw-local.sh'],
      acceptance: ['Container reaches health within the bounded timeout', 'Gateway remains running', 'Blocker scan is clean'],
    },
  ];

  return (
    rules.find((rule) => rule.pattern.test(value)) || {
      id: 'unclassified',
      files: [],
      acceptance: ['Reproduce the failure', 'Classify the root cause', 'Add a regression assertion before repair'],
    }
  );
}

function git(repoDir, args, options = {}) {
  return execFileSync('git', ['-C', repoDir, ...args], { encoding: 'utf8', ...options });
}

export function repositoryEvidence(repoDir) {
  const root = resolve(repoDir);
  const repoCommit = git(root, ['rev-parse', 'HEAD']).trim();
  const diff = git(root, ['diff', '--binary', 'HEAD', '--', '.', ':(exclude).validation']);
  const untracked = git(root, ['ls-files', '--others', '--exclude-standard', '-z'])
    .split('\0')
    .filter((path) => path && !path.startsWith('.validation/'))
    .sort();
  const hash = createHash('sha256').update(repoCommit).update('\0').update(diff);

  for (const path of untracked) {
    const absolute = resolve(root, path);
    if (!existsSync(absolute) || !statSync(absolute).isFile()) continue;
    hash.update('\0').update(relative(root, absolute)).update('\0').update(readFileSync(absolute));
  }

  return {
    repoCommit,
    workspaceFingerprint: hash.digest('hex'),
    dirty: Boolean(diff || untracked.length),
  };
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === 'context') {
    console.log(JSON.stringify(repositoryEvidence(args[0] || process.cwd())));
    return;
  }
  if (command === 'classify') {
    console.log(JSON.stringify(classifyFailure(readFileSync(args[0], 'utf8'))));
    return;
  }
  if (command === 'candidate') {
    console.log(selectCandidate({ currentPin: args[0], latestStable: args[1] }) || '');
    return;
  }
  if (command === 'evaluation-key') {
    console.log(
      evaluationKey({
        currentPin: args[0],
        candidate: args[1],
        workspaceFingerprint: args[2],
        stagingRequested: args[3] === '1',
      }),
    );
    return;
  }
  throw new Error(`Unknown command: ${command || '(missing)'}`);
}

if (process.argv[1] && import.meta.url === new URL(`file://${resolve(process.argv[1])}`).href) {
  main();
}
