import {buildPushPayload,type PushSubscription} from '@block65/webcrypto-web-push';
import {digest} from '../../website/src/workspace/domain.ts';
import {HTTPError,json,type Env} from './worker.ts';
export async function notificationRoute(request:Request,env:Env,owner:string){
  const path=new URL(request.url).pathname;
  if(path==='/api/notifications/key')return json({publicKey:env.VAPID_PUBLIC_KEY||'',configured:!!env.VAPID_PRIVATE_KEY});
  if(path==='/api/notifications/subscribe'&&request.method==='POST'){
    const subscription:any=await request.json();
    let endpoint:URL;try{endpoint=new URL(subscription.endpoint);}catch{throw new HTTPError(400,'알림 연결 주소를 확인해 주세요.');}
    if(endpoint.protocol!=='https:'||endpoint.port||!['fcm.googleapis.com','updates.push.services.mozilla.com','push.services.mozilla.com','web.push.apple.com'].includes(endpoint.hostname)||typeof subscription.keys?.p256dh!=='string'||typeof subscription.keys?.auth!=='string'||JSON.stringify(subscription).length>10000)throw new HTTPError(400,'지원되는 브라우저 알림 연결이 아닙니다.');
    const id=await digest(subscription.endpoint);
    await env.DB.prepare('INSERT INTO workspace_push_subscriptions(owner,id,subscription,stopped) VALUES (?,?,?,0) ON CONFLICT(owner,id) DO UPDATE SET subscription=excluded.subscription,stopped=0').bind(owner,id,JSON.stringify(subscription)).run();
    return json({enabled:true});
  }
  if(path==='/api/notifications/unsubscribe'&&request.method==='POST'){
    const input:any=await request.json();const id=await digest(String(input.endpoint||''));
    await env.DB.prepare('DELETE FROM workspace_push_subscriptions WHERE owner=? AND id=?').bind(owner,id).run();return json({enabled:false});
  }
  throw new HTTPError(404,'알림 요청을 찾지 못했습니다.');
}
export async function sendBackupReminders(env:Env){
  if(!env.VAPID_PRIVATE_KEY||!env.VAPID_PUBLIC_KEY)return;
  const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  const result=await env.DB.prepare("SELECT s.owner,s.id,s.subscription FROM workspace_push_subscriptions s WHERE s.stopped=0 AND (s.last_sent_day IS NULL OR s.last_sent_day<>?) AND EXISTS(SELECT 1 FROM workspace_entities p WHERE p.owner=s.owner AND p.kind='project' AND p.deleted=0 AND json_extract(p.payload,'$.phase')<>'archived' AND length(json_extract(p.payload,'$.examDate'))=10 AND json_extract(p.payload,'$.examDate')<?) LIMIT 100").bind(today,today).all<{owner:string;id:string;subscription:string}>();
  for(const row of result.results){
    const subscription:PushSubscription=JSON.parse(row.subscription);
    const payload=await buildPushPayload({data:JSON.stringify({title:'RAVIL · 프로젝트 백업',body:'종료일이 지난 프로젝트가 있어요. 기록 정리와 백업을 확인해 주세요.',url:'/workspace/'}),options:{ttl:86400}},subscription,{subject:env.APP_ORIGIN,publicKey:env.VAPID_PUBLIC_KEY,privateKey:env.VAPID_PRIVATE_KEY});
    const response=await fetch(subscription.endpoint,payload);
    if(response.status===429||response.status===402){await env.DB.prepare('UPDATE workspace_push_subscriptions SET stopped=1 WHERE owner=? AND id=?').bind(row.owner,row.id).run();break;}
    if(response.status===404||response.status===410){await env.DB.prepare('DELETE FROM workspace_push_subscriptions WHERE owner=? AND id=?').bind(row.owner,row.id).run();}
    else if(response.ok)await env.DB.prepare('UPDATE workspace_push_subscriptions SET last_sent_day=? WHERE owner=? AND id=?').bind(today,row.owner,row.id).run();
  }
}
