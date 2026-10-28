import test from 'node:test';
import assert from 'node:assert/strict';
import {calendarFile} from '../src/workspace/calendar-export.ts';
import {scheduleTasks,type Entity} from '../src/workspace/domain.ts';

test('downloaded calendars contain physical CRLF lines, UTC times and escaped Korean titles',()=>{
  const title='렌즈 실험, 복습; '+'긴 한글 제목 '.repeat(15)+'\\자료\n다음 줄';
  const body=calendarFile([{id:'task:1',taskID:'task',title,start:'2026-10-18T19:00:00+09:00',end:'2026-10-18T19:30:00+09:00',repetition:1}],new Date('2026-10-17T00:00:00Z'));
  const lines=body.split('\r\n');assert.equal(lines[0],'BEGIN:VCALENDAR');assert.equal(lines.at(-2),'END:VCALENDAR');
  assert.ok(lines.every(line=>new TextEncoder().encode(line).length<=75));
  const unfolded=body.replace(/\r\n /g,'');
  assert.ok(unfolded.includes('DTSTART:20261018T100000Z\r\n'));
  assert.ok(unfolded.includes('SUMMARY:렌즈 실험\\, 복습\\; '));
  assert.ok(unfolded.includes('\\\\자료\\n다음 줄\r\n'));
  assert.equal(unfolded.match(/BEGIN:VEVENT/g)?.length,1);
});

test('scheduling and calendar output preserve authored order even after one task was edited later',()=>{
  const task=(id:string,planOrder:number,repetitions=1):Entity=>({id,kind:'task',revision:1,deleted:false,updatedAt:id==='first'?'2026-10-17T12:00:00Z':'2026-10-17T00:00:00Z',payload:{day:'2026-10-18',recordID:'note',planOrder,action:id,completed:0,repetitions,minutes:30}});
  const result=scheduleTasks([task('second',1),task('first',0,2)],19,23,5,[],new Date('2026-10-17T00:00:00Z'));
  assert.deepEqual(result.blocks.map(b=>b.taskID),['first','first','second']);
  assert.equal(result.blocks[1].start,'2026-10-18T10:35:00.000Z');
  assert.equal(result.blocks[2].start,'2026-10-18T11:10:00.000Z');
});
