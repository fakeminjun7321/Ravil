import { authFor } from './auth.ts';
import { active, digest, stableJSON, type Entity } from '../../website/src/workspace/domain.ts';
import { calendarRoute } from './calendar.ts';
import {notificationRoute,sendBackupReminders} from './notifications.ts';
import { siteOrigin } from './site-origin.ts';
import { workspaceGate, privateWorkspace } from '../../website/src/auth/access.ts';
import {noteExportRoute,cleanupNoteExports,ExportDeliveryError} from './note-exports.ts';
import {analysisDigest, analysisSystemPrompt, buildAnalysisContext, invalidateAnalysis, normalizeAnalysis} from '../../website/src/workspace/second-brain.ts';
export interface Env {
    DB: D1Database;
    FILES: R2Bucket;
    ASSETS: Fetcher;
    AI: Ai;
    AUTH_SECRET: string;
    APP_ORIGIN: string;
    APP_ORIGINS?: string;
    VAPID_PUBLIC_KEY?: string;
    VAPID_PRIVATE_KEY?: string;
}
interface Row {
    id: string;
    kind: Entity['kind'];
    payload: string;
    revision: number;
    deleted: number;
    updated_at: string;
}
export class HTTPError extends Error {
    status: number;
    constructor(status: number, message: string) { super(message); this.status = status; }
}
export function json(value: any, status = 200) { return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } }); }
export function entity(row: Row): Entity { return { id: row.id, kind: row.kind, payload: JSON.parse(row.payload), revision: row.revision, deleted: !!row.deleted, updatedAt: row.updated_at }; }
export async function entities(env: Env, owner: string): Promise<Entity[]> {
    const result = await env.DB.prepare('SELECT * FROM workspace_entities WHERE owner=? ORDER BY id LIMIT 5001').bind(owner).all<Row>();
    if (result.results.length > 5000)
        throw new HTTPError(413, '기록이 많아 전체 동기화를 나눠 처리해야 합니다.');
    return result.results.map(entity);
}
export function tick(env: Env, owner: string) { return env.DB.prepare('INSERT INTO workspace_meta(owner,revision) VALUES (?,1) ON CONFLICT(owner) DO UPDATE SET revision=revision+1').bind(owner); }
export function update(env: Env, owner: string, e: Entity) { return env.DB.prepare('UPDATE workspace_entities SET payload=?,revision=revision+1,updated_at=? WHERE owner=? AND id=?').bind(JSON.stringify(e.payload), new Date().toISOString(), owner, e.id); }
async function revision(env: Env, owner: string) { return (await env.DB.prepare('SELECT revision FROM workspace_meta WHERE owner=?').bind(owner).first<{
    revision: number;
}>())?.revision || 0; }
function validate(e: any): Entity {
    if (!e || !/^[-a-zA-Z0-9]{1,80}$/.test(e.id) || !['record', 'subject', 'project', 'task', 'observation', 'preference'].includes(e.kind) || !e.payload || Array.isArray(e.payload) || typeof e.payload !== 'object' || !Number.isSafeInteger(e.revision) || e.revision < 0 || typeof e.deleted !== 'boolean')
        throw new HTTPError(400, '기록 형식을 확인해 주세요.');
    if (JSON.stringify(e.payload).length > 80000)
        throw new HTTPError(413, '한 기록은 80KB 이내로 나눠 주세요.');
    const p = e.payload;
    if (e.kind === 'record' && (typeof p.body !== 'string' || p.body.length > 60000 || typeof p.title !== 'string' || !Array.isArray(p.subjectIDs) || !Array.isArray(p.projectIDs) || !Array.isArray(p.fileIDs)))
        throw new HTTPError(400, '기록 본문과 연결 정보를 확인해 주세요.');
    if (e.kind === 'task' && (!Number.isInteger(p.repetitions) || p.repetitions < 1 || p.repetitions > 99 || !Number.isInteger(p.completed) || p.completed < 0 || p.completed > p.repetitions || !Number.isInteger(p.minutes) || p.minutes < 5 || p.minutes > 180 || typeof p.recordID !== 'string' || typeof p.action !== 'string' || !(p.day === '' || /^\d{4}-\d{2}-\d{2}$/.test(p.day))))
        throw new HTTPError(400, '할 일 날짜·횟수·시간을 확인해 주세요.');
    if (e.kind === 'observation' && (!['read', 'study', 'work', 'complete', 'planChanged', 'correction'].includes(p.event) || typeof p.at !== 'string' || (p.minutes != null && (!Number.isFinite(p.minutes) || p.minutes < 0 || p.minutes > 1440))))
        throw new HTTPError(400, '활동 기록을 확인해 주세요.');
    // Project lifecycle changes go through backup verification, never generic sync.
    if (e.kind === 'project' && (p.phase !== 'active' || e.deleted))
        throw new HTTPError(400, '프로젝트는 백업 확인 후 보관할 수 있습니다.');
    return e;
}
async function bodyJSON(request: Request, max = 2000000) { if (Number(request.headers.get('content-length') || 0) > max)
    throw new HTTPError(413, '요청이 너무 큽니다.'); const text = await request.text(); if (text.length > max)
    throw new HTTPError(413, '요청이 너무 큽니다.'); try {
    return JSON.parse(text);
}
catch {
    throw new HTTPError(400, '데이터 형식을 확인해 주세요.');
} }
async function sync(request: Request, env: Env, owner: string, ctx:ExecutionContext) {
    const input = await bodyJSON(request);
    if (!Array.isArray(input.changes) || input.changes.length > 100)
        throw new HTTPError(400, '한 번에 100개까지 동기화할 수 있습니다.');
    const changes: Entity[] = input.changes.map(validate);
    const previous = await entities(env, owner);
    for (const e of changes) {
        const old = previous.find(x => x.id === e.id);
        if (e.kind === 'record') e.payload = invalidateAnalysis(old?.payload, e.payload);
        if (e.kind === 'project' && old && old.payload.phase !== 'active')
            throw new HTTPError(409, '보관된 프로젝트는 일반 수정으로 다시 열 수 없습니다.');
    }
    if (new Set(changes.map(e => e.id)).size !== changes.length)
        throw new HTTPError(400, '중복된 동기화 요청입니다.');
    const now = new Date().toISOString();
    const statements = changes.map(e => env.DB.prepare('INSERT INTO workspace_entities(owner,id,kind,payload,revision,deleted,updated_at) SELECT ?,?,?,?,1,?,? WHERE ?=0 OR EXISTS(SELECT 1 FROM workspace_entities WHERE owner=? AND id=?) ON CONFLICT(owner,id) DO UPDATE SET payload=excluded.payload,revision=workspace_entities.revision+1,deleted=excluded.deleted,updated_at=excluded.updated_at WHERE workspace_entities.revision=? AND workspace_entities.kind=excluded.kind').bind(owner, e.id, e.kind, JSON.stringify(e.payload), e.deleted ? 1 : 0, now, e.revision, owner, e.id, e.revision));
    if (statements.length)
        statements.push(tick(env, owner));
    const results = statements.length ? await env.DB.batch(statements) : [];
    const current = await entities(env, owner);
    const planner=current.find(e=>e.kind==='preference'&&!e.deleted&&e.payload.key==='planner');
    if(planner?.payload.autoCalendar===true&&changes.some(e=>e.kind==='task')){
        ctx.waitUntil(autoCalendar(env,owner,planner));
    }
    return json({ results: changes.map((e, i) => ({ id: e.id, applied: !!results[i].meta.changes, entity: current.find(x => x.id === e.id) || null })), workspaceRevision: await revision(env, owner) });
}
async function autoCalendar(env:Env,owner:string,planner:Entity){
    const now=Date.now();
    const lock=await env.DB.prepare('INSERT INTO workspace_calendar_jobs(owner,locked_until) VALUES (?,?) ON CONFLICT(owner) DO UPDATE SET locked_until=excluded.locked_until WHERE locked_until<?').bind(owner,now+60000,now).run();
    if(!lock.meta.changes)return;
    try{
        const result=await calendarRoute(new Request(env.APP_ORIGIN+'/api/calendar/sync',{method:'POST'}),env,owner);
        const summary:any=await result.json();
        await env.DB.prepare('UPDATE workspace_calendar_jobs SET locked_until=0,summary=? WHERE owner=?').bind('새 일정 '+summary.created+'개 · 배치하지 못한 작업 '+summary.unplaced.length+'개',owner).run();
    }catch(error){
        await env.DB.prepare('UPDATE workspace_calendar_jobs SET locked_until=0,summary=? WHERE owner=?').bind(error instanceof HTTPError?error.message:'캘린더 배치를 마치지 못했습니다.',owner).run();
        planner.payload.autoCalendar=false;
        await env.DB.batch([update(env,owner,planner),tick(env,owner)]);
    }
}
export function projectContents(all: Entity[], projectID: string) {
    const project = active(all, 'project').find(e => e.id === projectID);
    if (!project)
        throw new HTTPError(404, '프로젝트를 찾지 못했습니다.');
    const records = active(all, 'record').filter(e => e.payload.projectIDs.includes(projectID));
    const ids = new Set(records.map(e => e.id));
    const subjects = new Set(records.flatMap(e => e.payload.subjectIDs));
    const tasks = active(all, 'task').filter(e => ids.has(e.payload.recordID));
    const taskIDs = new Set(tasks.map(e => e.id));
    const observations = active(all, 'observation').filter(e => ids.has(e.payload.recordID) || taskIDs.has(e.payload.taskID));
    return [project, ...records, ...tasks, ...observations, ...active(all, 'subject').filter(e => subjects.has(e.id))];
}
async function backupExport(env: Env, owner: string, projectID: string) {
    const revBefore = await revision(env, owner);
    const selected = projectContents(await entities(env, owner), projectID);
    const fileIDs = [...new Set(selected.filter(e => e.kind === 'record').flatMap(e => e.payload.fileIDs))];
    const files: any[] = [];
    let total = 0;
    for (const id of fileIDs) {
        const meta = await env.DB.prepare('SELECT id,name,mime,size,digest,object_key FROM workspace_files WHERE owner=? AND id=?').bind(owner, id).first<any>();
        if (!meta)
            throw new HTTPError(409, '연결된 파일이 없어 백업을 만들 수 없습니다.');
        total += meta.size;
        if (total > 32 * 1024 * 1024)
            throw new HTTPError(413, '현재 한 백업의 첨부파일 한도는 32MB입니다. 파일을 포함한 분할 백업이 필요합니다.');
        const object = await env.FILES.get(meta.object_key);
        if (!object)
            throw new HTTPError(409, '첨부파일을 가져오지 못했습니다. 백업이 완료되지 않았습니다.');
        const bytes = new Uint8Array(await object.arrayBuffer());
        let binary = '';
        for (let i = 0; i < bytes.length; i += 8192)
            binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
        files.push({ id: meta.id, name: meta.name, mime: meta.mime, size: meta.size, digest: meta.digest, data: btoa(binary) });
    }
    if (await revision(env, owner) !== revBefore)
        throw new HTTPError(409, '백업 중 기록이 변경되었습니다. 다시 만들어 주세요.');
    const contents = { entities: selected, files };
    const hash = await digest(stableJSON(contents));
    const snapshotID = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO workspace_backups(id,owner,project_id,workspace_revision,digest,created_at) VALUES (?,?,?,?,?,?)').bind(snapshotID, owner, projectID, revBefore, hash, new Date().toISOString()).run();
    return json({ format: 'ravil-backup', schemaVersion: 1, owner, projectID, snapshotID, exportedAt: new Date().toISOString(), digest: hash, ...contents });
}
async function backupVerify(request: Request, env: Env, owner: string, projectID: string) {
    const input = await bodyJSON(request, 48 * 1024 * 1024);
    if (input.format !== 'ravil-backup' || input.schemaVersion !== 1 || input.owner !== owner || input.projectID !== projectID || !Array.isArray(input.entities) || !Array.isArray(input.files))
        throw new HTTPError(400, '이 계정과 프로젝트의 백업 파일을 선택해 주세요.');
    const saved = await env.DB.prepare('SELECT * FROM workspace_backups WHERE id=? AND owner=? AND project_id=?').bind(input.snapshotID, owner, projectID).first<any>();
    if (!saved || saved.workspace_revision !== await revision(env, owner))
        throw new HTTPError(409, '백업 이후 기록이 바뀌었습니다. 새 백업이 필요합니다.');
    const hash = await digest(stableJSON({ entities: input.entities, files: input.files }));
    if (hash !== saved.digest || hash !== input.digest)
        throw new HTTPError(400, '백업 내용이 누락되거나 변경되었습니다.');
    const entityIDs = new Set(input.entities.map((e: any) => e.id));
    for (const e of input.entities) {
        if (e.kind === 'task' && !entityIDs.has(e.payload.recordID))
            throw new HTTPError(400, '할 일의 원본 기록이 누락되었습니다.');
    }
    const suppliedFileIDs = new Set(input.files.map((f: any) => f.id));
    for (const e of input.entities.filter((e: any) => e.kind === 'record'))
        for (const id of e.payload.fileIDs)
            if (!suppliedFileIDs.has(id))
                throw new HTTPError(400, '첨부파일이 백업에 누락되었습니다.');
    for (const f of input.files) {
        let bytes: Uint8Array;
        try {
            bytes = Uint8Array.from(atob(f.data), c => c.charCodeAt(0));
        }
        catch {
            throw new HTTPError(400, '첨부파일을 복원하지 못했습니다.');
        }
        if (bytes.length !== f.size || await digest(bytes.buffer as ArrayBuffer) !== f.digest)
            throw new HTTPError(400, '첨부파일의 무결성이 맞지 않습니다.');
    }
    await env.DB.prepare('UPDATE workspace_backups SET verified=1 WHERE id=? AND owner=?').bind(input.snapshotID, owner).run();
    return json({ verified: true, snapshotID: input.snapshotID, records: input.entities.filter((e: any) => e.kind === 'record').length, files: input.files.length });
}
async function finishProject(request: Request, env: Env, owner: string, projectID: string) {
    const input = await bodyJSON(request);
    const selected = projectContents(await entities(env, owner), projectID);
    const project = selected.find(e => e.id === projectID)!;
    const operations = [env.DB.prepare('INSERT INTO workspace_archive_commits(id,owner,backup_id) SELECT ?,?,id FROM workspace_backups WHERE id=? AND owner=? AND project_id=? RETURNING id').bind(crypto.randomUUID(), owner, input.snapshotID, owner, projectID)];
    // A missing receipt must cause the entire batch to fail, too.
    const snapshot = await env.DB.prepare('SELECT id FROM workspace_backups WHERE id=? AND owner=? AND project_id=? AND verified=1').bind(input.snapshotID, owner, projectID).first();
    if (!snapshot)
        throw new HTTPError(409, '다운로드한 백업을 먼저 검사해 주세요.');
    for (const record of selected.filter(e => e.kind === 'record')) {
        const previous = {...record.payload};
        record.payload.projectIDs = record.payload.projectIDs.filter((id: string) => id !== projectID);
        record.payload.projectHistory = [...new Set([...(record.payload.projectHistory || []), project.payload.title])];
        if (project.payload.kind === 'exam') record.payload.examHistory = [...new Set([...(record.payload.examHistory || []), project.payload.title])];
        record.payload = invalidateAnalysis(previous, record.payload);
        operations.push(update(env, owner, record));
    }
    project.payload.phase = 'archived';
    project.payload.archivedAt = new Date().toISOString();
    operations.push(update(env, owner, project), tick(env, owner));
    try {
        await env.DB.batch(operations);
    }
    catch {
        throw new HTTPError(409, '백업이 확인되지 않았거나 백업 뒤 기록이 바뀌었습니다. 새 백업을 검사해 주세요.');
    }
    return json({ archived: true, preservedRecords: selected.filter(e => e.kind === 'record').length });
}
async function fileRoute(request: Request, env: Env, owner: string, id: string) {
    if (!/^[a-f0-9-]{36}$/i.test(id))
        throw new HTTPError(400, '파일 ID를 확인해 주세요.');
    if (request.method === 'PUT') {
        const bytes = await request.arrayBuffer();
        if (bytes.byteLength > 20 * 1024 * 1024)
            throw new HTTPError(413, '파일당 20MB까지 연결할 수 있습니다.');
        const name = decodeURIComponent(request.headers.get('X-File-Name') || 'file').slice(0, 200);
        const mime = request.headers.get('Content-Type') || 'application/octet-stream';
        const hash = await digest(bytes);
        const key = owner + '/' + hash;
        if (await env.DB.prepare('SELECT id FROM workspace_files WHERE owner=? AND id=?').bind(owner, id).first())
            throw new HTTPError(409, '기존 파일은 덮어쓰지 않습니다. 새 판본을 추가해 주세요.');
        await env.FILES.put(key, bytes, { httpMetadata: { contentType: mime } });
        await env.DB.prepare('INSERT INTO workspace_files(owner,id,name,mime,size,digest,object_key) VALUES (?,?,?,?,?,?,?)').bind(owner, id, name, mime, bytes.byteLength, hash, key).run();
        return json({ id, name, mime, size: bytes.byteLength, digest: hash });
    }
    const meta = await env.DB.prepare('SELECT * FROM workspace_files WHERE owner=? AND id=?').bind(owner, id).first<any>();
    if (!meta)
        throw new HTTPError(404, '파일을 찾지 못했습니다.');
    const object = await env.FILES.get(meta.object_key);
    if (!object)
        throw new HTTPError(404, '파일을 찾지 못했습니다.');
    return new Response(object.body, { headers: { 'Content-Type': meta.mime, 'Content-Disposition': "attachment; filename*=UTF-8''" + encodeURIComponent(meta.name), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
}
export async function analyze(request: Request, env: Env, owner: string) {
    const input = await bodyJSON(request);
    if (!input || typeof input.recordID !== 'string' || (input.question != null && (typeof input.question !== 'string' || input.question.length > 2000)) ||
        (input.mode != null && !['organize', 'question'].includes(input.mode)))
        throw new HTTPError(400, '분석할 기록과 질문 형식을 확인해 주세요. 질문은 2,000자 이내로 적어 주세요.');
    const question = String(input.question || '').trim();
    const mode = input.mode || (question ? 'question' : 'organize');
    if (mode === 'question' && !question) throw new HTTPError(400, '기록에 물어볼 내용을 적어 주세요.');
    const all = await entities(env, owner);
    const record = active(all, 'record').find(e => e.id === input.recordID);
    if (!record)
        throw new HTTPError(404, '분석할 기록이 없습니다.');
    const context = buildAnalysisContext(all, record, question, mode);
    if(!env.AI)throw new HTTPError(503,'이 환경에는 AI 연결이 설정되지 않았습니다. 원문은 그대로 보관됩니다.');
    let result: any;
    try {
        result = await env.AI.run('@cf/meta/llama-3.1-8b-instruct-fast', {messages: [
            {role: 'system', content: analysisSystemPrompt}, {role: 'user', content: JSON.stringify(context)}], max_tokens: 1300});
    } catch { throw new HTTPError(502, 'AI 연결에서 응답을 받지 못했습니다. 저장한 기록은 보존됩니다.'); }
    let parsed: any;
    try {
        const text = String(result.response || '');
        parsed = JSON.parse(text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1));
    }
    catch {
        throw new HTTPError(502, 'AI 결과를 정리하지 못했습니다. 원문은 저장되어 있습니다.');
    }
    try { return json({...normalizeAnalysis(parsed, context, await analysisDigest(record)), ownerID: owner}); }
    catch { throw new HTTPError(502, 'AI 결과 형식을 확인하지 못했습니다. 원문은 저장되어 있습니다.'); }
}
export default {
    async fetch(request: Request, env: Env, ctx:ExecutionContext): Promise<Response> {
        const url = new URL(request.url);
        if (url.pathname === '/workspace' || url.pathname.startsWith('/workspace/')) {
            const origin = siteOrigin(request, env);
            if (!origin) return json({error:'허용되지 않은 사이트입니다.'},403);
            const denied = await workspaceGate(request, sessionRequest => authFor(env, origin).handler(sessionRequest));
            return denied || privateWorkspace(await env.ASSETS.fetch(request));
        }
        if (!url.pathname.startsWith('/api/'))
            return env.ASSETS.fetch(request);
        try {
            if (url.pathname === '/api/health')
                return json({ service: 'RAVIL workspace', version: 1 });
            const origin = siteOrigin(request, env);
            if (!origin)
                throw new HTTPError(403, '허용되지 않은 사이트입니다.');
            if (request.method !== 'GET' && request.method !== 'HEAD') {
                const suppliedOrigin = request.headers.get('Origin');
                if (suppliedOrigin && suppliedOrigin !== origin)
                    throw new HTTPError(403, '허용되지 않은 요청입니다.');
            }
            if (url.pathname.startsWith('/api/auth/'))
                return await authFor(env, origin).handler(request);
            const session = await authFor(env, origin).api.getSession({ headers: request.headers });
            if (!session)
                throw new HTTPError(401, '로그인이 필요합니다.');
            const owner = session.user.id;
            const exported=url.pathname.match(/^\/api\/exports\/([a-f0-9-]+)$/i);
            if(exported&&['GET','PUT','HEAD'].includes(request.method))return await noteExportRoute(request,env.DB,env.FILES,owner,exported[1]);
            if (url.pathname === '/api/workspace' && request.method === 'GET')
                return json({ entities: await entities(env, owner), workspaceRevision: await revision(env, owner) });
            if (url.pathname === '/api/sync' && request.method === 'POST')
                return await sync(request, env, owner,ctx);
            if (url.pathname === '/api/ai/analyze' && request.method === 'POST')
                return await analyze(request, env, owner);
            const backup = url.pathname.match(/^\/api\/backup\/([-a-zA-Z0-9]+)(\/verify)?$/);
            if (backup && request.method === 'POST')
                return await (backup[2] ? backupVerify(request, env, owner, backup[1]) : backupExport(env, owner, backup[1]));
            const finish = url.pathname.match(/^\/api\/projects\/([-a-zA-Z0-9]+)\/finish$/);
            if (finish && request.method === 'POST')
                return await finishProject(request, env, owner, finish[1]);
            const file = url.pathname.match(/^\/api\/files\/([a-f0-9-]+)$/i);
            if (file && ['GET', 'PUT'].includes(request.method))
                return await fileRoute(request, env, owner, file[1]);
            if (url.pathname.startsWith('/api/calendar/'))
                return await calendarRoute(request, env, owner);
            if (url.pathname.startsWith('/api/notifications/'))
                return await notificationRoute(request, env, owner);
            return json({ error: '요청한 기능을 찾지 못했습니다.' }, 404);
        }
        catch (error) {
            return json({ error: error instanceof HTTPError || error instanceof ExportDeliveryError ? error.message : '처리를 마치지 못했습니다. 저장한 기록은 보존됩니다.' }, error instanceof HTTPError || error instanceof ExportDeliveryError ? error.status : 500);
        }
    },
    async scheduled(_event:ScheduledController,env:Env,ctx:ExecutionContext){ctx.waitUntil(Promise.all([sendBackupReminders(env),cleanupNoteExports(env.DB,env.FILES)]));}
};
