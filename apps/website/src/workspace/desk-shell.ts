import {icon} from './icons.ts';
import {active,type Entity} from './domain.ts';
import {choosePlanningDay,planningDayLabel,planningDays,projectSubjects,scopedTasks,matchingDeskCommands,scopedRecords} from './desk-model.ts';

const h=(value:unknown)=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
export interface DeskState {
  entities:Entity[];view:string;projectID:string;subjectID:string;recordID:string;status:string;query:string;
  day:string;command:string;busy:boolean;projectsOpen:boolean;planOpen:boolean;collapsed:Set<string>;
}
const action=(name:string,label:string,glyph:string,extra='')=>'<button type="button" class="desk-icon" data-action="'+name+'" aria-label="'+h(label)+'" title="'+h(label)+'" '+extra+'>'+icon(glyph)+'</button>';

export function deskRail(state:DeskState):string{
  return '<nav class="desk-rail" aria-label="작업 탐색"><button type="button" data-action="home" class="desk-brand" aria-label="RAVIL 홈"><img src="/art/r-sculpture-v1.webp" width="44" height="50" alt="RAVIL" /></button><div class="desk-rail-main">'+
    action('workspaceHome','내 작업','home')+action('search','기록 검색','search')+action('allRecords','내 기록','file')+
    '<button type="button" class="desk-icon '+(state.view==='plan'?'current':'')+'" data-view="plan" aria-label="계획" title="계획">'+icon('calendar')+'</button>'+action('toggleProjects','프로젝트 열기','folder','data-mobile-only')+
    '</div><div class="desk-rail-foot"><button class="desk-icon" data-view="profile" aria-label="나에 대해" title="나에 대해">'+icon('sparkle')+'</button><button class="desk-icon" data-view="account" aria-label="계정 · 동기화" title="계정 · 동기화">'+icon('user')+'</button></div></nav>';
}

export function deskProjects(state:DeskState):string{
  const projects=active(state.entities,'project').filter(project=>project.payload.phase!=='archived');
  const allSubjects=active(state.entities,'subject');
  const rows=projects.map(project=>{
    const selected=project.id===state.projectID;
    const expanded=selected&&!state.collapsed.has(project.id);
    const subjects=projectSubjects(state.entities,project.id);
    return '<section class="desk-project '+(selected?'selected':'')+'"><div class="desk-project-row"><button data-project="'+h(project.id)+'" class="desk-project-name" '+(selected?'aria-current="true"':'')+'>'+icon('folder')+'<span>'+h(project.payload.title)+'</span></button><button class="desk-tree-toggle" data-project-toggle="'+h(project.id)+'" aria-label="'+h(project.payload.title)+' '+(expanded?'접기':'펼치기')+'" aria-expanded="'+expanded+'">'+icon(expanded?'down':'right')+'</button></div>'+
      (expanded?'<div class="desk-project-subjects">'+subjects.map(subject=>'<button data-subject="'+h(subject.id)+'" data-with-project="'+h(project.id)+'" class="desk-subject '+(state.subjectID===subject.id?'current':'')+'" '+(state.subjectID===subject.id?'aria-current="true"':'')+'>'+icon('file')+'<span>'+h(subject.payload.title)+'</span></button>').join('')+
      (!subjects.length?'<button class="desk-empty-link" data-action="newSubject">'+icon('plus')+'주제 추가</button>':'')+'</div>':'')+'</section>';
  }).join('');
  const records=scopedRecords(state.entities,state).slice(0,8);
  const nav=(view:string,label:string,glyph:string)=>'<button data-view="'+view+'" class="studio-nav '+(state.view===view?'current':'')+'">'+icon(glyph)+'<span>'+label+'</span></button>';
  return '<aside class="sidebar desk-project-browser '+(state.projectsOpen?'open':'')+'" aria-label="내 기록 탐색"><div class="studio-brand-row"><button class="studio-brand" data-action="home" aria-label="RAVIL 홈">RAVIL</button>'+action('newRecord','새 기록','plus')+action('toggleProjects','탐색 닫기','close','data-mobile-only')+'</div>'+
    '<button class="studio-search" data-action="search">'+icon('search')+'<span>기록 찾기</span><kbd>⌘ K</kbd></button><nav class="studio-primary" aria-label="내 공간"><button class="studio-nav '+(state.view==='editor'?'current':'')+'" data-action="workspaceHome">'+icon('home')+'<span>내 작업</span></button><button class="studio-nav '+(state.view==='records'?'current':'')+'" data-action="allRecords">'+icon('file')+'<span>전체 기록</span></button>'+nav('plan','계획','calendar')+'</nav>'+
    '<div class="desk-project-tree"><div class="studio-group-heading"><h2>프로젝트</h2>'+action('newProject','프로젝트 추가','plus')+'</div>'+rows+
    (!projects.length?'<button class="desk-empty-link" data-action="newProject">프로젝트 만들기</button>':'')+
    '<details class="desk-all-subjects" '+(!state.projectID?'open':'')+'><summary>'+icon('folder')+'<span>주제별 기록</span>'+icon('down')+'</summary>'+allSubjects.map(subject=>'<button class="desk-subject '+(state.subjectID===subject.id?'current':'')+'" data-subject="'+h(subject.id)+'">'+icon('file')+'<span>'+h(subject.payload.title)+'</span></button>').join('')+'<button class="desk-empty-link" data-action="newSubject">'+icon('plus')+'주제 추가</button></details>'+
    '<div class="studio-group-heading studio-recents-heading"><h2>최근 기록</h2></div><nav class="studio-recents" aria-label="최근 기록">'+records.map(record=>'<button class="studio-recent '+(record.id===state.recordID?'current':'')+'" data-record="'+h(record.id)+'" '+(record.id===state.recordID?'aria-current="true"':'')+'>'+icon('file')+'<span>'+h(record.payload.title||'제목 없는 기록')+'</span></button>').join('')+(!records.length?'<p class="desk-list-empty">남긴 기록이 여기에 모여요.</p>':'')+'</nav></div>'+
    '<div class="desk-project-foot">'+nav('projects','프로젝트와 백업','folder')+nav('profile','나에 대해','sparkle')+nav('account','계정 · 동기화','user')+'<p id="sync-status" role="status"><span class="studio-sync-dot" aria-hidden="true"></span>'+h(state.status)+'</p></div></aside>';
}

