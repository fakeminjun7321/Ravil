import test from 'node:test';
import assert from 'node:assert/strict';
import 'fake-indexeddb/auto';
import {analysisDigest, buildAnalysisContext, getRecordAnalysis, normalizeAnalysis} from '../src/workspace/second-brain';

const storage=new Map<string,string>();
Object.defineProperty(globalThis,'localStorage',{value:{getItem:(key:string)=>storage.get(key)||null,setItem:(key:string,value:string)=>storage.set(key,value),removeItem:(key:string)=>storage.delete(key)}});
const {WorkspaceStore}=await import('../src/workspace/store');
const deferred=<T,>()=>{let resolve!:(value:T)=>void;const promise=new Promise<T>(r=>{resolve=r;});return {promise,resolve};};
const payload=(body:string)=>({title:'과목 노트',body,format:'markdown',kind:'note',subjectIDs:[],projectIDs:[],fileIDs:[]});

test('a note changed during sync keeps its content and uses the acknowledged revision',async()=>{
 const store=new WorkspaceStore();store.owner='sync-qa-1';store.user={id:store.owner};store.online=true;
 const id=crypto.randomUUID();await store.put('record',payload('첫 문장'),id);
 const started=deferred<void>(),reply=deferred<any>();let remote:any;const sent:any[]=[];let editorRevision=0;
 store.addEventListener('acknowledged',event=>{const detail=(event as CustomEvent).detail;if(editorRevision===detail.sourceRevision)editorRevision=detail.revision;});
 store.api=async(path,body)=>{
  if(path==='sync'){
   const change=structuredClone(body.changes[0]);sent.push(change);
   if(sent.length===1){started.resolve();const value=await reply.promise;remote=value.results[0].entity;return value;}
   remote={...change,revision:change.revision+1};return {results:[{id,applied:true,entity:remote}]};
  }
  return {entities:remote?[remote]:[]};
 };
 const first=store.sync();await started.promise;const overlapping=store.sync();
 await store.put('record',payload('첫 문장\n\n$$E=CV^2/2$$\n\n![원본](/api/files/11111111-1111-1111-1111-111111111111)'),id,false,editorRevision);
 reply.resolve({results:[{id,applied:true,entity:{...sent[0],revision:1}}]});
 await Promise.all([first,overlapping]);
 assert.equal(sent.length,2);assert.equal(sent[1].revision,1);
 assert.ok(store.get(id)?.payload.body.includes('![원본]'));assert.ok(store.get(id)?.payload.body.includes('E=CV^2/2'));
 assert.equal(store.get(id)?.pending,false);assert.equal(store.get(id)?.conflict,undefined);assert.equal(editorRevision,2);
});

test('a real remote revision conflict keeps the local note and the remote alternative',async()=>{
 const store=new WorkspaceStore();store.owner='sync-qa-2';store.user={id:store.owner};store.online=true;
 const id=crypto.randomUUID();const local=await store.put('record',payload('내 수정'),id);
 const remote={...local,payload:payload('다른 기기의 수정'),revision:2};let acknowledgements=0;
 store.addEventListener('acknowledged',()=>acknowledgements++);
 store.api=async path=>path==='sync'?{results:[{id,applied:false,entity:remote}]}:{entities:[remote]};
 await store.sync();
 assert.equal(store.get(id)?.payload.body,'내 수정');assert.equal(store.get(id)?.conflict?.payload.body,'다른 기기의 수정');assert.equal(acknowledgements,0);
});

test('AI analysis survives IndexedDB reopening without replacing user text or manual tags',async()=>{
 const store=new WorkspaceStore();store.owner='analysis-qa-1';
 const source=await store.put('record',{...payload('직접 쓴 사진집 아이디어'),tags:['내가 단 태그']});
 const result={...normalizeAnalysis({summary:'인쇄·제본 검토',tags:['출판'],suggestions:[{text:'견적 비교',evidenceIDs:[source.id]}]},buildAnalysisContext([source],source),await analysisDigest(source)),ownerID:store.owner};
 await store.saveAnalysis(source,result);
 const reopened=new WorkspaceStore();reopened.api=async()=>({user:{id:store.owner}});reopened.sync=async()=>{};
 await reopened.signIn('fixture@example.test','synthetic-password');
 const saved=reopened.get(source.id)!;
 assert.equal(saved.payload.body,source.payload.body);assert.deepEqual(saved.payload.tags,['내가 단 태그']);
 assert.equal(getRecordAnalysis(saved.payload)?.summary,'인쇄·제본 검토');assert.deepEqual(getRecordAnalysis(saved.payload)?.tags,['출판']);
});

test('editing a note keeps the previous AI result marked stale and the manual tags intact',async()=>{
 const store=new WorkspaceStore();store.owner='analysis-qa-2';
 const source=await store.put('record',{...payload('이전 생각'),tags:['내 태그']});
 const result=normalizeAnalysis({summary:'이전 요약'},buildAnalysisContext([source],source),await analysisDigest(source));
 await store.saveAnalysis(source,result);
 await store.put('record',{...store.get(source.id)!.payload,body:'바뀐 생각'},source.id);
 assert.equal(store.get(source.id)!.payload.aiAnalysis.stale,true);
 assert.equal(store.get(source.id)!.payload.aiAnalysis.summary,'이전 요약');assert.equal(store.get(source.id)!.payload.summary,'');
 assert.deepEqual(store.get(source.id)!.payload.tags,['내 태그']);assert.equal(getRecordAnalysis(store.get(source.id)!.payload),undefined);
 await assert.rejects(store.saveAnalysis(source,result),/원문이나 연결/);
 assert.equal(store.get(source.id)!.payload.body,'바뀐 생각');
});

test('analysis saving preserves newer manual metadata and rejects another account result',async()=>{
 const store=new WorkspaceStore();store.owner='analysis-qa-3';
 const source=await store.put('record',{...payload('인쇄 견적 확인'),tags:['처음 태그']});
 const result=normalizeAnalysis({summary:'사진집 계획'},buildAnalysisContext([source],source),await analysisDigest(source));
 await store.put('record',{...source.payload,tags:['새 수동 태그']},source.id);
 await store.saveAnalysis(source,result);assert.deepEqual(store.get(source.id)!.payload.tags,['새 수동 태그']);
 await assert.rejects(store.saveAnalysis(source,{...result,ownerID:'another-owner'}),/원문이나 연결/);
 await store.put('record',{...store.get(source.id)!.payload,projectIDs:['new-scope']},source.id);
 await assert.rejects(store.saveAnalysis(source,result),/원문이나 연결/);
});

test('an older AI response contract cannot replace the current note or manual tags',async()=>{
 const store=new WorkspaceStore();store.owner='analysis-compatibility';
 const source=await store.put('record',{...payload('내 원문'),tags:['직접 입력']});
 await assert.rejects(store.saveAnalysis(source,{summary:'이전 응답',tags:['AI 태그']} as any),/업데이트/);
 assert.equal(store.get(source.id)!.payload.body,'내 원문');assert.deepEqual(store.get(source.id)!.payload.tags,['직접 입력']);
 assert.equal(store.get(source.id)!.payload.aiAnalysis,undefined);
});
