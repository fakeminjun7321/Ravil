import {planningText} from './note-format';
import { active, parsePlan, taskID, stableJSON, personalContext, type Entity, type EntityKind } from './domain.ts';
import {analysisDigest, invalidateAnalysis, recordInput, type AnalysisResult} from './second-brain.ts';
export {getRecordAnalysis} from './second-brain.ts';
const dbPromise = new Promise<IDBDatabase>((resolve, reject) => { const req = indexedDB.open('ravil-workspace-v1', 1); req.onupgradeneeded = () => req.result.createObjectStore('entities', { keyPath: 'key' }); req.onsuccess = () => resolve(req.result); req.onerror = () => reject(req.error); });
async function saved(owner: string): Promise<Entity[]> { const db = await dbPromise; return new Promise((resolve, reject) => { const req = db.transaction('entities').objectStore('entities').getAll(); req.onsuccess = () => resolve(req.result.filter((r: any) => r.owner === owner).map((r: any) => r.entity)); req.onerror = () => reject(req.error); }); }
async function persist(owner: string, e: Entity) { const db = await dbPromise; return new Promise<void>((resolve, reject) => { const transaction = db.transaction('entities', 'readwrite'); transaction.objectStore('entities').put({ key: owner + '/' + e.id, owner, entity: e }); transaction.oncomplete = () => resolve(); transaction.onerror = () => reject(transaction.error); }); }
class SessionEnded extends Error {}
export class WorkspaceStore extends EventTarget {
    owner = localStorage.getItem('ravil-owner') || 'guest';
    user: any = null;
    entities: Entity[] = [];
    status = '기기에 저장됨';
    online = false;
    syncing = false;
    error = '';
    private timer?: ReturnType<typeof setInterval>;
    private syncFlight?: Promise<void>;
    async initialize() { await this.session(); this.timer = setInterval(() => { if (document.visibilityState === 'visible')
        void this.sync(); }, 30000); window.addEventListener('online', () => void this.sync()); document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible')
        void this.sync(); }); }
    changed() { this.dispatchEvent(new Event('change')); }
    async api(path: string, body?: any, method?: string): Promise<any> {
        const response = await fetch('/api/' + path, { method: method || (body === undefined ? 'GET' : 'POST'), credentials: 'include', headers: body === undefined ? {} : { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
        const result = await response.json();
        if (response.status === 401) throw new SessionEnded('다시 로그인해 주세요.');
        if (!response.ok)
            throw new Error(result.error || result.message || '요청을 마치지 못했습니다.');
        return result;
    }
    async session() { try {
        const response = await fetch('/api/auth/get-session', { credentials: 'include' });
        if (!response.ok)
            throw new Error();
        const value = await response.json();
        if (value?.user) {
            this.user = value.user;
            this.online = true;
            this.owner = value.user.id;
            localStorage.setItem('ravil-owner', this.owner);
            this.entities = await saved(this.owner);
            await this.sync();
        }
        else {
            this.lock();
        }
    }
    catch {
        this.online = false;
        this.status = this.user ? '오프라인 · 기기에 저장됨' : '로그인 확인에 연결이 필요해요.';
    } this.changed(); }
    async signIn(email: string, password: string, name?: string) { const value = await this.api(name ? 'auth/sign-up/email' : 'auth/sign-in/email', { email, password, ...(name ? { name } : {}) }); this.user = value.user; this.owner = value.user.id; localStorage.setItem('ravil-owner', this.owner); this.entities = await saved(this.owner); this.online = true; await this.sync(); this.changed(); }
    lock() { this.dispatchEvent(new Event('beforelock')); this.user = null; this.online = false; this.entities = []; this.status = '다시 로그인해 주세요.'; this.changed(); }
    async signOut() { await this.api('auth/sign-out', {}); this.user = null; this.owner = 'guest'; this.online = false; localStorage.removeItem('ravil-owner'); this.entities = []; this.status = '로그아웃됨'; this.changed(); }
    async adoptGuest() { if (!this.user)
        return; const guest = await saved('guest'); for (const item of guest) {
        const adopted = { ...item, revision: 0, pending: true, conflict: undefined };
        this.entities.push(adopted);
        await persist(this.owner, adopted);
    } const db = await dbPromise; const tx = db.transaction('entities', 'readwrite'); for (const e of guest)
        tx.objectStore('entities').delete('guest/' + e.id); await this.sync(); this.changed(); }
    async hasGuest() { return (await saved('guest')).some(e => !e.deleted); }
    get(id: string) { return this.entities.find(e => e.id === id && !e.deleted); }
    stopPolling() { if (this.timer)
        clearInterval(this.timer); }
    async put(kind: EntityKind, payload: Record<string, any>, id: string = crypto.randomUUID(), deleted = false, expectedRevision?: number) { const previous = this.entities.find(e => e.id === id); if (kind === 'record') payload = invalidateAnalysis(previous?.payload, payload); if (previous && previous.deleted === deleted && stableJSON(previous.payload) === stableJSON(payload))
        return previous; const e: Entity = { id, kind, payload, revision: expectedRevision ?? previous?.revision ?? 0, deleted, updatedAt: new Date().toISOString(), pending: true, conflict: previous?.conflict }; this.entities = this.entities.filter(x => x.id !== id).concat(e); await persist(this.owner, e); this.status = '기기에 저장됨'; this.changed(); return e; }
    async saveAnalysis(record: Entity, result: AnalysisResult) {
        if (!result || typeof result.inputDigest !== 'string')
            throw new Error('AI 응답 형식이 현재 작업 공간과 맞지 않습니다. 업데이트를 확인해 주세요. 원문은 보존됩니다.');
        const owner = this.owner;
        const expected = recordInput(record.payload);
        const inputDigest = await analysisDigest(record);
        const current = this.get(record.id);
        if (this.owner !== owner || (result.ownerID && result.ownerID !== owner) || !current || current.conflict || recordInput(current.payload) !== expected || result.inputDigest !== inputDigest)
            throw new Error('분석 중 원문이나 연결이 바뀌었습니다. 현재 기록으로 다시 요청해 주세요.');
        return this.put('record', {...current.payload,
            aiAnalysis: {...result, generatedAt: new Date().toISOString(), stale: false},
            summary: result.summary, aiSuggestions: result.suggestions}, record.id);
    }
    async observe(event: string, recordID?: string, taskIDValue?: string, minutes?: number, action?: string) { await this.put('observation', { event, recordID, taskID: taskIDValue, minutes, action, at: new Date().toISOString() }); }
    async organize(record: Entity) {
        const parsed = parsePlan(record.payload.format==='markdown'?planningText(record.payload.body):record.payload.body, new Date(record.payload.createdAt));
        const retained = new Set<string>();
        for (const [planOrder,draft] of parsed.tasks.entries()) {
            const id = await taskID(record.id, draft);
            retained.add(id);
            const old = this.get(id);
            const estimate = personalContext(this.entities).estimates.find(e=>e.action===draft.action&&e.samples>=3);
            const minutes = old?.payload.minutes || (estimate ? Math.max(5,Math.min(180,Math.round(estimate.minutes/5)*5)) : draft.minutes);
            await this.put('task', { ...draft, planOrder, minutes, estimatedFromIDs:estimate?.evidenceIDs||[], recordID: record.id, subjectIDs: record.payload.subjectIDs, completed: Math.min(old?.payload.completed || 0, draft.repetitions) }, id);
        }
        for (const e of active(this.entities, 'task').filter(e => e.payload.recordID === record.id && !retained.has(e.id)))
            await this.put('task', e.payload, e.id, true);
        await this.put('record', { ...record.payload, kind: 'plan', parseWarnings: parsed.warnings }, record.id);
        await this.observe('planChanged', record.id);
        await this.sync();
        return parsed;
    }
    async complete(task: Entity) { const n = task.payload.completed >= task.payload.repetitions ? 0 : task.payload.completed + 1; await this.put('task', { ...task.payload, completed: n }, task.id); await this.observe('complete', task.payload.recordID, task.id, undefined, task.payload.action); await this.sync(); }
    async resolveConflict(id: string, choice: 'remote' | 'copy') { const local = this.entities.find(e => e.id === id); if (!local?.conflict)
        return; const remote = local.conflict; if (choice === 'copy')
        await this.put(local.kind, local.payload); this.entities = this.entities.filter(e => e.id !== id).concat({ ...remote, pending: false }); await persist(this.owner, { ...remote, pending: false }); this.changed(); await this.sync(); }
    async sync() {
        if (!this.user || !this.online) return;
        if (this.syncFlight) return this.syncFlight;
        this.syncFlight = (async () => {
            // Finish edits made during an earlier request before an awaiting save returns.
            for (let pass = 0; pass < 3; pass++) {
                await this.syncPass();
                if (this.error || !this.user || !this.entities.some(e => e.pending && !e.conflict)) break;
            }
        })();
        try { await this.syncFlight; } finally { this.syncFlight = undefined; }
    }
    private async syncPass() {
        this.syncing = true;
        const syncOwner = this.owner;
        this.status = '동기화 중…';
        this.changed();
        try {
            const pending = this.entities.filter(e => e.pending && !e.conflict).slice(0, 100);
            if (pending.length) {
                const sent = new Map(pending.map(e => [e.id, JSON.stringify(e.payload)]));
                const sentRevisions = new Map(pending.map(e => [e.id, e.revision]));
                const sentDeleted = new Map(pending.map(e => [e.id, e.deleted]));
                const response = await this.api('sync', { changes: pending.map(({ pending, conflict, ...e }) => e) });
                if (this.owner !== syncOwner || !this.user) return;
                for (const result of response.results) {
                    const current = this.entities.find(e => e.id === result.id);
                    if (!current)
                        continue;
                    if (result.applied && result.entity) {
                        if (JSON.stringify(current.payload) === sent.get(current.id) && current.deleted === sentDeleted.get(current.id)) {
                            Object.assign(current, result.entity, { pending: false, conflict: undefined });
                        }
                        else
                            current.revision = result.entity.revision;
                        this.dispatchEvent(new CustomEvent('acknowledged', { detail: { id: current.id, sourceRevision: sentRevisions.get(current.id), revision: result.entity.revision } }));
                    }
                    else
                        current.conflict = result.entity;
                    await persist(this.owner, current);
                }
            }
            const remote = await this.api('workspace');
            if (this.owner !== syncOwner || !this.user) return;
            for (const e of remote.entities) {
                const local = this.entities.find(x => x.id === e.id);
                if (local?.pending) {
                    if (e.revision !== local.revision && !local.conflict)
                        local.conflict = e;
                    await persist(this.owner, local);
                    continue;
                }
                this.entities = this.entities.filter(x => x.id !== e.id).concat({ ...e, pending: false });
                await persist(this.owner, { ...e, pending: false });
            }
            this.status = this.entities.some(e => e.conflict) ? '동시 수정 확인 필요' : this.entities.some(e => e.pending) ? '추가 변경 동기화 대기' : '클라우드에 저장됨';
            this.error = '';
        }
        catch (e) {
            if (e instanceof SessionEnded) { this.lock(); return; }
            this.status = '기기에 저장됨 · 동기화 대기';
            this.error = (e as Error).message;
        }
        finally {
            this.syncing = false;
            this.changed();
        }
    }
}
