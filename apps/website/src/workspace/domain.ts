export type EntityKind = 'record' | 'subject' | 'project' | 'task' | 'observation' | 'preference';
export interface Entity {
    id: string;
    kind: EntityKind;
    payload: Record<string, any>;
    revision: number;
    deleted: boolean;
    updatedAt: string;
    pending?: boolean;
    conflict?: Entity;
}
export interface TaskDraft {
    topic: string;
    action: string;
    day: string;
    repetitions: number;
    minutes: number;
}
export const examplePlan = `1. 10.14
기하광학 (1) 양기선 문제 풀기 (2) 학습지 재정독 2회
(3) 기하광학 이론 백지 공부
파동광학
(1) 양기선 문제 풀기
(2) 학습지 재정독 3회
(3) 파동광학 이론 백지 공부
정전기학
(1) 양기선 문제 풀기
(2) 학습지 리딩
(3) 정전기학 백지 공부
축전기 & 전기회로
(1) 양기선 문제 풀기
(2) 학습지 리딩
(3) 이론 백지 공부
2. 10.15
기하광학
(1) 학습지 재정독
(2) 틀린 문제 재점검
(3) 백지에 한번 더 써보기
파동광학
(1) 학습지 재정독
(2) 틀린 문제 재점검
(3) 무한암기, 백지에 한번 더 써보기
정전기학
(1) 틀린 문제 재점검
(2) 백지 공부
축전기 & 전기회로
(1) 틀린 문제 재점검
(2) 백지 공부`;
export function parsePlan(body: string, referenceDate = new Date()): {
    tasks: TaskDraft[];
    warnings: string[];
} {
    const tasks: TaskDraft[] = [];
    const warnings: string[] = [];
    const year = Number(new Intl.DateTimeFormat('en', { timeZone: 'Asia/Seoul', year: 'numeric' }).format(referenceDate));
    const lines = body.replace(/&#x20;|&nbsp;/g, ' ').replace(/\((\d+)\)/g, '\n($1)').split(/\r?\n/);
    let day = '', topic = '';
    for (const raw of lines) {
        const line = raw.trim().replace(/^#{1,6}\s+/, '');
        if (!line)
            continue;
        const date = line.match(/^(?:\d+[.)]\s+)?(?:(\d{4})[-/.])?(\d{1,2})[./-](\d{1,2})(?:\s*(?:일|\([^)]*\)))?(?:\s+(.+))?\s*$/);
        if (date) {
            const y = Number(date[1] || year), m = Number(date[2]), d = Number(date[3]);
            const check = new Date(Date.UTC(y, m - 1, d));
            if (check.getUTCFullYear() !== y || check.getUTCMonth() !== m - 1 || check.getUTCDate() !== d) {
                warnings.push(`날짜 확인: ${line}`);
                day = '';
            }
            else
                day = `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
            const heading=String(date[4]||'').trim();
            topic = /^(?:공부할\s*것|공부\s*계획|계획|할\s*일)$/.test(heading)?'':heading;
            continue;
        }
        const numbered = /^(?:\(\d+\)|\d+[.)]|[-*]|\[[ xX]\])\s*/.test(line);
        if (!numbered && !/(풀기|정독|공부|리딩|재점검|암기|읽기|보기|하기|작성|정리|복습|검토|확인|연락|예약|보내기|준비|구매|수정|제출|운동|산책|회\s*$)/.test(line)) {
            topic = line.replace(/^#+\s*/, '');
            continue;
        }
        const repetition = line.match(/(\d+)\s*회/);
        const count = repetition ? Number(repetition[1]) : 1;
        if (count < 1 || count > 99) {
            warnings.push(`횟수 확인: ${line}`);
            continue;
        }
        const action = line.replace(/^(?:\(\d+\)|\d+[.)]|[-*]|\[[ xX]\])\s*/, '').replace(/^\[[ xX]\]\s*/,'').replace(/\s*\d+\s*회\s*$/, '').trim();
        if (action)
            tasks.push({ topic, action, day, repetitions: count, minutes: 30 });
    }
    return { tasks, warnings };
}
export async function digest(text: string | ArrayBuffer): Promise<string> {
    const value = await crypto.subtle.digest('SHA-256', typeof text === 'string' ? new TextEncoder().encode(text) : text);
    return Array.from(new Uint8Array(value), b => b.toString(16).padStart(2, '0')).join('');
}
export async function taskID(recordID: string, task: TaskDraft): Promise<string> {
    const h = await digest([recordID, task.day, task.topic, task.action].join('\n'));
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}
export function stableJSON(value: any): string {
    if (Array.isArray(value))
        return `[${value.map(stableJSON).join(',')}]`;
    if (value && typeof value === 'object')
        return `{${Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + stableJSON(value[k])).join(',')}}`;
    return JSON.stringify(value);
}
export function active(entities: Entity[], kind: EntityKind) { return entities.filter(e => e.kind === kind && !e.deleted); }
export function searchTerms(query: string): string[] {
    const stop = new Set(['전에', '내가', '했던', '적은', '기록', '메모', '찾아', '찾아줘', '알려줘', '계획', '대한', '관련', '내용', '무엇', '어떤', '어떻게', '뭐', '어디', '좀']);
    return [...new Set(query.toLocaleLowerCase().split(/[^\p{L}\p{N}]+/u)
        .map(term => term.replace(/(?:에서는|으로는|에서|에게|으로|처럼|에는|은|는|이|가|을|를|와|과)$/u, suffix => term.length - suffix.length >= 2 ? '' : suffix))
        .filter(term => term.length > 1 && !stop.has(term)))];
}
export function searchRecords(entities: Entity[], query: string): Entity[] {
    const terms = searchTerms(query);
    const contexts = new Map(entities.filter(e => !e.deleted && ['subject', 'project'].includes(e.kind)).map(e => [e.id, e.payload.title]));
    return active(entities, 'record').map(e => {
        const p = e.payload, analysis = p.aiAnalysis?.stale === true ? undefined : p.aiAnalysis;
        const text = [p.title, p.body, ...(p.tags || []), ...(p.projectHistory || []), ...(p.examHistory || []),
            ...[...(p.subjectIDs || []), ...(p.projectIDs || [])].map((id: string) => contexts.get(id) || ''),
            analysis?.summary || (!p.aiAnalysis ? p.summary : ''), ...(analysis?.tags || [])].join(' ').toLocaleLowerCase();
        return { e, score: terms.reduce((n, term) => n + (text.includes(term) ? 1 : 0), 0) };
    }).filter(x => !terms.length || x.score > 0).sort((a, b) => b.score - a.score || b.e.updatedAt.localeCompare(a.e.updatedAt)).map(x => x.e);
}
export function personalContext(entities: Entity[]) {
    const observations = active(entities, 'observation');
    const tasks = active(entities, 'task');
    const durations = observations.filter(e => ['study', 'work'].includes(e.payload.event) && e.payload.minutes > 0);
    const groups = new Map<string, Entity[]>();
    for (const e of durations) {
        const label = String(e.payload.action || '작업');
        groups.set(label, [...(groups.get(label) || []), e]);
    }
    return { observedActivities: observations.length, completedTasks: tasks.filter(e => e.payload.completed >= e.payload.repetitions).length,
        estimates: [...groups].map(([action, items]) => { const values = items.map(e => Number(e.payload.minutes)).sort((a, b) => a - b); const middle = Math.floor(values.length / 2); return { action, minutes: values.length % 2 ? values[middle] : (values[middle - 1] + values[middle]) / 2, samples: values.length, evidenceIDs: items.map(e => e.id), status: items.length >= 3 ? '추정' : '기록 부족' }; }),
        corrections: active(entities, 'preference').filter(e => typeof e.payload.text === 'string' && e.payload.text.trim()).map(e => ({ id: e.id, text: e.payload.text })) };
}
export interface ScheduledBlock {
    id: string;
    taskID: string;
    title: string;
    start: string;
    end: string;
    repetition: number;
}
export function scheduleTasks(tasks: Entity[], startHour = 19, endHour = 23, breakMinutes = 5, busy: {
    start: string;
    end: string;
}[] = [], now = new Date()): {
    blocks: ScheduledBlock[];
    unplaced: string[];
} {
    const blocks: ScheduledBlock[] = [];
    const unplaced: string[] = [];
    const occupied = busy.map(b => ({ start: Date.parse(b.start), end: Date.parse(b.end) }));
    const recordOrder=new Map<string,number>();
    for(const task of tasks){const key=String(task.payload.recordID||'');if(!recordOrder.has(key))recordOrder.set(key,recordOrder.size);}
    const sorted = [...tasks].sort((a,b)=>String(a.payload.day).localeCompare(String(b.payload.day)) ||
        recordOrder.get(String(a.payload.recordID||''))!-recordOrder.get(String(b.payload.recordID||''))! ||
        (a.payload.planOrder??10000)-(b.payload.planOrder??10000));
    for (const task of sorted) {
        const p = task.payload;
        if (!/^\d{4}-\d{2}-\d{2}$/.test(p.day || '')) {
            unplaced.push(task.id);
            continue;
        }
        const limit = Date.parse(`${p.day}T${String(endHour).padStart(2, '0')}:00:00+09:00`);
        let cursor = Math.max(Date.parse(`${p.day}T${String(startHour).padStart(2, '0')}:00:00+09:00`), now.getTime());
        for (let r = Number(p.completed || 0) + 1; r <= p.repetitions; r++) {
            const duration = Number(p.minutes || 30) * 60000;
            let found = false;
            while (cursor + duration <= limit) {
                const clash = occupied.filter(b => cursor < b.end && cursor + duration > b.start).sort((a, b) => a.end - b.end)[0];
                if (clash) {
                    cursor = clash.end;
                    continue;
                }
                const end = cursor + duration;
                const block = { id: `${task.id}:${r}`, taskID: task.id, title: `${p.topic ? p.topic + ' · ' : ''}${p.action}${p.repetitions > 1 ? ` (${r}/${p.repetitions})` : ''}`, start: new Date(cursor).toISOString(), end: new Date(end).toISOString(), repetition: r };
                blocks.push(block);
                occupied.push({ start: cursor, end: end + breakMinutes * 60000 });
                cursor = end + breakMinutes * 60000;
                found = true;
                break;
            }
            if (!found) {
                unplaced.push(`${task.id}:${r}`);
            }
        }
    }
    return { blocks, unplaced };
}
