import test from 'node:test';
import assert from 'node:assert/strict';
import {noteExportRoute,cleanupNoteExports,ExportDeliveryError,type ExportRow} from '../src/note-exports.ts';

function fixture(){
 const rows=new Map<string,ExportRow>(),objects=new Map<string,Uint8Array>(),deleted:string[]=[];
 const db={prepare(sql:string){return {bind(...args:any[]){return {
  first:async()=>rows.get(args[0]+'/'+args[1])||null,
  all:async()=>({results:[...rows.values()].filter(row=>row.expires_at<=args[0])}),
  run:async()=>{if(sql.startsWith('INSERT')){const [owner,id,name,mime,size,expires_at]=args;rows.set(owner+'/'+id,{owner,id,name,mime,size,expires_at});}else if(sql.startsWith('DELETE'))rows.delete(args[0]+'/'+args[1]);return {success:true};}
 };}};}} as unknown as D1Database;
 const files={put:async(key:string,stream:ReadableStream)=>{const bytes=new Uint8Array(await new Response(stream).arrayBuffer());objects.set(key,bytes);return {size:bytes.length};},get:async(key:string)=>objects.has(key)?{body:objects.get(key)}:null,delete:async(key:string)=>{deleted.push(key);objects.delete(key);}} as unknown as R2Bucket;
 return {db,files,rows,objects,deleted};
}
const id='11111111-1111-1111-1111-111111111111';
test('export delivery stores the byte stream and only lets its owner download it',async()=>{
 const f=fixture();const bytes=new Uint8Array([37,80,68,70,45]);
 const response=await noteExportRoute(new Request('https://ravil.test/api/exports/'+id,{method:'PUT',headers:{'Content-Length':String(bytes.length),'Content-Type':'application/pdf','X-Export-Name':encodeURIComponent('과목 노트.pdf')},body:bytes}),f.db,f.files,'owner-1',id,new Date('2026-10-05T10:00:00Z'));
 assert.equal((await response.json()).expiresAt,'2026-10-05T11:00:00.000Z');
 const downloaded=await noteExportRoute(new Request('https://ravil.test/api/exports/'+id),f.db,f.files,'owner-1',id,new Date('2026-10-05T10:01:00Z'));
 assert.deepEqual(new Uint8Array(await downloaded.arrayBuffer()),bytes);assert.ok(downloaded.headers.get('Content-Disposition')?.startsWith('attachment;'));assert.equal(downloaded.headers.get('Cache-Control'),'private, no-store');
 await assert.rejects(noteExportRoute(new Request('https://ravil.test/api/exports/'+id),f.db,f.files,'owner-2',id),error=>error instanceof ExportDeliveryError&&error.status===404);
});
test('an expired export cannot be downloaded',async()=>{
 const f=fixture();f.rows.set('owner-1/'+id,{owner:'owner-1',id,name:'note.pdf',mime:'application/pdf',size:4,expires_at:'2026-10-05T10:00:00Z'});
 await assert.rejects(noteExportRoute(new Request('https://ravil.test/api/exports/'+id),f.db,f.files,'owner-1',id,new Date('2026-10-05T10:01:00Z')),error=>error instanceof ExportDeliveryError&&error.status===410);
});
test('expiration cleanup only removes the separate generated-file namespace',async()=>{
 const f=fixture();f.rows.set('owner-1/'+id,{owner:'owner-1',id,name:'note.pdf',mime:'application/pdf',size:4,expires_at:'2026-10-05T10:00:00Z'});f.objects.set('owner-1/original-note-digest',new Uint8Array([1]));
 await cleanupNoteExports(f.db,f.files,new Date('2026-10-05T11:00:00Z'));
 assert.deepEqual(f.deleted,['temporary-exports/owner-1/'+id]);assert.ok(f.objects.has('owner-1/original-note-digest'));assert.equal(f.rows.size,0);
});