export function deskHeader(state:DeskState):string{
  const project=state.entities.find(entity=>entity.id===state.projectID);
  const subject=state.entities.find(entity=>entity.id===state.subjectID);
  const breadcrumb=[project?.payload.title,subject?.payload.title].filter(Boolean).join(' / ')||'내 기록';
  const tabs=[['editor','노트'],['files','자료'],['plan','계획']];
  return '<header class="desk-work-head"><div class="desk-contextbar">'+action('toggleProjects','기록 탐색 열기','menu','data-mobile-only')+'<span class="breadcrumb">'+icon('file')+h(breadcrumb)+'</span><div class="desk-header-actions">'+action('newRecord','새 기록','plus')+action('contextNote','주제 · 프로젝트 연결','link')+action('exportNote','PDF · Word 내보내기','share')+'<details class="note-overflow"><summary aria-label="작업 메뉴" title="작업 메뉴">'+icon('more')+'</summary><div class="note-overflow-menu"><button data-action="organize">'+icon('calendar')+'<span>계획으로 정리</span></button><button data-action="analyze">'+icon('sparkle')+'<span>AI로 정리</span></button><button data-action="sourceMode">'+icon('code')+'<span>원문 / 편집 전환</span></button><button data-action="importNote">'+icon('upload')+'<span>텍스트 노트 가져오기</span></button><button data-action="save">'+icon('save')+'<span>저장</span></button></div></details>'+action('togglePlan',state.view==='plan'?'날짜별 계획 열기':'AI 맥락 열기',state.view==='plan'?'calendar':'sparkle','data-mobile-context')+'</div></div><nav class="desk-work-tabs" aria-label="현재 공간">'+tabs.map(([view,label])=>'<button data-view="'+view+'" class="'+(state.view===view?'current':'')+'" '+(state.view===view?'aria-current="page"':'')+'>'+label+'</button>').join('')+'</nav></header>';
}

export function deskNoteList(state:DeskState):string{
  const records=scopedRecords(state.entities,state);
  return '<nav class="desk-note-list" aria-label="현재 공간의 노트">'+records.map(record=>'<button class="desk-note-link '+(record.id===state.recordID?'current':'')+'" data-record="'+h(record.id)+'" '+(record.id===state.recordID?'aria-current="true"':'')+'>'+h(record.payload.title||'제목 없는 노트')+'</button>').join('')+
    (!records.length?'<p class="desk-list-empty">아직 기록이 없습니다.</p>':'')+'<button class="desk-new-note" data-action="newRecord" aria-label="새 기록">'+icon('plus')+'<span>새 기록</span></button></nav>';
}

