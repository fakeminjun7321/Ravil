import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parsePlan, personalContext, searchRecords, type Entity} from '../../website/src/workspace/domain.ts';
import {analysisDigest, buildAnalysisContext, getRecordAnalysis, invalidateAnalysis, normalizeAnalysis} from '../../website/src/workspace/second-brain.ts';
import {analyze, projectContents, HTTPError, type Env} from '../src/worker.ts';

const entity = (kind: Entity['kind'], id: string, payload: Record<string, any>): Entity => ({kind, id, payload, revision: 1, deleted: false, updatedAt: '2026-10-19T00:00:00Z'});
const record = (id: string, body: string, projectIDs: string[] = [], subjectIDs: string[] = []) => entity('record', id, {title: id, body, projectIDs, subjectIDs, fileIDs: [], tags: [], format: 'plain'});
const main = record('idea', '개인 사진집을 만들고 싶다. 다음에는 인쇄 견적을 확인한다.', ['photo-book']);
const related = record('printing', '사진집 인쇄는 무광 용지와 중철 제본을 비교한다.', ['photo-book']);
const unrelated = record('private-trip', '다른 프로젝트 여행 기록', ['trip']);
const all = [entity('project', 'photo-book', {title: '첫 사진집', kind: 'project', phase: 'active'}), main, related, unrelated,
    entity('observation', 'work', {event: 'work', recordID: main.id, action: '견적 확인', minutes: 20, at: '2026-10-19'}),
    entity('observation', 'other-work', {event: 'work', recordID: unrelated.id, action: '비공개 여행 작업', minutes: 30, at: '2026-10-19'})];

test('ordinary personal plans preserve dates, topic and actions without an exam', () => {
    const result = parsePlan('2026-10-20\n사진집\n인쇄 견적 확인\n- 표지 수정\n2026-10-21\n일상\n산책 2회', new Date('2026-10-19'));
    assert.deepEqual(result.tasks.map(task => [task.topic, task.action, task.day, task.repetitions]), [
        ['사진집', '인쇄 견적 확인', '2026-10-20', 1], ['사진집', '표지 수정', '2026-10-20', 1], ['일상', '산책', '2026-10-21', 2]]);
    assert.equal(parsePlan('[x] 제출 완료').tasks[0].action, '제출 완료');
});

test('search finds project names and current AI organization without requiring a subject', () => {
    const analyzed = {...main, payload: {...main.payload, aiAnalysis: {summary: '독립 출판 준비', tags: ['제본'], stale: false}}};
    assert.equal(searchRecords([...all.filter(e => e.id !== main.id), analyzed], '첫 사진집에서 적은 기록')[0].id, 'printing');
    assert.equal(searchRecords([analyzed], '독립 출판')[0].id, main.id);
    const stale = {...analyzed, payload: {...analyzed.payload, aiAnalysis: {...analyzed.payload.aiAnalysis, stale: true}}};
    assert.equal(searchRecords([stale], '독립 출판').length, 0);
    const archived = {...main, payload: {...main.payload, projectIDs: [], projectHistory: ['첫 사진집']}};
    assert.equal(searchRecords([archived], '첫 사진집')[0].id, main.id);
});

test('work and legacy study observations both support personal time estimates', () => {
    const events = [10, 20, 30].map((minutes, index) => entity('observation', 'event-' + index, {event: index ? 'work' : 'study', action: '견적 확인', minutes}));
    assert.equal(personalContext(events).estimates[0].minutes, 20);
    assert.equal(personalContext(events).estimates[0].samples, 3);
    const four = [...events, entity('observation', 'fourth', {event: 'work', action: '견적 확인', minutes: 40})];
    assert.equal(personalContext(four).estimates[0].minutes, 25, 'Even-sized activity samples use the mean of the two central values');
});

test('AI context includes related records and excludes unrelated activities and deleted records', () => {
    const context = buildAnalysisContext([...all, {...related, id: 'deleted', deleted: true}], main);
    assert.deepEqual(context.records.map(record => record.id), [main.id, related.id]);
    assert.deepEqual(context.activities.map(event => event.id), ['work']);
    assert.ok(!context.sources.some(source => ['other-work', unrelated.id, 'deleted'].includes(source.id)));
    assert.equal(context.records[0].projects[0], '첫 사진집');
});

test('an explicit question can retrieve a relevant record outside the selected project', () => {
    const context = buildAnalysisContext(all, main, '여행 기록은 무엇이었지?');
    assert.ok(context.records.some(record => record.id === unrelated.id));
});

test('large personal context stays bounded and identifies excerpts', () => {
    const records = Array.from({length: 8}, (_, index) => record('long-' + index, '가'.repeat(60000), ['photo-book']));
    const context = buildAnalysisContext([...records, ...all], records[0], '기록 분석');
    assert.equal(context.records.length, 5);
    assert.ok(context.records.every(record => record.excerpted));
    assert.ok(JSON.stringify(context).length <= 24000);
    assert.equal(JSON.parse(JSON.stringify(context)).recordID, records[0].id);
});

