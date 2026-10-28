import {active,type Entity} from '../../website/src/workspace/domain.ts';

// `all` is already restricted to the authenticated owner by the caller.
// An explicit empty selection must never turn into a full-workspace write.
export function calendarTasks(all:Entity[],ids?:unknown):Entity[]{
  const tasks=active(all,'task');
  let selected=tasks;
  if(ids!==undefined){
    if(!Array.isArray(ids)||ids.length>100||ids.some(id=>typeof id!=='string'||!/^[-a-zA-Z0-9]{1,80}$/.test(id)))throw new Error('선택한 할 일을 확인해 주세요.');
    const wanted=new Set(ids);
    if(ids.some(id=>!tasks.some(task=>task.id===id)))throw new Error('할 일 목록이 바뀌었습니다. 기록을 다시 열어 확인해 주세요.');
    selected=[...wanted].map(id=>tasks.find(task=>task.id===id)!);
  }
  return selected.filter(task=>task.payload.completed<task.payload.repetitions&&task.payload.day);
}
