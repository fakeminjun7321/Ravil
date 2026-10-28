import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {analysisDigest, buildAnalysisContext, normalizeAnalysis} from '../../website/src/workspace/second-brain.ts';
import {type Entity} from '../../website/src/workspace/domain.ts';

const base = process.argv[2] || 'http://127.0.0.1:8896';
assert.ok(['localhost', '127.0.0.1'].includes(new URL(base).hostname), 'This integration check is localhost-only');
let requests = 0;
async function api(path: string, body?: any, token?: string, method?: string) {
    assert.ok(++requests <= 35, 'Bounded localhost request budget');
    const response = await fetch(base + '/api/' + path, {method: method || (body === undefined ? 'GET' : 'POST'), redirect: 'error', signal: AbortSignal.timeout(10000),
        headers: {Origin: base, ...(body === undefined ? {} : {'Content-Type': 'application/json'}), ...(token ? {Authorization: 'Bearer ' + token} : {})},
        body: body === undefined ? undefined : JSON.stringify(body)});
    assert.notEqual(response.status, 429, 'Stop on a quota response');
    return {status: response.status, value: await response.json() as any};
}
// Reuse existing synthetic accounts when composing local checks, so repeated
// test setup does not hit the service's unchanged signup-attempt limit.
const reuse = process.argv[3] ? JSON.parse(readFileSync(process.argv[3], 'utf8')) : undefined;
if (reuse) assert.equal(reuse.base, base, 'Fixture belongs to this localhost service');
const suffix = crypto.randomUUID(), password = reuse?.password || 'QA-' + crypto.randomUUID(), email = reuse?.email || 'second-brain-' + suffix + '@example.test';
const endpoint = reuse ? 'auth/sign-in/email' : 'auth/sign-up/email';
const registered = await api(endpoint, {email, password, name: 'Second brain local QA'});
assert.equal(registered.status, 200);
const token = registered.value.token;
const otherEmail = reuse?.otherEmail || 'other-' + suffix + '@example.test';
const other = await api(endpoint, {email: otherEmail, password, name: 'Other local QA'});
assert.equal(other.status, 200);
const make = (kind: Entity['kind'], payload: Record<string, any>): Entity => ({id: crypto.randomUUID(), kind, payload, revision: 0, deleted: false, updatedAt: new Date().toISOString()});
let project = make('project', {title: '사진집 만들기', kind: 'project', phase: 'active', examDate: ''});
const original = '사진집을 만들고 싶다. 인쇄 견적과 표지 아이디어를 기록한다.';
let record = make('record', {title: '사진집 아이디어', body: original, format: 'plain', kind: 'note', tags: ['내 태그'], subjectIDs: [], projectIDs: [project.id], fileIDs: [], createdAt: new Date().toISOString()});
async function sync(changes: Entity[]) {
    const response = await api('sync', {changes}, token); assert.equal(response.status, 200);
    assert.ok(response.value.results.every((item: any) => item.applied)); return response.value.results.map((item: any) => item.entity) as Entity[];
}
[project, record] = await sync([project, record]);
assert.equal((await api('workspace', undefined, other.value.token)).value.entities.length, 0);
assert.equal((await api('workspace')).status, 401);
assert.equal((await api('ai/analyze', {recordID: record.id, mode: 'question', question: '다음에 할 일은?'}, token)).status, 503, 'Local configuration deliberately has no paid AI binding');
assert.equal((await api('ai/analyze', {recordID: record.id, mode: 'question'}, token)).status, 400);

// Only the provider contract is doubled here. Authentication, D1 persistence,
// stale-result handling and backup/archive below use the actual local service.
const result = normalizeAnalysis({summary: '검증용 AI 결과: 사진집의 인쇄와 표지를 검토한다.', tags: ['사진집'], suggestions: [{text: '인쇄 견적 비교하기', evidenceIDs: [record.id]}]}, buildAnalysisContext([record, project], record), await analysisDigest(record));
[record] = await sync([{...record, payload: {...record.payload, aiAnalysis: {...result, generatedAt: new Date().toISOString(), stale: false}, summary: result.summary}}]);
const reopened = (await api('workspace', undefined, token)).value.entities.find((item: Entity) => item.id === record.id);
assert.equal(reopened.payload.body, original); assert.deepEqual(reopened.payload.tags, ['내 태그']);
assert.equal(reopened.payload.aiAnalysis.summary, result.summary);
[record] = await sync([{...record, payload: {...record.payload, body: original + '\n무광 용지도 비교한다.'}}]);
assert.equal(record.payload.aiAnalysis.stale, true); assert.equal(record.payload.summary, '');
assert.deepEqual(record.payload.tags, ['내 태그']);
const backup = await api('backup/' + project.id, {}, token);
assert.equal(backup.status, 200, 'Personal project backup requires neither a subject nor an exam date');
assert.equal((await api('projects/' + project.id + '/finish', {snapshotID: backup.value.snapshotID}, token)).status, 409);
const corrupted = structuredClone(backup.value); corrupted.entities.find((item: Entity) => item.id === record.id).payload.body = 'altered';
assert.equal((await api('backup/' + project.id + '/verify', corrupted, token)).status, 400);
assert.equal((await api('backup/' + project.id + '/verify', backup.value, token)).status, 200);
assert.equal((await api('projects/' + project.id + '/finish', {snapshotID: backup.value.snapshotID}, token)).status, 200);
const final = (await api('workspace', undefined, token)).value.entities;
const preserved = final.find((item: Entity) => item.id === record.id);
assert.ok(preserved.payload.body.startsWith(original)); assert.deepEqual(preserved.payload.projectIDs, []);
assert.deepEqual(preserved.payload.projectHistory, ['사진집 만들기']); assert.deepEqual(preserved.payload.subjectIDs, []);
assert.equal(final.find((item: Entity) => item.id === project.id).payload.phase, 'archived');
const directory = mkdtempSync(join(tmpdir(), 'ravil-second-brain-flow-'));
writeFileSync(join(directory, 'fixture.json'), JSON.stringify({base, email, password, owner: registered.value.user.id, recordID: record.id}), {mode: 0o600});
writeFileSync(join(directory, 'backup.json'), JSON.stringify(backup.value), {mode: 0o600});
console.log(JSON.stringify({passed: true, target: new URL(base).host, requests, productionRequests: 0,
    checks: ['real-local-auth', 'account-isolation', 'unclassified-personal-record', 'D1-reopen', 'manual-tags-preserved', 'AI-contract-result-persistence', 'server-stale-invalidation', 'backup-integrity', 'archive-preserves-original'],
    aiVerification: 'Provider double only; no live model invoked. Missing AI binding returns 503 without altering records.', fixtureDirectory: directory}));
