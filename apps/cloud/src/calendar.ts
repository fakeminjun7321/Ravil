import { active, digest, scheduleTasks, stableJSON } from '../../website/src/workspace/domain.ts';
import { entities, HTTPError, json, type Env } from './worker.ts';
import {calendarTasks} from './calendar-scope.ts';
async function key(secret: string) { return crypto.subtle.importKey('raw', await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret)), { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']); }
async function encrypt(value: any, env: Env, owner: string) { const iv = crypto.getRandomValues(new Uint8Array(12)); const bytes = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(owner) }, await key(env.AUTH_SECRET), new TextEncoder().encode(JSON.stringify(value))); return JSON.stringify({ iv: Array.from(iv), data: Array.from(new Uint8Array(bytes)) }); }
async function decrypt(value: string, env: Env, owner: string) { const saved = JSON.parse(value); const bytes = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: new Uint8Array(saved.iv), additionalData: new TextEncoder().encode(owner) }, await key(env.AUTH_SECRET), new Uint8Array(saved.data)); return JSON.parse(new TextDecoder().decode(bytes)); }
async function google(url: string, token: string, method = 'GET', body?: any, extra: Record<string, string> = {}): Promise<any> {
    const response = await fetch(url, { method, headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', ...extra }, body: body === undefined ? undefined : JSON.stringify(body) });
    if (response.status === 404)
        return null;
    if (!response.ok)
        throw new HTTPError(response.status === 429 ? 429 : 502, 'Google Calendar 요청을 마치지 못했습니다 (HTTP ' + response.status + '). 자동 재시도하지 않았습니다.');
    return response.status === 204 ? {} : response.json();
}
export async function calendarRoute(request: Request, env: Env, owner: string): Promise<Response> {
    const path = new URL(request.url).pathname;
    const saved = await env.DB.prepare('SELECT encrypted FROM workspace_calendar_credentials WHERE owner=?').bind(owner).first<{
        encrypted: string;
    }>();
    if (path === '/api/calendar/status')
        return json({ connected: !!saved });
    if (path === '/api/calendar/disconnect' && request.method === 'POST') {
        await env.DB.prepare('DELETE FROM workspace_calendar_credentials WHERE owner=?').bind(owner).run();
        return json({ connected: false });
    }
    if (path === '/api/calendar/connect' && request.method === 'POST') {
        const input: any = await request.json();
        if (typeof input.refreshToken !== 'string' || input.refreshToken.length > 5000 || typeof input.clientID !== 'string' || !input.clientID.endsWith('.apps.googleusercontent.com') || typeof input.clientSecret !== 'string')
            throw new HTTPError(400, 'Google Calendar 연결 정보를 확인해 주세요.');
        const verification = await fetch('https://oauth2.googleapis.com/token', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams({client_id:input.clientID,client_secret:input.clientSecret,refresh_token:input.refreshToken,grant_type:'refresh_token'})});
        if(!verification.ok) throw new HTTPError(401,'Google 연결을 확인하지 못했습니다. Mac에서 다시 연결해 주세요.');
        const verifiedToken:any = await verification.json();
        const verifiedCalendar=await google('https://www.googleapis.com/calendar/v3/calendars/primary/events?maxResults=1',verifiedToken.access_token);
        if(!verifiedCalendar)throw new HTTPError(401,'Google Calendar 접근 권한을 확인하지 못했습니다.');
        const encoded = await encrypt({ refreshToken: input.refreshToken, clientID: input.clientID, clientSecret: input.clientSecret }, env, owner);
        await env.DB.prepare('INSERT INTO workspace_calendar_credentials(owner,encrypted) VALUES (?,?) ON CONFLICT(owner) DO UPDATE SET encrypted=excluded.encrypted').bind(owner, encoded).run();
        return json({ connected: true });
    }
    if (path !== '/api/calendar/sync' || request.method !== 'POST')
        throw new HTTPError(404, '캘린더 요청을 찾지 못했습니다.');
    let input:{taskIDs?:unknown};
    try{input=request.body?await request.json() as {taskIDs?:unknown}:{};}catch{throw new HTTPError(400,'캘린더 배치 요청을 확인해 주세요.');}
    if(!input||typeof input!=='object'||Array.isArray(input))throw new HTTPError(400,'캘린더 배치 요청을 확인해 주세요.');
    const all = await entities(env, owner);
    let tasks;
    try{tasks=calendarTasks(all,input.taskIDs);}catch(error){throw new HTTPError(409,(error as Error).message);}
    if (tasks.length > 100)
        throw new HTTPError(413, '한 번에 배치할 날짜가 있는 할 일은 100개까지입니다.');
    if (!tasks.length)
        return json({ blocks: [], unplaced: [], created: 0, updated: 0 });
    if (!saved)
        throw new HTTPError(409, 'Mac 앱에서 Google Calendar를 먼저 연결해 주세요.');
    const credential = await decrypt(saved.encrypted, env, owner);
    const response = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: credential.clientID, client_secret: credential.clientSecret, refresh_token: credential.refreshToken, grant_type: 'refresh_token' }) });
    if (!response.ok)
        throw new HTTPError(401, 'Google Calendar 연결이 만료되었거나 권한이 부족합니다. Mac에서 다시 연결해 주세요.');
    const token: any = await response.json();
    const days = tasks.map(e => String(e.payload.day)).sort();
    const min = days[0] + 'T00:00:00+09:00';
    const max = days[days.length - 1] + 'T23:59:59+09:00';
    if (Date.parse(max) - Date.parse(min) > 91 * 86400000)
        throw new HTTPError(400, '이번 배치 범위를 3개월 이내로 좁혀 주세요.');
    const query = new URLSearchParams({ singleEvents: 'true', timeMin: min, timeMax: max, maxResults: '2500' });
    const base = 'https://www.googleapis.com/calendar/v3/calendars/primary/events';
    const calendar = await google(base + '?' + query, token.access_token);
    if (calendar.nextPageToken)
        throw new HTTPError(413, '일정이 많아 빈 시간을 모두 확인하지 못했습니다. 배치를 중단했습니다.');
    const prefix = await digest(owner);
    const items = (calendar.items || []).filter((e: any) => e.status !== 'cancelled');
    const busy = items.filter((e: any) => e.transparency !== 'transparent' && e.extendedProperties?.private?.ravilOwner !== prefix).map((e: any) => ({ start: e.start?.dateTime || (e.start?.date + 'T00:00:00+09:00'), end: e.end?.dateTime || (e.end?.date + 'T00:00:00+09:00') }));
    const settings = active(all, 'preference').find(e => e.payload.key === 'planner')?.payload || {};
    const start = Math.min(22, Math.max(0, Number(settings.startHour ?? 19))), end = Math.min(24, Math.max(start + 1, Number(settings.endHour ?? 23))), rest = Math.min(60, Math.max(0, Number(settings.breakMinutes ?? 5)));
    const result = scheduleTasks(tasks, start, end, rest, busy);
    if(result.blocks.length>50)throw new HTTPError(413,'한 번에 50개까지 캘린더에 배치할 수 있습니다. 날짜 범위를 좁혀 주세요.');
    let created = 0, updated = 0, manualChanges = 0;
    for (const block of result.blocks) {
        const eventID = 'ravil' + (await digest(owner + '|' + block.id)).slice(0, 50);
        const previous = items.find((e: any) => e.id === eventID);
        const payload = { id: eventID, summary: block.title, start: { dateTime: block.start, timeZone: 'Asia/Seoul' }, end: { dateTime: block.end, timeZone: 'Asia/Seoul' }, description: 'RAVIL 기록과 계획에서 배치한 할 일입니다.', extendedProperties: { private: { ravilOwner: prefix, ravilBlock: block.id } } };
        const hash = await digest(stableJSON(payload));
        const link = await env.DB.prepare('SELECT digest FROM workspace_calendar_links WHERE owner=? AND block_id=?').bind(owner, block.id).first<{
            digest: string;
        }>();
        if (previous && previous.extendedProperties?.private?.ravilOwner !== prefix)
            throw new HTTPError(409, '같은 ID의 다른 일정이 있어 배치를 중단했습니다.');
        if (previous && link?.digest === hash) {
            if (Date.parse(previous.start?.dateTime) !== Date.parse(block.start) || Date.parse(previous.end?.dateTime) !== Date.parse(block.end))
                manualChanges++;
            continue;
        }
        const confirmed = previous ? await google(base + '/' + eventID, token.access_token, 'PATCH', { summary: payload.summary, start: payload.start, end: payload.end, description: payload.description, extendedProperties: payload.extendedProperties }, { 'If-Match': previous.etag }) : await google(base, token.access_token, 'POST', payload);
        if (confirmed?.id !== eventID || Date.parse(confirmed.start?.dateTime) !== Date.parse(block.start))
            throw new HTTPError(502, '캘린더의 저장 결과를 확인하지 못했습니다. 다시 배치하기 전에 일정 상태를 확인해 주세요.');
        await env.DB.prepare('INSERT INTO workspace_calendar_links(owner,block_id,event_id,digest) VALUES (?,?,?,?) ON CONFLICT(owner,block_id) DO UPDATE SET event_id=excluded.event_id,digest=excluded.digest').bind(owner, block.id, eventID, hash).run();
        if (previous)
            updated++;
        else
            created++;
    }
    return json({ ...result, created, updated, manualChanges });
}
