export class ExportDeliveryError extends Error {
  status:number;
  constructor(status:number,message:string){super(message);this.status=status;}
}
export interface ExportRow {owner:string;id:string;name:string;mime:string;size:number;expires_at:string}
const limit=64*1024*1024;
const allowed=new Set(['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/zip','text/markdown']);
const key=(owner:string,id:string)=>'temporary-exports/'+owner+'/'+id;
export async function noteExportRoute(request:Request,db:D1Database,files:R2Bucket,owner:string,id:string,now=new Date()):Promise<Response>{
  if(!/^[a-f0-9-]{36}$/i.test(id))throw new ExportDeliveryError(400,'파일 주소를 확인해 주세요.');
  const row=await db.prepare('SELECT * FROM workspace_exports WHERE owner=? AND id=?').bind(owner,id).first<ExportRow>();
  if(request.method==='PUT'){
    if(row)throw new ExportDeliveryError(409,'새 출력 파일을 만들어 주세요.');
    const size=Number(request.headers.get('Content-Length'));
    if(!Number.isSafeInteger(size)||size<1)throw new ExportDeliveryError(411,'파일 크기를 확인하지 못했습니다.');
    if(size>limit)throw new ExportDeliveryError(413,'출력 파일은 64MB까지 받을 수 있어요.');
    const mime=(request.headers.get('Content-Type')||'').split(';')[0].trim();
    if(!allowed.has(mime))throw new ExportDeliveryError(400,'출력 형식을 확인해 주세요.');
    let name:string;try{name=decodeURIComponent(request.headers.get('X-Export-Name')||'RAVIL').replace(/[\r\n\0]/g,'').slice(0,200);}catch{throw new ExportDeliveryError(400,'파일 이름을 확인해 주세요.');}
    const expires=new Date(now.getTime()+3600000).toISOString();
    // Reserve the identifier before writing so concurrent retries cannot replace another output.
    await db.prepare('INSERT INTO workspace_exports(owner,id,name,mime,size,expires_at) VALUES (?,?,?,?,?,?)').bind(owner,id,name,mime,size,expires).run();
    // The original request stream retains its known Content-Length for R2.
    try{const object=await files.put(key(owner,id),request.body,{httpMetadata:{contentType:mime}});if(!object||object.size!==size)throw new ExportDeliveryError(400,'출력 파일을 전송하지 못했습니다.');}
    catch(error){await files.delete(key(owner,id));await db.prepare('DELETE FROM workspace_exports WHERE owner=? AND id=?').bind(owner,id).run();throw error;}
    return Response.json({url:'/api/exports/'+id,expiresAt:expires},{headers:{'Cache-Control':'no-store'}});
  }
  if(!row)throw new ExportDeliveryError(404,'출력 파일을 찾지 못했습니다.');
  if(row.expires_at<=now.toISOString())throw new ExportDeliveryError(410,'링크가 만료됐어요. 다시 내보내 주세요.');
  const headers={'Content-Type':row.mime,'Content-Length':String(row.size),'Content-Disposition':"attachment; filename*=UTF-8''"+encodeURIComponent(row.name),'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'};
  if(request.method==='HEAD')return new Response(null,{headers});
  const object=await files.get(key(owner,id));if(!object)throw new ExportDeliveryError(404,'출력 파일을 찾지 못했습니다.');
  return new Response(object.body,{headers});
}
export async function cleanupNoteExports(db:D1Database,files:R2Bucket,now=new Date()){
  const rows=await db.prepare('SELECT * FROM workspace_exports WHERE expires_at<=? ORDER BY expires_at LIMIT 100').bind(now.toISOString()).all<ExportRow>();
  for(const row of rows.results){await files.delete(key(row.owner,row.id));await db.prepare('DELETE FROM workspace_exports WHERE owner=? AND id=?').bind(row.owner,row.id).run();}
}
