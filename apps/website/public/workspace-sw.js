const CACHE='ravil-workspace-shell-v2';
self.addEventListener('install',event=>{event.waitUntil(self.skipWaiting());});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('ravil-workspace-shell-')&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()));});
self.addEventListener('push',event=>{let data={};try{data=event.data?.json()||{};}catch{}event.waitUntil(self.registration.showNotification(String(data.title||'RAVIL').slice(0,80),{body:String(data.body||'과목별 정리와 백업을 확인해 주세요.').slice(0,300),icon:'/workspace-icon-256.png',tag:'ravil-backup',data:{url:'/workspace/'}}));});
self.addEventListener('notificationclick',event=>{event.notification.close();event.waitUntil(clients.openWindow('/workspace/'));});
self.addEventListener('fetch',event=>{
  const url=new URL(event.request.url);
  if(event.request.method!=='GET'||url.origin!==self.location.origin||url.pathname.startsWith('/api/'))return;
  if(event.request.mode==='navigate'){
    event.respondWith(fetch(event.request).catch(()=>new Response('<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>로그인 확인 · RAVIL</title><body><p>작업 공간을 열려면 로그인 확인이 필요해요. 연결이 돌아오면 다시 열어 주세요.</p></body></html>',{status:503,headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'}})));
  }else if(url.pathname.startsWith('/_astro/')){
    event.respondWith(fetch(event.request).then(response=>{if(response.ok&&!response.redirected&&!/no-store/i.test(response.headers.get('cache-control')||'')){const copy=response.clone();void caches.open(CACHE).then(cache=>cache.put(event.request,copy));}return response;}).catch(()=>caches.match(event.request).then(cached=>cached||new Response('아직 저장되지 않은 화면입니다.',{status:503}))));
  }
});
