import test from 'node:test';
import assert from 'node:assert/strict';
import type {Entity} from '../src/workspace/domain.ts';
import {parsePlan} from '../src/workspace/domain.ts';
import {scopedRecords,scopedTasks,projectSubjects,choosePlanningDay,planningDayLabel,seoulDay,resolveDeskCommand} from '../src/workspace/desk-model.ts';
const entity=(kind:Entity['kind'],id:string,payload:Record<string,any>,deleted=false):Entity=>({kind,id,payload,deleted,revision:1,updatedAt:'2026-10-13T00:00:00Z'});
const record=(id:string,projects:string[],subjects=['physics'],deleted=false)=>entity('record',id,{title:id,body:'',projectIDs:projects,subjectIDs:subjects,fileIDs:[]},deleted);
const task=(id:string,recordID:string,day='2026-10-14',planOrder=0)=>entity('task',id,{recordID,day,action:id,repetitions:2,completed:0,minutes:30,planOrder});

test('one canonical note can appear in two projects without mixing unrelated notes or tasks',()=>{
 const data=[record('shared',['p1','p2']),record('only-two',['p2']),record('removed',['p1'],['physics'],true),task('shared-task','shared'),task('other-task','only-two'),task('deleted-note-task','removed')];
 assert.deepEqual(scopedRecords(data,{projectID:'p1',subjectID:'physics'}).map(e=>e.id),['shared']);
 assert.deepEqual(scopedTasks(data,{projectID:'p1',subjectID:'physics'}).map(e=>e.id),['shared-task']);
 assert.equal(scopedRecords(data,{projectID:'p2',subjectID:''}).length,2);
 assert.deepEqual(data[0].payload.projectIDs,['p1','p2']);
});
test('project subjects come from active linked notes, and plan order preserves the authored sequence',()=>{
 const data=[record('r1',['p1']),record('r2',['p2'],['astronomy']),entity('subject','physics',{title:'물리'}),entity('subject','astronomy',{title:'천문'}),task('z-first','r1','2026-10-14',0),task('a-second','r1','2026-10-14',1)];
 assert.deepEqual(projectSubjects(data,'p1').map(e=>e.id),['physics']);
 assert.deepEqual(scopedTasks(data,{projectID:'p1',subjectID:''}).map(e=>e.id),['z-first','a-second']);
});
test('planning uses Seoul dates without silently moving old or undated tasks',()=>{
 assert.equal(seoulDay(new Date('2026-10-17T15:15:00Z')),'2026-10-18');
 assert.equal(choosePlanningDay([task('old','r','2026-10-14')],'','2026-10-17'),'2026-10-14');
 assert.equal(choosePlanningDay([task('undated','r','')],'','2026-10-17'),'');
 assert.equal(choosePlanningDay([],'','2026-10-17'),'2026-10-18');
 assert.equal(planningDayLabel('2026-10-14'),'10.14 수요일');
 assert.equal(planningDayLabel('2026-10-18'),'10.18 일요일');
});
test('slash commands keep search arguments and plain capture text separate',()=>{
 assert.deepEqual(resolveDeskCommand('/찾기 기하광학 노트'),{id:'find',text:'기하광학 노트'});
 assert.deepEqual(resolveDeskCommand('/계획'),{id:'plan',text:''});
 assert.deepEqual(resolveDeskCommand('/질문 사진집 다음 작업은?'),{id:'question',text:'사진집 다음 작업은?'});
 assert.deepEqual(resolveDeskCommand('10.14\n기하광학'),{id:'capture',text:'10.14\n기하광학'});
 assert.deepEqual(resolveDeskCommand('/없는명령'),{id:'unknown',text:'없는명령'});
 assert.equal(resolveDeskCommand('  '),null);
});
test('the date headings shown in the editor retain dates, checkbox actions and repetition counts',()=>{
 const parsed=parsePlan('## 10.14 공부할 것\n\n- [ ] 양기선 문제 풀기\n- [ ] 학습지 재정독 2회\n- [ ] 이론 백지 공부\n\n10.15 기하광학\n(1) 틀린 문제 재점검',new Date('2026-10-17T00:00:00+09:00'));
 assert.deepEqual(parsed.tasks.slice(0,3).map(t=>[t.action,t.day,t.repetitions]),[['양기선 문제 풀기','2026-10-14',1],['학습지 재정독','2026-10-14',2],['이론 백지 공부','2026-10-14',1]]);
 assert.equal(parsed.tasks[3].topic,'기하광학');
 assert.equal(parsed.tasks[3].day,'2026-10-15');
});
