import {active, type Entity} from './domain.ts';

export interface DeskScope {projectID:string;subjectID:string}

export function scopedRecords(entities:Entity[],scope:DeskScope):Entity[]{
  return active(entities,'record').filter(record =>
    (!scope.projectID || record.payload.projectIDs.includes(scope.projectID)) &&
    (!scope.subjectID || record.payload.subjectIDs.includes(scope.subjectID))
  ).sort((a,b)=>b.updatedAt.localeCompare(a.updatedAt));
}

export function scopedTasks(entities:Entity[],scope:DeskScope):Entity[]{
  const records=scopedRecords(entities,scope);
  const ids=new Set(records.map(record=>record.id));
  const recordOrder=new Map(records.map((record,index)=>[record.id,index]));
  return active(entities,'task').filter(task=>ids.has(task.payload.recordID))
    .sort((a,b)=>String(a.payload.day||'').localeCompare(String(b.payload.day||'')) ||
      (recordOrder.get(a.payload.recordID)!-recordOrder.get(b.payload.recordID)!) ||
      ((a.payload.planOrder??10000)-(b.payload.planOrder??10000)) || a.id.localeCompare(b.id));
}

export function projectSubjects(entities:Entity[],projectID:string):Entity[]{
  const records=scopedRecords(entities,{projectID,subjectID:''});
  const ids=new Set(records.flatMap(record=>record.payload.subjectIDs));
  return active(entities,'subject').filter(subject=>ids.has(subject.id)).sort((a,b)=>String(a.payload.title).localeCompare(String(b.payload.title),'ko'));
}

export function seoulDay(date=new Date()):string{
  return date.toLocaleDateString('sv-SE',{timeZone:'Asia/Seoul'});
}

export function validDay(day:string):boolean{
  return /^\d{4}-\d{2}-\d{2}$/.test(day) && !Number.isNaN(Date.parse(day+'T12:00:00+09:00')) &&
    new Date(day+'T12:00:00+09:00').toLocaleDateString('sv-SE',{timeZone:'Asia/Seoul'})===day;
}

export function planningDays(tasks:Entity[]):string[]{
  return [...new Set(tasks.map(task=>String(task.payload.day||'')))].filter(validDay).sort();
}

export function choosePlanningDay(tasks:Entity[],requested='',today=seoulDay()):string{
  const days=planningDays(tasks);
  if(days.includes(requested))return requested;
  if(days.length)return days.find(day=>day>=today)||days[0];
  if(tasks.length)return '';
  return seoulDay(new Date(Date.parse(today+'T12:00:00+09:00')+86400000));
}

export function planningDayLabel(day:string):string{
  if(!day)return '날짜 미정';
  const date=new Date(day+'T12:00:00+09:00');
  const weekday=date.toLocaleDateString('ko-KR',{timeZone:'Asia/Seoul',weekday:'long'});
  return Number(day.slice(5,7))+'.'+Number(day.slice(8,10))+' '+weekday;
}

export interface DeskCommand {id:string;label:string;glyph:string;aliases:string[];argument?:boolean}
export const deskCommands:DeskCommand[]=[
  {id:'new',label:'새 노트',glyph:'file',aliases:['노트','새노트','new']},
  {id:'find',label:'기록 찾기',glyph:'search',aliases:['찾기','검색','find','search'],argument:true},
  {id:'plan',label:'계획으로 정리',glyph:'calendar',aliases:['계획','할일','plan']},
  {id:'summary',label:'AI로 정리',glyph:'sparkle',aliases:['정리','요약','ai']},
  {id:'question',label:'기록에 질문',glyph:'sparkle',aliases:['질문','물어보기','ask'],argument:true},
  {id:'attach',label:'사진 · PDF 넣기',glyph:'attach',aliases:['자료','사진','pdf','파일']},
  {id:'export',label:'PDF · Word 내보내기',glyph:'download',aliases:['내보내기','출력','export']},
];

export function matchingDeskCommands(input:string):DeskCommand[]{
  const key=input.replace(/^\//,'').trim().toLocaleLowerCase().replace(/\s+/g,'');
  return deskCommands.filter(command=>[command.label,...command.aliases].some(value=>value.toLocaleLowerCase().replace(/\s+/g,'').includes(key)));
}

export function resolveDeskCommand(input:string):{id:string;text:string}|null{
  const value=input.trim();
  if(!value)return null;
  if(!value.startsWith('/'))return {id:'capture',text:value};
  const [name,...parts]=value.slice(1).trim().split(/\s+/);
  const command=deskCommands.find(command=>command.aliases.includes(name.toLocaleLowerCase()));
  return command?{id:command.id,text:parts.join(' ')}:{id:'unknown',text:name};
}
