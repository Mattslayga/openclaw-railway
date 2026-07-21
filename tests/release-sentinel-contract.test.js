import assert from 'node:assert/strict';
import test from 'node:test';

import {
  classifyFailure,
  compareOpenClawVersions,
  evidenceMatches,
  evaluationKey,
  isPrerelease,
  selectCandidate,
  shouldEvaluate,
} from '../scripts/lib/release-sentinel-contract.js';

test('selects only a changed stable/latest candidate', () => {
  assert.equal(selectCandidate({ currentPin: '2026.5.22', latestStable: '2026.7.1-2' }), '2026.7.1-2');
  assert.equal(selectCandidate({ currentPin: '2026.7.1-2', latestStable: '2026.7.1-2' }), null);
  assert.equal(selectCandidate({ currentPin: '2026.7.1-2', latestStable: '2026.6.11' }), null);
  assert.equal(selectCandidate({ currentPin: '2026.7.1-2', latestStable: '2026.7.2-canary.1' }), null);
  assert.equal(isPrerelease('2026.7.2-beta.3'), true);
  assert.equal(isPrerelease('2026.7.1-2'), false);
  assert.ok(compareOpenClawVersions('2026.7.1-2', '2026.7.1') > 0);
});

test('requires candidate and repository identity to match across evidence', () => {
  const evidence = { version: '2026.7.1-2', repoCommit: 'abc', workspaceFingerprint: 'tree' };
  assert.equal(evidenceMatches(evidence, { ...evidence }), true);
  assert.equal(evidenceMatches(evidence, { ...evidence, workspaceFingerprint: 'other' }), false);
});

test('suppresses a completed evaluation until its inputs change', () => {
  const key = evaluationKey({ currentPin: '1.0.0', candidate: '1.1.0', workspaceFingerprint: 'abc' });
  const stagingKey = evaluationKey({ currentPin: '1.0.0', candidate: '1.1.0', workspaceFingerprint: 'abc', stagingRequested: true });
  assert.notEqual(key, stagingKey);
  assert.equal(shouldEvaluate({ key, previousState: { evaluationKey: key, verdict: 'BLOCK' } }), false);
  assert.equal(shouldEvaluate({ key, previousState: { evaluationKey: 'different', verdict: 'BLOCK' } }), true);
  assert.equal(shouldEvaluate({ key, previousState: { evaluationKey: key, verdict: 'RUNNING' } }), true);
});

test('turns known failures into focused repair classifications', () => {
  const permission = classifyFailure('EACCES renaming exec-approvals.json');
  assert.equal(permission.id, 'permissions');
  assert.ok(permission.files.includes('entrypoint.sh'));

  const unknown = classifyFailure('something novel happened');
  assert.equal(unknown.id, 'unclassified');
});
