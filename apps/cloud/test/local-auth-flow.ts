import assert from 'node:assert/strict';
const base=process.argv[2] || 'http://127.0.0.1:8790';
assert.ok(['127.0.0.1','localhost'].includes(new URL(base).hostname),'Localhost only');
let requests=0;
async function send(path:string, body?:any, cookie?:string) {
  assert.ok(++requests<=40,'Local test request bound');
  const response=await fetch(base+path,{method:body===undefined?'GET':'POST',redirect:'manual',signal:AbortSignal.timeout(10000),headers:{Origin:base,...(body===undefined?{}:{'Content-Type':'application/json'}),...(cookie?{Cookie:cookie}:{})},body:body===undefined?undefined:JSON.stringify(body)});
  return {status:response.status,headers:response.headers,value:response.headers.get('content-type')?.includes('json')?await response.json() as any:await response.text()};
}
const email='local-login-'+crypto.randomUUID()+'@example.test', password='QA-'+crypto.randomUUID();
assert.equal((await send('/workspace/')).status,303);
const registered=await send('/api/auth/sign-up/email',{email,password,name:'Local auth flow'});
assert.equal(registered.status,200);
let cookie=registered.headers.getSetCookie().map(c=>c.split(';')[0]).join('; ');
// Reproduce more session reads than the previously failing 20-per-minute limit.
for(let i=0;i<25;i++) assert.equal((await send('/api/auth/get-session',undefined,cookie)).status,200);
assert.equal((await send('/workspace/',undefined,cookie)).status,200);
assert.equal((await send('/api/auth/sign-out',{},cookie)).status,200);
assert.equal((await send('/workspace/',undefined,cookie)).status,303);
assert.equal((await send('/api/auth/sign-in/email',{email,password:'incorrect-fixture-password'})).status,401);
const signed=await send('/api/auth/sign-in/email',{email,password});
assert.equal(signed.status,200);
cookie=signed.headers.getSetCookie().map(c=>c.split(';')[0]).join('; ');
assert.equal((await send('/workspace/',undefined,cookie)).status,200);
assert.equal((await send('/api/auth/sign-out',{},cookie)).status,200);
console.log(JSON.stringify({passed:true,target:new URL(base).host,requests,checks:['server-gate','25-session-reads','logout','wrong-password','password-login','protected-workspace']}));
