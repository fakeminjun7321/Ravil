import test from 'node:test';
import assert from 'node:assert/strict';
import {calendarTasks} from '../src/calendar-scope.ts';
import type {Entity} from '../../website/src/workspace/domain.ts';
const task=(id:string,completed=0,day='2026-10-18'):Entity=>({id,kind:'task',revision:1,deleted:false,updatedAt:'2026-10-17T00:00:00Z',payload:{completed,repetitions:1,day,recordID:'note-'+id,minutes:30,action:id}});
test('a project selection never schedules the rest of the workspace',()=>{const all=[task('one'),task('two')];assert.deepEqual(calendarTasks(all,['two']).map(t=>t.id),['two']);assert.deepEqual(calendarTasks(all,[]),[]);});
test('a selected calendar request retains the caller order without duplicates',()=>{assert.deepEqual(calendarTasks([task('one'),task('two')],['two','one','two']).map(t=>t.id),['two','one']);});
test('legacy full-workspace selection still excludes completed and undated work',()=>{assert.deepEqual(calendarTasks([task('active'),task('done',1),task('undated',0,'')]).map(t=>t.id),['active']);});
test('stale or foreign task IDs are rejected before any external calendar request',()=>{assert.throws(()=>calendarTasks([task('one')],['foreign']));assert.throws(()=>calendarTasks([task('one')],'one'));assert.throws(()=>calendarTasks([task('one')],new Array(101).fill('one')));});