export function deskPlan(state:DeskState):string{
  const tasks=scopedTasks(state.entities,state);
  const day=choosePlanningDay(tasks,state.day);
  const days=planningDays(tasks);
  if(!days.includes(day))days.push(day);
  const todayTasks=tasks.filter(task=>String(task.payload.day||'')===day);
  const subject=state.entities.find(entity=>entity.id===state.subjectID);
  return '<aside class="desk-plan-panel '+(state.planOpen?'open':'')+'" aria-label="선택한 공간의 계획"><header><div class="desk-plan-date"><h2>'+h(planningDayLabel(day))+'</h2>'+icon('calendar')+'<select id="plan-day" aria-label="계획 날짜">'+days.map(value=>'<option value="'+h(value)+'" '+(value===day?'selected':'')+'>'+h(planningDayLabel(value))+'</option>').join('')+'</select></div><p>'+h(subject?.payload.title||'내 계획')+'</p>'+action('togglePlan','계획 패널 닫기','close','data-mobile-only')+'</header><div class="desk-plan-content">'+todayTasks.map(task=>{
    const done=task.payload.completed>=task.payload.repetitions;
    const text=task.payload.action+(task.payload.repetitions>1?' '+task.payload.repetitions+'회':'');
    return '<label class="desk-plan-task '+(done?'done':'')+'"><input type="checkbox" data-plan-complete="'+h(task.id)+'" '+(done?'checked':'')+' aria-label="'+h(text)+' '+(done?'완료 취소':'1회 완료')+'" /><span>'+h(text)+(task.payload.completed>0&&task.payload.repetitions>1?'<small>'+task.payload.completed+'/'+task.payload.repetitions+'</small>':'')+'</span></label>';
  }).join('')+(!todayTasks.length?'<div class="desk-plan-empty"><p>날짜가 있는 계획을 남겨보세요.</p><button data-action="organize">'+icon('list')+'계획으로 정리</button></div>':'')+'</div><div class="desk-plan-actions"><button class="btn primary" data-action="calendarScope" '+(!todayTasks.some(task=>task.payload.completed<task.payload.repetitions&&task.payload.day)?'disabled':'')+'>'+icon('calendar')+'<span>캘린더에 배치</span></button><button class="desk-text-link" data-view="plan">시간 배치 보기</button></div></aside>';
}

export function commandOptions(value:string):string{
  if(!value.startsWith('/'))return '';
  const commands=matchingDeskCommands(value);
  return commands.map(command=>'<button type="button" role="option" data-desk-command="'+command.id+'">'+icon(command.glyph)+'<span>'+h(command.label)+'</span><kbd>/'+command.aliases[0]+'</kbd></button>').join('')||'<p>일치하는 명령이 없습니다.</p>';
}

export function deskCommand(state:DeskState):string{
  const project=state.entities.find(entity=>entity.id===state.projectID);
  return '<div class="desk-command-dock"><form id="desk-command-form" class="desk-command-form"><button type="button" class="desk-command-scope" data-action="commandScope" aria-label="명령의 프로젝트 선택">'+icon('folder')+'<span>'+h(project?.payload.title||'내 기록')+'</span>'+icon('down')+'</button><textarea id="desk-command" rows="1" aria-label="기록과 AI 명령" placeholder="기록을 남기거나 /정리 · /질문" '+(state.busy?'disabled':'')+'>'+h(state.command)+'</textarea><button type="button" class="desk-command-attach" data-action="noteAttach" aria-label="사진 · PDF 넣기" title="사진 · PDF 넣기">'+icon('attach')+'</button><button class="desk-command-send" type="submit" aria-label="명령 실행" '+(state.busy?'disabled':'')+'>'+icon('up')+'</button></form><div id="desk-command-options" class="desk-command-options" role="listbox" aria-label="기록과 AI 명령 목록" '+(!state.command.startsWith('/')?'hidden':'')+'>'+commandOptions(state.command)+'</div><p id="desk-command-status" class="sr-only" role="status">'+(state.busy?'작업 중':'')+'</p></div>';
}