test('AI output only retains provided evidence and connections to actual related records', () => {
    const context = buildAnalysisContext(all, main, '어떤 용지를 비교할까?');
    const result = normalizeAnalysis({summary: '사진집 계획', tags: ['출판', null, '출판'],
        answer: '무광 용지를 비교하고 있다.', answerEvidenceIDs: [related.id],
        suggestions: [null, {text: '견적 확인하기', evidenceIDs: [main.id]}, {text: '비공개 기록 추측', evidenceIDs: ['other-work']}],
        connections: [{recordID: related.id, reason: '인쇄 검토', evidenceIDs: [main.id, related.id]}, {recordID: unrelated.id, reason: '추측', evidenceIDs: [main.id, unrelated.id]}]}, context, 'digest');
    assert.equal(result.suggestions.length, 1); assert.equal(result.connections.length, 1);
    assert.deepEqual(result.tags, ['출판']); assert.deepEqual(result.answerEvidenceIDs, [related.id]);
    assert.equal(result.insufficientEvidence, false);
});

test('an answer without valid evidence is replaced with an explicit lack-of-evidence response', () => {
    const context = buildAnalysisContext(all, main, '내 성격은?');
    const result = normalizeAnalysis({answer: '확신에 찬 추측', answerEvidenceIDs: ['invented']}, context, 'digest');
    assert.equal(result.insufficientEvidence, true); assert.deepEqual(result.answerEvidenceIDs, []);
    assert.ok(!result.answer.includes('확신')); assert.throws(() => normalizeAnalysis(null, context, 'digest'));
    assert.throws(() => normalizeAnalysis({}, buildAnalysisContext(all, main), 'digest'), /요약/);
});

test('editing content or scope marks analysis stale while preserving manual tags and the old result', () => {
    const previous = {...main.payload, tags: ['내 태그'], summary: '기존 요약', aiAnalysis: {summary: '기존 요약', stale: false}};
    const changed = invalidateAnalysis(previous, {...previous, body: '새 생각'});
    assert.equal(changed.body, '새 생각'); assert.deepEqual(changed.tags, ['내 태그']);
    assert.equal(changed.aiAnalysis.summary, '기존 요약'); assert.equal(changed.summary, '');
    assert.equal(getRecordAnalysis(changed), undefined);
    assert.equal(invalidateAnalysis(previous, {...previous, projectIDs: []}).aiAnalysis.stale, true);
    assert.equal(invalidateAnalysis(previous, {...previous, aiAnalysis: {summary: '새 요약', stale: false}}).aiAnalysis.stale, false);
});

test('project backup selection preserves unclassified personal records and their tasks', () => {
    const task = entity('task', 'next-action', {recordID: main.id, action: '견적 확인'});
    const selected = projectContents([...all, task], 'photo-book');
    assert.ok(selected.some(e => e.id === main.id)); assert.ok(selected.some(e => e.id === task.id));
    assert.ok(!selected.some(e => e.id === unrelated.id)); assert.deepEqual(main.payload.subjectIDs, []);
});

function environment(response: unknown = {summary: '사진집 계획', tags: ['출판'], suggestions: []}, failure = false) {
    let calls = 0, prompt: any;
    const env = {DB: {prepare() {return {bind(owner: string) {assert.equal(owner, 'owner-a'); return {async all() {return {results: all.map(e => ({id: e.id, kind: e.kind, payload: JSON.stringify(e.payload), revision: e.revision, deleted: 0, updated_at: e.updatedAt}))};}};}};}},
        AI: {async run(_model: string, input: any) {calls++; prompt = input; if (failure) throw new Error('provider unavailable'); return {response: typeof response === 'string' ? response : JSON.stringify(response)};}}} as unknown as Env;
    return {env, calls: () => calls, prompt: () => prompt};
}
const request = (body: unknown) => new Request('http://localhost/api/ai/analyze', {method: 'POST', body: JSON.stringify(body)});

test('AI handler uses the real grounding contract with a provider double and never mutates source data', async () => {
    const before = JSON.stringify(all);
    const fixture = environment({summary: '사진집', answer: '무광 용지', answerEvidenceIDs: [related.id]});
    const response = await analyze(request({recordID: main.id, question: '용지를 어떻게 정할까?'}), fixture.env, 'owner-a');
    const result = await response.json() as any;
    assert.equal(response.status, 200); assert.equal(fixture.calls(), 1);
    assert.equal(result.inputDigest, await analysisDigest(main)); assert.equal(result.mode, 'question');
    assert.equal(fixture.prompt().messages[0].role, 'system');
    assert.equal(JSON.parse(fixture.prompt().messages[1].content).recordID, main.id);
    assert.equal(JSON.stringify(all), before);
});

test('AI handler rejects malformed requests before provider calls and exposes unavailable/invalid providers', async () => {
    const fixture = environment();
    for (const input of [null, {recordID: main.id, question: 3}, {recordID: main.id, question: 'a'.repeat(2001)}, {recordID: main.id, mode: 'question'}, {recordID: 'absent'}]) {
        await assert.rejects(analyze(request(input), fixture.env, 'owner-a'), (error: HTTPError) => [400, 404].includes(error.status));
    }
    assert.equal(fixture.calls(), 0);
    const noAI = {...fixture.env, AI: undefined} as unknown as Env;
    await assert.rejects(analyze(request({recordID: main.id}), noAI, 'owner-a'), (error: HTTPError) => error.status === 503);
    await assert.rejects(analyze(request({recordID: main.id}), environment('not json').env, 'owner-a'), (error: HTTPError) => error.status === 502);
    await assert.rejects(analyze(request({recordID: main.id}), environment(null).env, 'owner-a'), (error: HTTPError) => error.status === 502);
    await assert.rejects(analyze(request({recordID: main.id}), environment({}).env, 'owner-a'), (error: HTTPError) => error.status === 502);
    await assert.rejects(analyze(request({recordID: main.id}), environment(undefined, true).env, 'owner-a'), (error: HTTPError) => error.status === 502);
});
