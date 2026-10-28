import assert from 'node:assert/strict';

const base = process.argv[2] || 'https://workspace-preview.ravil-website.pages.dev';
assert.equal(new URL(base).origin, base);
assert.ok(['workspace-preview.ravil-website.pages.dev', '127.0.0.1', 'localhost'].includes(new URL(base).hostname), 'Preview targets only');
const backend = 'https://ravil-workspace-preview.fakeminjun7321-f03.workers.dev';
let requests = 0;
async function request(origin:string, path:string, body?:unknown, headers:Record<string,string>={}) {
  assert.ok(++requests <= 16, 'Bounded preview request budget');
  const r = await fetch(origin+path, {
    redirect:'manual', method:body === undefined ? 'GET':'POST',
    headers:{Origin:origin, ...(body === undefined ? {} : {'Content-Type':'application/json'}), ...headers},
    body:body === undefined ? undefined : JSON.stringify(body)
  });
  if (r.status===429 || r.status===402) throw new Error('Quota response; no retries');
  return {status:r.status, headers:r.headers, value: r.headers.get('content-type')?.includes('json') ? await r.json() as any : await r.text()};
}
const home = await request(base, '/');
assert.equal(home.status,200);
assert.ok(home.value.includes('href="/workspace/"'), 'Introduction links to its own workspace');
assert.ok(home.value.includes('href="/login/"'), 'Introduction has a login entry');
const loginPage=await request(base, '/login/');
assert.equal(loginPage.status,200);
assert.ok(loginPage.value.includes('id="auth-form"'), 'Dedicated login form');
const deniedPage = await request(base, '/workspace/');
assert.equal(deniedPage.status,303, 'Direct workspace access redirects without a session');
assert.equal(deniedPage.headers.get('location'),'/login/?next=%2Fworkspace%2F');
const suffix=crypto.randomUUID();
const email='site-qa-'+suffix+'@example.test', password='QA-'+crypto.randomUUID();
const signed=await request(base, '/api/auth/sign-up/email', {email,password,name:'Introduction integration QA'});
assert.equal(signed.status,200,'Signup through Pages service binding');
const cookies=signed.headers.getSetCookie();
assert.ok(cookies.some(c=>c.includes('session_token=')), 'Browser session cookie returned');
assert.ok(cookies.every(c=>!/(^|;)\s*domain=/i.test(c)), 'Cookies are scoped to the current host');
assert.ok(cookies.some(c=>/httponly/i.test(c)), 'Session is HttpOnly');
const cookie=cookies.map(c=>c.split(';')[0]).join('; ');
const session=await request(base, '/api/auth/get-session', undefined, {Cookie:cookie});
assert.equal(session.value.user.id,signed.value.user.id);
const protectedPage = await request(base, '/workspace/', undefined, {Cookie:cookie});
assert.equal(protectedPage.status,200);
assert.ok(protectedPage.value.includes('내 작업 · RAVIL'));
assert.ok(protectedPage.headers.get('cache-control')?.includes('no-store'));
const id=crypto.randomUUID();
const record={id,kind:'record',revision:0,deleted:false,updatedAt:new Date().toISOString(),payload:{title:'소개 사이트 연결 검증',body:'소개에서 내 작업으로 들어와 저장한 검증용 기록.',subjectIDs:[],projectIDs:[],fileIDs:[],tags:[],kind:'memo',createdAt:new Date().toISOString()}};
const saved=await request(base, '/api/sync', {changes:[record]}, {Cookie:cookie});
assert.equal(saved.status,200);
assert.equal(saved.value.results[0].applied,true);
const reopened=await request(base, '/api/workspace', undefined, {Cookie:cookie});
assert.equal(reopened.value.entities.find((e:any)=>e.id===id).payload.body,record.payload.body, 'Persisted record reopened through same host');
const rejected=await request(base, '/api/auth/sign-out', {}, {Cookie:cookie,Origin:'https://evil.example.test'});
assert.equal(rejected.status,403, 'Foreign-origin signout blocked');
const stillSigned=await request(base, '/api/auth/get-session', undefined, {Cookie:cookie});
assert.equal(stillSigned.value.user.id,signed.value.user.id);
const nativeSession=await request(backend, '/api/auth/sign-in/email', {email,password});
assert.equal(nativeSession.status,200,'Same account accepted by the Mac API host');
const shared=await request(backend, '/api/workspace', undefined, {Authorization:'Bearer '+nativeSession.value.token});
assert.equal(shared.value.entities.find((e:any)=>e.id===id).payload.body,record.payload.body, 'Pages and Mac backend share the actual record');
assert.equal((await request(base, '/api/auth/sign-out', {}, {Cookie:cookie})).status,200);
const loggedOut=await request(base, '/api/auth/get-session', undefined, {Cookie:cookie});
assert.equal(loggedOut.value,null, 'Browser signout revoked the session');
const afterLogout=await request(base, '/workspace/', undefined, {Cookie:cookie});
assert.equal(afterLogout.status,303, 'Logged out users cannot reopen the workspace');
assert.equal((await request(backend, '/workspace/')).status,303, 'Mac web mirror also requires login');
console.log(JSON.stringify({passed:true,target:new URL(base).hostname,requests,checks:['introduction-login-entry','protected-workspace','host-only-cookie','cookie-session','actual-record-persistence','csrf-origin','shared-mac-backend','signout']}));
