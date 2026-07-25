import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { applySecurityTier } from '../src/build-config.js';

const defaults = JSON.parse(readFileSync(new URL('../config/defaults.json', import.meta.url)));
const tier0 = JSON.parse(readFileSync(new URL('../config/exec-approvals-tier0.json', import.meta.url)));
const tier1 = JSON.parse(readFileSync(new URL('../config/exec-approvals-tier1.json', import.meta.url)));

function entries(policy) {
  return policy.agents.main.allowlist;
}

function commandEntries(policy, command) {
  return entries(policy).filter((entry) => entry.lastUsedCommand === command);
}

function allows(entry, args) {
  return new RegExp(entry.argPattern).test(args);
}

test('all restricted-tier command entries constrain their arguments', () => {
  for (const policy of [tier0, tier1]) {
    for (const entry of entries(policy)) {
      assert.equal(typeof entry.argPattern, 'string', `${entry.id} must define argPattern`);
      assert.notEqual(entry.argPattern, '', `${entry.id} must not use an empty argPattern`);
    }
  }
});

test('Tier 0 ls stays inside the workspace', () => {
  for (const entry of commandEntries(tier0, 'ls')) {
    assert.equal(allows(entry, ''), true);
    assert.equal(allows(entry, '-la projects/current'), true);
    assert.equal(allows(entry, '/data/.openclaw'), false);
    assert.equal(allows(entry, '../.openclaw'), false);
    assert.equal(allows(entry, 'projects/../../.openclaw'), false);
  }
});

test('Tier 1 does not trust git or dangerous find operations', () => {
  assert.equal(commandEntries(tier1, 'git').length, 0);

  const [find] = commandEntries(tier1, 'find');
  assert.ok(find, 'Tier 1 find entry is required');
  assert.equal(allows(find, '. -maxdepth 2 -type f -name *.md -print'), true);
  assert.equal(allows(find, '/data/.openclaw -type f'), false);
  assert.equal(allows(find, '.. -type f'), false);
  assert.equal(allows(find, '. -exec cat {} ;'), false);
  assert.equal(allows(find, '. -delete'), false);
});

test('Tier 1 text tools cannot name files outside the workspace', () => {
  for (const command of ['wc', 'sort', 'uniq']) {
    for (const entry of commandEntries(tier1, command)) {
      assert.equal(allows(entry, '/proc/1/environ'), false, `${command} allowed an absolute path`);
      assert.equal(allows(entry, '../secret'), false, `${command} allowed path traversal`);
    }
  }
});

test('inline command execution hardening is enabled', () => {
  assert.equal(defaults.tools.exec.strictInlineEval, true);
});

test('full-shell tiers explicitly disable restricted-tier inline hardening', () => {
  const config = structuredClone(defaults);
  applySecurityTier(config, 2);
  assert.equal(config.tools.exec.security, 'full');
  assert.equal(config.tools.exec.strictInlineEval, false);
});
