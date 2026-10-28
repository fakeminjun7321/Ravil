import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parsePlan,examplePlan,taskID,scheduleTasks,searchRecords,personalContext,type Entity} from '../../website/src/workspace/domain.ts';
const reference=new Date('2026-10-04T00:00:00Z');
const entity=(kind:Entity['kind'],payload:Record<string,any>,id=crypto.randomUUID()):Entity=>({kind,payload,id,revision:1,deleted:false,updatedAt:'2026-10-04T00:00:00Z'});
test('original mixed inline/multiline exam plan preserves every action, date and repetition',()=>{
  const result=parsePlan(examplePlan,reference);
  assert.equal(result.tasks.length,22);assert.equal(result.warnings.length,0);
  assert.equal(result.tasks.filter(t=>t.day==='2026-10-14').length,12);
  assert.equal(result.tasks.filter(t=>t.day==='2026-10-15').length,10);
  assert.equal(result.tasks.reduce((n,t)=>n+t.repetitions,0),25);
  assert.equal(result.tasks.find(t=>t.topic==='기하광학'&&t.action==='학습지 재정독'&&t.day==='2026-10-14')?.repetitions,2);
  assert.equal(result.tasks.find(t=>t.topic==='파동광학'&&t.action==='학습지 재정독'&&t.day==='2026-10-14')?.repetitions,3);
  assert.ok(result.tasks.some(t=>t.topic==='축전기 & 전기회로'&&t.action==='백지 공부'));
});
test('invalid calendar dates are reported without silently normalizing',()=>{
  const result=parsePlan('2026-02-30\n광학\n(1) 문제 풀기',reference);assert.equal(result.tasks[0].day,'');assert.equal(result.warnings.length,1);
});
test('task identity survives reformatting and changing repetitions',async()=>{
  const one=parsePlan('10.14\n광학 (1) 학습지 정독 2회',reference).tasks[0];
  const two=parsePlan('10.14\n광학\n(1) 학습지 정독 3회',reference).tasks[0];
  assert.equal(await taskID('record-id',one),await taskID('record-id',two));
});
test('scheduling preserves the date and never overlaps a busy event',()=>{
  const task=entity('task',{day:'2026-10-14',topic:'광학',action:'정독',repetitions:3,completed:1,minutes:30});
  const result=scheduleTasks([task],19,22,5,[{start:'2026-10-14T19:00:00+09:00',end:'2026-10-14T20:00:00+09:00'}],reference);
  assert.equal(result.blocks.length,2);assert.ok(result.blocks.every(b=>Date.parse(b.start)>=Date.parse('2026-10-14T20:00:00+09:00')));assert.equal(result.blocks[0].repetition,2);
});
test('insufficient time remains unplaced rather than shifting to another day',()=>{
  const task=entity('task',{day:'2026-10-14',action:'공부',repetitions:3,completed:0,minutes:60});
  const result=scheduleTasks([task],19,20,5,[],reference);assert.equal(result.blocks.length,1);assert.equal(result.unplaced.length,2);
});
test('search combines subject connections with original text',()=>{
  const subject=entity('subject',{title:'물리'});const record=entity('record',{title:'시험',body:'파동광학 틀린 문제 재점검',tags:[],subjectIDs:[subject.id]});
  assert.equal(searchRecords([subject,record],'전에 적은 물리 파동광학')[0].id,record.id);
});
test('behavior estimates remain evidence-linked and require repeated observations',()=>{
  const events=[20,40,30].map(minutes=>entity('observation',{event:'study',action:'학습지 정독',minutes}));
  const context=personalContext(events);assert.equal(context.estimates[0].minutes,30);assert.equal(context.estimates[0].status,'추정');assert.equal(context.estimates[0].evidenceIDs.length,3);
});
