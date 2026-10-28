import { WorkspaceStore, getRecordAnalysis } from './store.ts';
import {renderAnalysisPanel,type ContextTab} from './analysis-view.ts';
import {calendarFile} from './calendar-export.ts';
import {NoteEditor,noteToolbar} from './note-editor';
import {uploadNoteFile} from './note-files';
import {plainDocument,safeFileName,type NoteAttachment,type NoteSnapshot} from './note-format';
import katex from 'katex';
import {icon, actionIcons} from './icons.ts';
import { active, personalContext, scheduleTasks, searchRecords, type Entity, parsePlan, taskID } from './domain.ts';
import {scopedRecords,scopedTasks,choosePlanningDay,resolveDeskCommand,validDay} from './desk-model.ts';
import {deskProjects,deskHeader,deskPlan,deskCommand,commandOptions,type DeskState} from './desk-shell.ts';
const store = new WorkspaceStore();
const root = document.querySelector<HTMLDivElement>('#workspace')!;
const modal = document.querySelector<HTMLDialogElement>('#modal')!;
const modalBody = document.querySelector<HTMLDivElement>('#modal-body')!;
const h = (s: any) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
let view = 'editor', selectedRecordID = '', subjectID = '', projectID = '', query = '', draftID = crypto.randomUUID(), draftTitle = '', draftBody = '', draftFiles: string[] = [];
let editingRevision = 0, renderedOwner = '';
let planningDay='',commandDraft='',commandBusy=false,projectsOpen=false,planOpen=false;
let questionDraft='';
let contextTab:ContextTab='summary';
const collapsedProjects=new Set<string>();
let autoSave: ReturnType<typeof setTimeout> | undefined;
let draftSaveChain: Promise<Entity | undefined> = Promise.resolve(undefined);
let noteEditor:NoteEditor|undefined, sourceMode=false, draftFormat='markdown', draftKind='note';
let draftAttachments:NoteAttachment[]=[];let noteEditorKey='';let preservedSelection:{from:number;to:number}|undefined;let textComposing=false;
function currentBody(){return noteEditor?.body() ?? document.querySelector<HTMLTextAreaElement>('#body')?.value ?? draftBody;}
function scheduleNoteSave(){if(textComposing||noteEditor?.composing)return;clearTimeout(autoSave);autoSave=setTimeout(()=>void saveDraft().catch(e=>notify(e.message)),700);}
let backupReceipts = new Map<string, string>();
let study: {
    task: Entity;
    seconds: number;
    last: number;
} | undefined;
let lastInteraction = Date.now();
document.addEventListener('pointerdown', () => lastInteraction = Date.now());
document.addEventListener('keydown', () => lastInteraction = Date.now());
setInterval(() => { if (study) {
    const now = Date.now();
    if (document.visibilityState === 'visible' && document.hasFocus() && now - lastInteraction < 300000)
        study.seconds += (now - study.last) / 1000;
    study.last = now;
} }, 1000);
function notify(message: string) { const el = document.querySelector<HTMLDivElement>('#notice')!; el.textContent = message; el.style.display = 'block'; setTimeout(() => el.style.display = 'none', 6500); }
function button(label: string, action: string, extra = '', primary = false) { return '<button class="btn' + (primary ? ' primary' : '') + '" data-action="' + action + '" ' + extra + '>' + (actionIcons[action] ? icon(actionIcons[action]) : '') + '<span>' + h(label) + '</span></button>'; }
function record() { return store.get(selectedRecordID); }
function filteredRecords(){return scopedRecords(store.entities,{projectID,subjectID});}
function row(e: Entity) { const names = e.payload.subjectIDs.map((id: string) => store.get(id)?.payload.title || '').filter(Boolean).join(' · '); return '<button class="record-row" data-record="' + h(e.id) + '"><strong>' + h(e.payload.title || '제목 없는 기록') + '</strong><span class="meta">' + h((e.payload.kind === 'plan' ? '계획' : e.payload.kind === 'activity' ? '활동' : '노트') + (names ? ' · ' + names : '')) + ' · ' + h(e.updatedAt.slice(0, 10)) + '</span></button>'; }
function sidebar(){return deskProjects(deskState());}
function taskRow(e:Entity) {
    const p=e.payload,done=p.completed>=p.repetitions;
    return '<div class="task"><button class="complete'+(done?' done':'')+'" data-complete="'+h(e.id)+'" aria-label="'+h(p.action)+' '+(done?'완료 취소':'1회 완료')+'">'+(done?'✓':'')+'</button><div class="task-main"><strong>'+h((p.topic?p.topic+' · ':'')+p.action)+'</strong><span class="meta"><input class="task-date" type="date" data-task-day="'+h(e.id)+'" value="'+h(p.day||'')+'" aria-label="'+h(p.action)+' 날짜" /> · '+button('원문','source','data-id="'+h(p.recordID)+'"')+'</span></div><label class="tiny"><input class="duration" type="number" min="5" max="180" step="5" value="'+p.minutes+'" data-duration="'+h(e.id)+'" aria-label="예상 소요 시간" />분</label><span class="progress">'+p.completed+'/'+p.repetitions+'</span>'+button(study?.task.id===e.id?'작업 마침':'작업 시작','study','data-id="'+h(e.id)+'"')+'</div>';
}
function conflict(e: Entity) { if (!e.conflict)
    return ''; return '<div class="conflict"><strong>다른 기기에서도 수정한 기록입니다.</strong><p>내 수정과 다른 기기의 수정을 모두 확인하고 선택해 주세요.</p><pre>' + h(e.conflict.payload.body || JSON.stringify(e.conflict.payload)) + '</pre><div class="actions">' + button('다른 기기 수정 사용', 'remoteConflict', 'data-id="' + h(e.id) + '"') + button('내 수정도 별도 기록으로 남기기', 'copyConflict', 'data-id="' + h(e.id) + '"') + '</div></div>'; }

function insertMathDialog(){dialog('<h2>수식 넣기</h2><form><label>수식<input name="formula" id="note-formula" value="E=\\frac{1}{2}CV^2" required /></label><div class="row">'+['α','β','θ','π','Σ','∫','∞','√'].map(symbol=>'<button type="button" class="btn" data-math-symbol="'+symbol+'">'+symbol+'</button>').join('')+'</div><label>분수 분자<input id="math-num" /></label><label>분수 분모<input id="math-den" /></label><button type="button" class="btn" id="math-fraction">분수 넣기</button><label>표시<select name="display"><option value="block">따로 표시</option><option value="inline">문장 안에 표시</option></select></label><button type="submit" class="btn primary">수식 넣기</button></form>',async f=>{const latex=String(f.get('formula'));katex.renderToString(latex,{throwOnError:true,trust:false,maxExpand:1000});noteEditor?.math(latex,f.get('display')==='block');await saveDraft();await store.sync();});modalBody.querySelectorAll<HTMLButtonElement>('[data-math-symbol]').forEach(b=>b.addEventListener('click',()=>{const field=modalBody.querySelector<HTMLInputElement>('#note-formula')!;field.value+=b.dataset.mathSymbol;}));modalBody.querySelector('#math-fraction')?.addEventListener('click',()=>{const field=modalBody.querySelector<HTMLInputElement>('#note-formula')!;const num=modalBody.querySelector<HTMLInputElement>('#math-num')!.value,den=modalBody.querySelector<HTMLInputElement>('#math-den')!.value;field.value+='\\frac{'+num+'}{'+den+'}';});}
function importNoteFile(){const input=document.querySelector<HTMLInputElement>('#note-import-input')!;input.value='';input.accept='.md,.markdown,.txt,text/plain,text/markdown';input.onchange=async()=>{try{const file=input.files?.[0];if(!file)return;if(file.size>60000)throw new Error('텍스트 노트는 60KB 이내로 나눠 주세요.');await saveDraft();newRecord();draftTitle=file.name.replace(/\.(md|markdown|txt)$/i,'');draftBody=await file.text();draftFormat=/\.txt$/i.test(file.name)?'plain':'markdown';render();await saveDraft();await store.sync();}catch(e){notify((e as Error).message);}};input.click();}
async function runNoteCommand(action:string){if(action==='insertMath')insertMathDialog();else if(action==='noteAttach')pickNoteFiles();else if(action==='exportNote')await exportNoteDialog();else if(action==='importNote')importNoteFile();else if(action==='contextNote')contextNoteDialog();}
function contextNoteDialog(){
    const payload=record()?.payload;
    const choices=(kind:'subject'|'project',name:string,selected:string[])=>active(store.entities,kind).filter(e=>kind==='subject'||e.payload.phase!=='archived').map(e=>'<label><input type="checkbox" name="'+name+'" value="'+h(e.id)+'" '+(selected.includes(e.id)?'checked':'')+' /><span>'+h(e.payload.title)+'</span></label>').join('');
    dialog('<h2>노트 연결</h2><form><fieldset class="desk-context-options"><legend>주제</legend>'+choices('subject','subjects',payload?.subjectIDs||(subjectID?[subjectID]:[]))+'</fieldset><fieldset class="desk-context-options"><legend>프로젝트</legend>'+choices('project','projects',payload?.projectIDs||(projectID?[projectID]:[]))+'</fieldset><label>태그 · 쉼표로 구분<input name="tags" maxlength="1000" value="'+h((payload?.tags||[]).join(', '))+'" /></label><div class="row"><button type="button" class="btn" data-add-context="subject">주제 추가</button><button type="button" class="btn" data-add-context="project">프로젝트 추가</button></div><button type="submit" class="btn primary">적용</button></form>',async f=>{
        const saved=await saveDraft();
        const subjects=f.getAll('subjects').map(String),projects=f.getAll('projects').map(String);
        subjectID=subjects.includes(subjectID)?subjectID:subjects[0]||'';projectID=projects.includes(projectID)?projectID:projects[0]||'';
        const tags=[...new Set(String(f.get('tags')||'').split(',').map(tag=>tag.trim()).filter(Boolean))].slice(0,30);
        if(saved)await store.put('record',{...saved.payload,subjectIDs:subjects,projectIDs:projects,tags},saved.id,false,editingRevision);
        await store.sync();
    });
    modalBody.querySelectorAll<HTMLButtonElement>('[data-add-context]').forEach(button=>button.addEventListener('click',()=>{modal.close();createContext(button.dataset.addContext as 'subject'|'project');}));
}

function editor() {
    const e=record(),payload=e?.payload;editingRevision=e?.revision||0;
    const title=payload?.title??draftTitle,body=payload?.body??draftBody,kind=payload?.kind||draftKind;
    const files:NoteAttachment[]=payload?.attachments||draftAttachments;
    return '<div class="desk-editor-row"><main class="document note-document" id="editor">'+
      (sourceMode?'':noteToolbar())+'<div class="desk-note-heading"><input class="title-input" id="title" aria-label="기록 제목" placeholder="제목 없는 노트" value="'+h(title)+'" /><select id="record-kind" aria-label="기록 종류"><option value="memo" '+(kind==='memo'?'selected':'')+'>메모</option><option value="note" '+(kind==='note'?'selected':'')+'>노트</option><option value="plan" '+(kind==='plan'?'selected':'')+'>계획</option><option value="activity" '+(kind==='activity'?'selected':'')+'>활동</option></select></div>'+(payload?.tags?.length?'<p class="meta brain-manual-tags">'+payload.tags.map((tag:string)=>h('#'+tag)).join(' · ')+'</p>':'')+'<p class="sr-only" id="editor-status" aria-live="polite">'+h(store.status)+'</p>'+
      (sourceMode?'<textarea id="body" class="body-editor" aria-label="기록 본문">'+h(body)+'</textarea>':'<div id="body" class="note-editor-host"></div>')+
      (e?conflict(e):'')+'<div class="files">'+(payload?.fileIDs||draftFiles).filter((id:string)=>!files.find(f=>f.id===id)?.sourceId).map((id:string)=>'<a href="/api/files/'+h(id)+'" target="_blank" rel="noopener">'+icon('attach')+h(files.find(f=>f.id===id)?.name||'첨부파일')+'</a>').join('')+'</div>'+
      (payload?.parseWarnings?.length?'<p class="banner">'+h(payload.parseWarnings.join(' · '))+'</p>':'')+'</main></div>';
}
function filesView(){
    const files=new Map<string,{name:string;record:Entity;size?:number;mime?:string}>();
    for(const e of filteredRecords()){
      const attachments:NoteAttachment[]=e.payload.attachments||[];
      for(const id of e.payload.fileIDs){const attachment=attachments.find(file=>file.id===id);if(attachment?.sourceId)continue;files.set(id,{name:attachment?.name||'연결 파일',record:e,size:attachment?.size,mime:attachment?.mime});}
    }
    return '<main class="wide desk-files" id="editor"><div class="section-title"><h2>자료</h2>'+button('사진 · PDF 넣기','noteAttach','',true)+'</div><div class="desk-file-list">'+[...files].map(([id,file])=>'<article class="desk-file-row">'+icon(file.mime?.startsWith('image/')?'image':'file')+'<div><a href="/api/files/'+h(id)+'" target="_blank" rel="noopener">'+h(file.name)+'</a><p class="meta">'+h(file.record.payload.title)+(file.size?' · '+Math.ceil(file.size/1024)+'KB':'')+'</p></div><button class="desk-icon" data-record="'+h(file.record.id)+'" aria-label="'+h(file.record.payload.title)+' 노트 열기" title="노트 열기">'+icon('right')+'</button></article>').join('')+'</div>'+(!files.size?'<p class="empty">이 공간에 연결된 사진과 PDF가 여기에 모입니다.</p>':'')+'</main>';
}
function records() { return '<main class="wide" id="editor"><input id="search" aria-label="기록 검색" placeholder="기록 · 주제 · 프로젝트 검색" value="'+h(query)+'" /><h1>' + h(subjectID ? store.get(subjectID)?.payload.title : projectID ? store.get(projectID)?.payload.title : '내 기록') + '</h1><p class="meta">원본 하나를 여러 맥락에서 연결해서 봅니다.</p><div class="actions" style="margin-top:20px">' + button('새 기록', 'newRecord', '', true) + button('전체 기록', 'allRecords') + '</div>' + filteredRecords().map(row).join('') + (filteredRecords().length ? '' : '<p class="empty">아직 연결된 기록이 없습니다. 여기서 새 기록을 남기면 이 공간에 연결됩니다.</p>') + '</main>'; }
function plan() {
    const tasks = scopedTasks(store.entities,{projectID,subjectID});
    const settings = active(store.entities, 'preference').find(e => e.payload.key === 'planner')?.payload || {};
    const planned = scheduleTasks(tasks, settings.startHour ?? 19, settings.endHour ?? 23, settings.breakMinutes ?? 5);
    return '<main class="wide" id="editor"><h1>계획</h1><p class="meta">날짜와 반복 횟수를 유지하며 작업 가능한 시간에 배치합니다.</p><div class="preferences"><label>시작<input id="startHour" type="number" min="0" max="22" value="' + (settings.startHour ?? 19) + '" />시</label><label>끝<input id="endHour" type="number" min="1" max="24" value="' + (settings.endHour ?? 23) + '" />시</label><label>휴식<input id="breakMinutes" type="number" min="0" max="60" value="' + (settings.breakMinutes ?? 5) + '" />분</label>' + '<label><input id="autoCalendar" type="checkbox" '+(settings.autoCalendar?'checked':'')+' /> 계획 저장 시 캘린더 자동 배치</label>' + button('시간 기준 저장', 'plannerSettings') + '</div><div class="actions">' + button('Google Calendar에 배치', 'calendar', '', true) + button('일정 파일 받기', 'ics') + '</div><p class="tiny" style="margin-top:12px">Google 연결은 Mac 앱에서 한 번 설정하면 웹에서도 사용합니다. 예상 시간은 할 일마다 바꿀 수 있어요.</p><div class="section-title"><h2>남은 할 일</h2></div>' + tasks.map(taskRow).join('') + (tasks.length ? '' : '<p class="empty">기록을 작성하고 ‘계획으로 정리’를 눌러 시작하세요.</p>') + (planned.unplaced.length ? '<p class="banner">현재 시간 기준으로 ' + planned.unplaced.length + '개 작업을 배치하지 못했습니다. 날짜를 넘겨 임의로 옮기지 않았습니다.</p>' : '') + '<div class="section-title"><h2>시간 배치 미리보기</h2></div>' + planned.blocks.map(b => '<div class="profile-row"><strong>' + h(b.title) + '</strong><p class="meta">' + h(new Date(b.start).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })) + ' · ' + h(new Date(b.end).toLocaleTimeString('ko-KR', { timeZone: 'Asia/Seoul', hour: '2-digit', minute: '2-digit' })) + '</p></div>').join('') + '</main>';
}
function profile() { const p = personalContext(store.entities); return '<main class="wide" id="editor"><h1>나에 대해</h1><p class="meta">이 공간에 남긴 기록·작업·계획 변경과 정정을 모아 봅니다.</p><p class="info">현재 ' + p.observedActivities + '개의 활동 기록과 ' + p.completedTasks + '개의 완료한 할 일이 연결되어 있어요. 이 기록으로 성격이나 능력을 단정하지 않습니다.</p><div class="section-title"><h2>작업 시간에 대한 관찰</h2></div>' + p.estimates.map(e => '<div class="profile-row"><strong>' + h(e.action) + '</strong><p>' + e.minutes + '분 · ' + e.samples + '회 기록 · ' + e.status + '</p><div class="evidence">' + e.evidenceIDs.map(id => { const o = store.get(id); return '<button data-source="' + h(o?.payload.recordID || '') + '">근거 기록</button>'; }).join('') + '</div>' + button('정정하기', 'correction') + '</div>').join('') + (p.estimates.length ? '' : '<p class="empty">‘작업 시작 → 작업 마침’으로 실제 활동이 쌓이면 예상 시간에 반영할 수 있어요.</p>') + '<div class="section-title"><h2>내가 알려준 정정</h2>' + button('알려주기', 'correction') + '</div>' + p.corrections.map(e => '<div class="profile-row">' + h(e.text) + ' ' + button('잊기', 'forget', 'data-id="' + h(e.id) + '"') + '</div>').join('') + '</main>'; }
function projects() {
    const items=active(store.entities,'project'),activeProjects=items.filter(e=>e.payload.phase!=='archived'),archived=items.filter(e=>e.payload.phase==='archived');
    return '<main class="wide backups" id="editor"><h1>프로젝트와 백업</h1><p class="meta">기록을 모아 작업하고, 끝난 프로젝트는 백업을 확인한 뒤 보관합니다. 원본은 계속 남아 있어요.</p><div class="actions" style="margin-top:20px">'+button('프로젝트 추가','newProject','',true)+'</div>'+activeProjects.map(e=>{
        const records=active(store.entities,'record').filter(r=>r.payload.projectIDs.includes(e.id));
        return '<section class="profile-row"><h2 style="font-size:20px">'+h(e.payload.title)+'</h2><p class="meta">'+h(e.payload.examDate||'종료일 없이 진행')+' · 연결된 기록 '+records.length+'개</p><div class="actions">'+button('기록 보기','projectRecords','data-id="'+h(e.id)+'"')+button('백업 파일 받기','backup','data-id="'+h(e.id)+'"')+'</div><label>내려받은 백업 검사<input type="file" accept=".json" data-backup="'+h(e.id)+'" /></label>'+button('프로젝트 보관','finishProject','data-id="'+h(e.id)+'" '+(backupReceipts.has(e.id)?'':'disabled'))+'</section>';
    }).join('')+(archived.length?'<section><h2>보관한 프로젝트</h2>'+archived.map(e=>'<div class="profile-row"><strong>'+h(e.payload.title)+'</strong><button type="button" class="btn" data-archive-query="'+h(e.payload.title)+'">남겨둔 기록 찾기</button></div>').join('')+'</section>':'')+'<p class="tiny" style="margin-top:24px">연결 파일은 파일당 20MB, 프로젝트 백업의 첨부파일 합계는 32MB까지입니다. 한도를 넘으면 보관을 중단합니다.</p></main>';
}
function account() { return '<main class="wide" id="editor"><h1>계정 · 동기화</h1><p class="info">' + h(store.user ? '로그인: ' + store.user.email : '로그인하면 같은 계정의 Mac·웹·PWA가 연결됩니다.') + '</p><p class="meta">' + h(store.status) + '</p>' + (store.error ? '<p class="banner">' + h(store.error) + '</p>' : '') + '<div class="actions" style="margin-top:24px">' + (store.user ? button('지금 동기화', 'sync', '', true) + button('로그아웃', 'signOut') + button('이 기기의 로그인 전 기록 연결', 'adoptGuest') + button('백업 알림 받기', 'notifications') : button('로그인', 'signIn', '', true) + button('계정 만들기', 'signUp')) + '</div><div class="rule"></div><p class="info">로그인 전 기록과 다른 계정의 기록은 자동으로 섞지 않습니다. 현재 데이터는 이 기기에도 저장됩니다.</p></main>'; }
function deskState():DeskState{return {entities:store.entities,view,projectID,subjectID,recordID:selectedRecordID,status:store.status,query,day:planningDay,command:commandDraft,busy:commandBusy,projectsOpen,planOpen,collapsed:collapsedProjects};}
function rememberDesk(){if(!store.user||store.syncing)return;try{localStorage.setItem('ravil-desk:'+store.owner,JSON.stringify({view,projectID,subjectID,recordID:selectedRecordID,day:planningDay}));}catch{}}
function restoreDesk(){try{const saved=JSON.parse(localStorage.getItem('ravil-desk:'+store.owner)||'null');if(!saved)return;view=['editor','files','records','plan','profile','projects','account'].includes(saved.view)?saved.view:'editor';projectID=String(saved.projectID||'');subjectID=String(saved.subjectID||'');selectedRecordID=String(saved.recordID||'');planningDay=String(saved.day||'');}catch{}}
function applyDeskPanels(){
    const sidebar=root.querySelector<HTMLElement>('.desk-project-browser'),planning=root.querySelector<HTMLElement>('.desk-plan-panel');
    const projectSheet=matchMedia('(max-width:980px)').matches,planSheet=matchMedia('(max-width:1190px)').matches;
    const opened=projectSheet&&projectsOpen?sidebar:planSheet&&planOpen?planning:undefined;
    for(const panel of [sidebar,planning]){if(!panel)continue;const hidden=panel===sidebar?projectSheet&&!projectsOpen:planSheet&&!planOpen;panel.inert=hidden||!!opened&&panel!==opened;if(panel===opened){panel.setAttribute('role','dialog');panel.setAttribute('aria-modal','true');}else{panel.removeAttribute('role');panel.removeAttribute('aria-modal');}}
    for(const surface of root.querySelectorAll<HTMLElement>('.desk-work,.desk-rail'))surface.inert=!!opened;
    const backdrop=root.querySelector<HTMLElement>('.desk-panel-backdrop');if(backdrop)backdrop.hidden=!opened;
}
function focusDeskPanel(){root.querySelector<HTMLElement>('[aria-modal=true] button,[aria-modal=true] select')?.focus();}

function render() {
    preservedSelection=noteEditor&&noteEditorKey===(selectedRecordID||draftID)?{from:noteEditor.editor.state.selection.from,to:noteEditor.editor.state.selection.to}:undefined;
    noteEditor?.destroy();noteEditor=undefined;
    if(!store.user){root.innerHTML='<main class="workspace-lock"><h1>내 작업으로 이어가기</h1><p>'+h(store.status)+'</p><a class="btn primary" href="/login/?next=%2Fworkspace%2F">로그인</a></main>';return;}
    const expired=active(store.entities,'project').filter(e=>e.payload.phase!=='archived'&&e.payload.examDate&&e.payload.examDate<new Date().toLocaleDateString('sv-SE',{timeZone:'Asia/Seoul'}));
    const hits=query?new Set(searchRecords(store.entities,query).map(e=>e.id)):undefined;
    const content=query?'<main class="wide search-list" id="editor"><h2>검색</h2><input id="search" aria-label="기록 검색" placeholder="기록 · 주제 · 프로젝트 검색" value="'+h(query)+'" />'+filteredRecords().filter(e=>hits?.has(e.id)).map(row).join('')+'</main>':view==='editor'?editor():view==='files'?filesView():view==='records'?records():view==='plan'?plan():view==='profile'?profile():view==='projects'?projects():account();
    root.innerHTML='<div class="shell desk-shell">'+sidebar()+'<section class="work desk-work">'+deskHeader(deskState())+
      (expired.length&&view!=='projects'?'<div class="banner desk-backup-banner">종료일이 지난 프로젝트가 있어요. '+button('백업과 정리','projects')+'</div>':'')+
      '<div class="desk-main">'+content+'</div>'+deskCommand(deskState())+'</section>'+(view==='plan'?deskPlan(deskState()):'<aside class="desk-plan-panel studio-context '+(planOpen?'open':'')+'" aria-label="AI 맥락">'+renderAnalysisPanel(record(),store.entities,commandBusy,questionDraft,contextTab,icon)+'</aside>')+'</div><button class="desk-panel-backdrop" data-action="closePanels" aria-label="패널 닫기" '+(!projectsOpen&&!planOpen?'hidden':'')+'></button>';
    mountNoteEditor();applyDeskPanels();rememberDesk();
}
async function openContext(project:string,subject:string){
    await saveDraft();projectID=project;subjectID=subject;query='';planningDay='';projectsOpen=false;planOpen=false;collapsedProjects.delete(project);view='editor';
    const records=filteredRecords();const next=records.find(e=>e.id===selectedRecordID)||records[0];
    if(next)await openRecord(next.id);else newRecord();
}
function commandScopeDialog(){dialog('<h2>프로젝트 선택</h2><form><label>프로젝트<select name="project"><option value="">전체 기록</option>'+active(store.entities,'project').filter(e=>e.payload.phase!=='archived').map(e=>'<option value="'+h(e.id)+'" '+(e.id===projectID?'selected':'')+'>'+h(e.payload.title)+'</option>').join('')+'</select></label><button type="submit" class="btn primary">열기</button></form>',async form=>{await openContext(String(form.get('project')),'');});}
async function organizeCurrent(){const e=await saveDraft();if(!e)throw new Error('먼저 기록을 적어 주세요.');const parsed=await store.organize(e);planningDay='';notify(parsed.tasks.length+'개의 할 일로 정리했습니다.');}
async function analyzeCurrent(question=''){
    const e=await saveDraft();if(!e)throw new Error('먼저 기록을 적어 주세요.');
    if(!store.user)throw new Error('AI 도움은 로그인 후 사용할 수 있습니다.');
    const owner=store.owner;await store.sync();
    const source=store.get(e.id);if(!source||source.pending||source.conflict||store.error)throw new Error('원문 저장과 동기화를 먼저 확인해 주세요.');
    notify(question?'관련 기록을 바탕으로 질문을 살펴보고 있어요.':'내 기록을 분석하고 관련 내용을 정리하고 있어요.');
    const result=await store.api('ai/analyze',{recordID:source.id,mode:question?'question':'organize',...(question?{question}:{})});
    if(store.owner!==owner)throw new Error('계정이 바뀌어 AI 결과를 저장하지 않았습니다.');
    await saveDraft();
    await store.saveAnalysis(source,result);await store.sync();
    notify(store.error?'AI 결과는 기기에 저장됐어요. 클라우드 동기화를 확인해 주세요.':'AI 결과를 기록과 함께 저장했어요.');
}
async function runDeskCommand(forced?:string,argument='',preserveCommand=false){
    if(commandBusy||textComposing)return;
    const input=root.querySelector<HTMLTextAreaElement>('#desk-command');commandDraft=input?.value??commandDraft;
    const command=forced?{id:forced,text:argument}:resolveDeskCommand(commandDraft);if(!command)return;
    if(command.id==='question'&&!command.text.trim()){await saveDraft();view='editor';commandDraft='';planOpen=matchMedia('(max-width:1190px)').matches;projectsOpen=false;render();root.querySelector<HTMLInputElement>('#record-question')?.focus();return;}
    try{await saveDraft();}catch(error){notify((error as Error).message);return;}
    if(commandBusy)return;
    if(['summary','question'].includes(command.id)){planOpen=matchMedia('(max-width:1190px)').matches;projectsOpen=false;}
    commandBusy=true;render();let success=false;
    try{
      if(command.id==='unknown')throw new Error('사용할 명령을 / 목록에서 선택해 주세요.');
      if(command.id==='find'){await saveDraft();query=command.text;view='records';}
      if(command.id==='new'){await saveDraft();newRecord();}
      if(command.id==='capture'){
        await saveDraft();newRecord();draftBody=command.text;draftTitle=command.text.split('\n').find(line=>line.trim())?.slice(0,70)||'';draftFormat='plain';draftKind=parsePlan(command.text).tasks.some(task=>task.day)?'plan':'note';render();
        const e=await saveDraft();if(e&&draftKind==='plan')await store.organize(e);else await store.sync();
      }
      if(command.id==='plan')await organizeCurrent();
      if(command.id==='summary')await analyzeCurrent();
      if(command.id==='question'){await analyzeCurrent(command.text.trim());questionDraft='';}
      if(command.id==='attach'){await saveDraft();view='editor';render();pickNoteFiles();}
      if(command.id==='export')await exportNoteDialog();
      success=true;if(!preserveCommand)commandDraft='';
    }catch(error){notify((error as Error).message);}
    finally{
      let saved=true;try{await saveDraft();if(store.entities.some(entity=>entity.pending&&!entity.conflict))await store.sync();}catch(error){saved=false;notify((error as Error).message);}
      commandBusy=false;if(saved)render();else refreshAnalysisPanel();
      if(success&&command.id==='find')root.querySelector<HTMLInputElement>('#search')?.focus();if(success&&command.id==='new')root.querySelector<HTMLInputElement>('#title')?.focus();
    }
}
function refreshAnalysisPanel(){const panel=root.querySelector<HTMLElement>('#record-ai');if(panel&&!panel.contains(document.activeElement))panel.outerHTML=renderAnalysisPanel(record(),store.entities,commandBusy,questionDraft,contextTab,icon);}
function saveDraft():Promise<Entity | undefined> {
    clearTimeout(autoSave);
    const next=draftSaveChain.then(commitDraft);
    draftSaveChain=next.catch(()=>undefined);
    return next;
}
async function commitDraft() {
    if (!document.querySelector('#title') || !document.querySelector('#body')) return record();
    const title=document.querySelector<HTMLInputElement>('#title')?.value??draftTitle;
    const body=currentBody();draftTitle=title;draftBody=body;
    if(!body.trim()&&!title.trim())return;
    const e=record();draftKind=document.querySelector<HTMLSelectElement>('#record-kind')?.value||e?.payload.kind||draftKind;
    draftFormat=noteEditor?.format()||e?.payload.format||draftFormat;
    const subjectChoice=document.querySelector<HTMLSelectElement>('#subject')?.value,projectChoice=document.querySelector<HTMLSelectElement>('#project')?.value;
    const subjectIDs=subjectChoice!==undefined?(subjectChoice?[subjectChoice]:[]):e?.payload.subjectIDs|| (subjectID?[subjectID]:[]);
    const projectIDs=projectChoice!==undefined?(projectChoice?[projectChoice]:[]):e?.payload.projectIDs|| (projectID?[projectID]:[]);
    const saved=await store.put('record',{...(e?.payload||{}),title:title.trim()||noteEditor?.text().split('\n').find(l=>l.trim())?.slice(0,70)||body.split('\n').find(l=>l.trim())?.slice(0,70)||'제목 없는 노트',body,format:draftFormat,kind:draftKind,subjectIDs,projectIDs,fileIDs:[...new Set([...(e?.payload.fileIDs||[]),...draftFiles])],attachments:[...(e?.payload.attachments||[]),...draftAttachments].filter((f:NoteAttachment,i:number,a:NoteAttachment[])=>a.findIndex(x=>x.id===f.id)===i),tags:e?.payload.tags||[],createdAt:e?.payload.createdAt||new Date().toISOString()},e?.id||draftID,false,editingRevision);
    selectedRecordID=saved.id;editingRevision=saved.revision;return saved;
}
function mountNoteEditor(){noteEditorKey=selectedRecordID||draftID;const host=document.querySelector<HTMLElement>('.note-editor-host');if(!host)return;const payload=record()?.payload;noteEditor=new NoteEditor(host,payload?.body??draftBody,payload?.format??draftFormat,scheduleNoteSave,files=>void addNoteFiles(files).catch(e=>notify(e.message)),action=>void runNoteCommand(action).catch(e=>notify(e.message)));if(preservedSelection){const max=Math.max(1,noteEditor.editor.state.doc.content.size-1);noteEditor.editor.commands.setTextSelection({from:Math.min(max,preservedSelection.from),to:Math.min(max,preservedSelection.to)});}}
async function addNoteFiles(files:File[]){if(!store.user)throw new Error('로그인 후 노트에 파일을 넣을 수 있어요.');for(const file of files){notify(file.name+'을 보관하고 있어요.');const uploaded=await uploadNoteFile(file);draftAttachments.push(uploaded.original);draftFiles.push(uploaded.original.id);if(uploaded.image){if(uploaded.image.id!==uploaded.original.id){draftAttachments.push(uploaded.image);draftFiles.push(uploaded.image.id);}const src='/api/files/'+uploaded.image.id+(uploaded.image.sourceId?'#pdf='+uploaded.image.sourceId:'');if(noteEditor)noteEditor.image(src,file.name+(uploaded.original.pageCount?' · '+uploaded.original.pageCount+'쪽 원본':''));else{draftBody=currentBody()+'\n\n!['+file.name.replace(/[\[\]]/g,'')+']('+src+')\n';const body=document.querySelector<HTMLTextAreaElement>('#body');if(body)body.value=draftBody;}}await saveDraft();await store.sync();}notify('원본을 내 노트에 보관했습니다.');render();}
function pickNoteFiles(){const input=document.querySelector<HTMLInputElement>('#note-media-input')!;input.value='';input.multiple=true;input.accept='image/png,image/jpeg,image/webp,application/pdf';input.onchange=()=>void addNoteFiles([...input.files||[]]).catch(e=>notify(e.message));input.click();}
async function exportNoteDialog(){
    const saved=await saveDraft();if(!saved)throw new Error('먼저 노트를 적어 주세요.');
    const snapshot:NoteSnapshot={title:saved.payload.title,document:noteEditor?.json()||plainDocument(saved.payload.body),markdown:saved.payload.body,subjects:saved.payload.subjectIDs.map((id:string)=>store.get(id)?.payload.title||'').filter(Boolean),projects:saved.payload.projectIDs.map((id:string)=>store.get(id)?.payload.title||'').filter(Boolean),updatedAt:saved.updatedAt,attachments:saved.payload.attachments||[]};
    dialog('<h2>내보내기</h2><form><label>형식<select name="format"><option value="pdf">PDF</option><option value="docx">Word (.docx)</option><option value="md">Markdown / ZIP</option></select></label><label>용지<select name="size"><option value="LETTER">Letter</option><option value="A4">A4</option></select></label><button type="submit" class="btn primary">생성</button></form>',async f=>{
        notify('파일 생성 중');const output=await import('./note-export');const format=String(f.get('format')),size=String(f.get('size')) as 'LETTER'|'A4';
        let bytes:Uint8Array,name:string,mime:string;
        if(format==='pdf'){bytes=await output.createNotePDF(snapshot,size);name=safeFileName(snapshot.title)+'.pdf';mime='application/pdf';}
        else if(format==='docx'){bytes=await output.createNoteWord(snapshot,size);name=safeFileName(snapshot.title)+'.docx';mime='application/vnd.openxmlformats-officedocument.wordprocessingml.document';}
        else{const file=await output.createNoteMarkdown(snapshot);({bytes,name,mime}=file);}
        if(bytes.byteLength>64*1024*1024)throw new Error('출력 파일은 64MB까지 받을 수 있어요.');
        const response=await fetch('/api/exports/'+crypto.randomUUID(),{method:'PUT',credentials:'include',headers:{'Content-Type':mime,'X-Export-Name':encodeURIComponent(name)},body:bytes as BodyInit});const delivery=await response.json();if(!response.ok)throw new Error(delivery.error||'파일을 전달하지 못했습니다.');const url=delivery.url;
        modalBody.innerHTML='<h2>내보내기</h2><p class="meta">'+h(name)+'</p><div class="row" id="note-download-ready"></div>';
        const link=document.createElement('a');link.href=url;link.download=name;link.className='btn primary';link.textContent=format==='pdf'?'PDF 받기':format==='docx'?'Word 받기':'파일 받기';
        modalBody.querySelector('#note-download-ready')!.append(link);const expiry=document.createElement('p');expiry.className='tiny';expiry.textContent='링크 1시간 유효';modalBody.append(expiry);notify('파일 생성됨');return false;
    });
}
function newRecord() { questionDraft='';draftAttachments=[];draftFormat='markdown';draftKind='note';sourceMode=false;selectedRecordID = ''; draftID = crypto.randomUUID(); draftTitle = ''; draftBody = ''; draftFiles = []; view = 'editor'; query = ''; render(); document.querySelector<HTMLInputElement>('#title')?.focus(); }
async function openRecord(id: string) { const e = store.get(id); if (!e)
    return; questionDraft='';selectedRecordID = id; draftTitle = e.payload.title; draftBody = e.payload.body; draftFiles = e.payload.fileIDs; draftAttachments=e.payload.attachments||[];draftFormat=e.payload.format||'plain';draftKind=e.payload.kind||'note';sourceMode=false;view = 'editor'; query = ''; render(); await store.observe('read', id); }
function dialog(html: string, callback: (form: FormData) => Promise<void|false>) { modalBody.innerHTML = html; modal.showModal(); modalBody.querySelector('form')?.addEventListener('submit', async (event) => { event.preventDefault(); const form = event.currentTarget as HTMLFormElement; const submit = form.querySelector<HTMLButtonElement>('button[type=submit]'); if (submit)
    submit.disabled = true; try {
    const result=await callback(new FormData(form));
    if(result===false)return;
    modal.close();
    render();
}
catch (error) {
    notify((error as Error).message);
    if (submit)
        submit.disabled = false;
} }); }
function createContext(kind: 'subject' | 'project') {
    dialog('<h2>'+(kind==='subject'?'주제 추가':'프로젝트 추가')+'</h2><form><label>이름<input name="title" required maxlength="100" /></label>'+(kind==='project'?'<label>종류<select name="kind"><option value="project">프로젝트</option><option value="exam">시험 준비</option></select></label><label>종료일 · 선택<input name="examDate" type="date" /></label>':'')+'<button class="btn primary" type="submit">만들기</button></form>',async f=>{
        const title=String(f.get('title')||'').trim();if(!title)throw new Error('이름을 적어 주세요.');
        await saveDraft();const e=await store.put(kind,{title,kind:f.get('kind')||'subject',examDate:f.get('examDate')||'',phase:'active'});
        await store.sync();await openContext(kind==='project'?e.id:projectID,kind==='subject'?e.id:'');
    });
}
function authDialog(signUp = false) { dialog('<h2>' + (signUp ? 'RAVIL 계정 만들기' : '로그인') + '</h2><form>' + (signUp ? '<label>표시 이름<input name="name" required autocomplete="name" /></label>' : '') + '<label>이메일<input name="email" type="email" required autocomplete="username" /></label><label>비밀번호<input name="password" type="password" minlength="12" required autocomplete="' + (signUp ? 'new-password' : 'current-password') + '" /></label><p class="tiny">비밀번호는 12자 이상으로 설정해 주세요.</p><button class="btn primary" type="submit">' + (signUp ? '계정 만들기' : '로그인') + '</button></form>', async (f) => { await store.signIn(String(f.get('email')), String(f.get('password')), signUp ? String(f.get('name')) : undefined); if (await store.hasGuest())
    notify('로그인 전 기록은 계정 화면에서 연결할 수 있어요.'); }); }
function download(name: string, content: string, type = 'application/json') { const url = URL.createObjectURL(new Blob([content], { type })); const a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url), 60000); }
function ics(selected:Entity[]=scopedTasks(store.entities,{projectID,subjectID})) {
    const settings=active(store.entities,'preference').find(e=>e.payload.key==='planner')?.payload||{};
    const result=scheduleTasks(selected,settings.startHour??19,settings.endHour??23,settings.breakMinutes??5);
    if(!result.blocks.length)throw new Error('배치할 일정이 없습니다. 날짜와 작업 시간을 확인해 주세요.');
    download('ravil-plan.ics',calendarFile(result.blocks),'text/calendar;charset=utf-8');
}
root.addEventListener('compositionstart',()=>{textComposing=true;clearTimeout(autoSave);});root.addEventListener('compositionend',()=>{textComposing=false;scheduleNoteSave();});
root.addEventListener('pointerdown',event=>{if((event.target as HTMLElement).closest('[data-note-command],[data-desk-command]'))event.preventDefault();});
root.addEventListener('submit',event=>{const form=event.target as HTMLFormElement;if(form.id==='desk-command-form'){event.preventDefault();void runDeskCommand();}if(form.id==='record-question-form'){event.preventDefault();questionDraft=String(new FormData(form).get('question')||'');void runDeskCommand('question',questionDraft,true);}});
root.addEventListener('keydown',event=>{
    const contextButton=(event.target as HTMLElement).closest<HTMLButtonElement>('[data-context-tab]');
    if(contextButton&&['ArrowLeft','ArrowRight','Home','End'].includes(event.key)){event.preventDefault();const tabs=[...root.querySelectorAll<HTMLButtonElement>('[data-context-tab]')],index=tabs.indexOf(contextButton);const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;tabs[next].click();return;}
    if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='k'){event.preventDefault();void (async()=>{await saveDraft();view='records';projectID='';subjectID='';query='';render();root.querySelector<HTMLInputElement>('#search')?.focus();})();return;}
    const panel=root.querySelector<HTMLElement>('[aria-modal=true]');
    if(panel&&event.key==='Escape'){event.preventDefault();const wasProject=projectsOpen;projectsOpen=false;planOpen=false;render();root.querySelector<HTMLElement>('.desk-work-head [data-action='+ (wasProject?'toggleProjects':'togglePlan') +']')?.focus();return;}
    if(panel&&event.key==='Tab'){const controls=[...panel.querySelectorAll<HTMLElement>('button:not(:disabled),select,input,a[href]')].filter(el=>el.getClientRects().length);const first=controls[0],last=controls.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last?.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}}
    if((event.target as HTMLElement).id==='desk-command'){if(event.key==='Escape'){const menu=root.querySelector<HTMLElement>('#desk-command-options');if(menu)menu.hidden=true;}if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing&&!textComposing){event.preventDefault();event.stopPropagation();void runDeskCommand();}}});
window.addEventListener('resize',applyDeskPanels);
root.addEventListener('input', event => { const el = event.target as HTMLInputElement; if(el.id==='record-question'){questionDraft=el.value;return;}if(el.id==='desk-command'){commandDraft=el.value;const options=root.querySelector<HTMLElement>('#desk-command-options');if(options){options.innerHTML=commandOptions(commandDraft);options.hidden=!commandDraft.startsWith('/');}return;} if (el.id === 'title' || (el.id === 'body' && el instanceof HTMLTextAreaElement)) {
    clearTimeout(autoSave);
    if(!textComposing)autoSave = setTimeout(() => void saveDraft().catch(e => notify(e.message)), 700);
} if (el.id === 'search') {
    query = el.value;
    const cursor = el.selectionStart;
    render();
    const search = document.querySelector<HTMLInputElement>('#search')!;
    search.focus();
    search.setSelectionRange(cursor, cursor);
} });
root.addEventListener('change', async (event) => { const el = event.target as HTMLInputElement; try {
    if(el.dataset.planComplete){const task=store.get(el.dataset.planComplete);if(task)await store.complete(task);render();return;}
    if(el.id==='plan-day'){planningDay=el.value;render();return;}
    if(el.id==='note-style'){noteEditor?.run('style',el.value);return;}
    if(el.id==='record-kind'){draftKind=el.value;await saveDraft();await store.sync();return;}
    if(el.dataset.taskDay){const task=store.get(el.dataset.taskDay);if(el.value&&!validDay(el.value))throw new Error('날짜를 확인해 주세요.');if(task){await store.put('task',{...task.payload,day:el.value},task.id);await store.sync();}render();return;}
    if (el.id === 'subject' || el.id === 'project') {
        if (el.id === 'subject')
            subjectID = el.value;
        else
            projectID = el.value;
        await saveDraft();
        await store.sync();
        render();
    }
    if (el.dataset.duration) {
        const e = store.get(el.dataset.duration);
        const minutes = Number(el.value);
        if (!Number.isInteger(minutes) || minutes < 5 || minutes > 180)
            throw new Error('예상 시간은 5~180분으로 입력해 주세요.');
        if (e) {
            await store.put('task', { ...e.payload, minutes }, e.id);
            await store.sync();
        }
    }
    if (el.dataset.backup && el.files?.[0]) {
        const backup = JSON.parse(await el.files[0].text());
        const result = await store.api('backup/' + el.dataset.backup + '/verify', backup);
        backupReceipts.set(el.dataset.backup, result.snapshotID);
        notify('기록과 첨부파일 백업을 검사했습니다. 프로젝트를 보관할 수 있어요.');
        render();
    }
}
catch (e) {
    notify((e as Error).message);
} });
root.addEventListener('click', async (event) => {
    const el = (event.target as HTMLElement).closest<HTMLButtonElement>('button');
    if (!el)
        return;
    if(el.type==='submit'&&el.closest('form')?.id==='desk-command-form')return;
    try {
        if(el.dataset.contextTab){contextTab=el.dataset.contextTab as ContextTab;const panel=root.querySelector<HTMLElement>('#record-ai');if(panel)panel.outerHTML=renderAnalysisPanel(record(),store.entities,commandBusy,questionDraft,contextTab,icon);root.querySelector<HTMLElement>('[data-context-tab='+contextTab+']')?.focus();return;}
        if(el.dataset.deskCommand){await runDeskCommand(el.dataset.deskCommand);return;}
        if(el.dataset.archiveQuery){await saveDraft();projectID='';subjectID='';query=el.dataset.archiveQuery;view='records';render();return;}
        if(el.dataset.aiTask!==undefined||el.dataset.aiTags){
            await saveDraft();const source=record(),analysis=source&&getRecordAnalysis(source.payload);
            if(!source||source.id!==el.dataset.aiRecord||!analysis)throw new Error('현재 기록의 AI 결과를 다시 확인해 주세요.');
            if(el.dataset.aiTags){await store.put('record',{...source.payload,tags:[...new Set([...(source.payload.tags||[]),...analysis.tags])]},source.id);notify('직접 남긴 태그에 AI 주제를 더했어요.');}
            else{
                if(analysis.generatedAt!==el.dataset.analysisAt)throw new Error('새 AI 결과에서 제안을 다시 선택해 주세요.');
                const suggestion=analysis.suggestions[Number(el.dataset.aiTask)];if(!suggestion)throw new Error('추가할 제안을 찾지 못했습니다.');
                const draft={topic:'',action:suggestion.text,day:'',repetitions:1,minutes:30},id=await taskID(source.id,draft);
                if(!store.get(id)){await store.put('task',{...draft,recordID:source.id,subjectIDs:source.payload.subjectIDs,completed:0,origin:'ai-suggestion',evidenceIDs:suggestion.evidenceIDs,analysisGeneratedAt:analysis.generatedAt},id);await store.observe('planChanged',source.id);notify('할 일로 추가했어요. 계획에서 날짜와 시간을 정할 수 있어요.');}
                else notify('이미 추가한 할 일이에요. 기존 진행을 유지했어요.');
            }
            await store.sync();render();return;
        }
        if(el.dataset.projectToggle){const id=el.dataset.projectToggle;if(id!==projectID){await openContext(id,'');return;}if(collapsedProjects.has(id))collapsedProjects.delete(id);else collapsedProjects.add(id);render();return;}
        if(el.dataset.action==='toggleProjects'){projectsOpen=!projectsOpen;planOpen=false;render();focusDeskPanel();return;}
        if(el.dataset.action==='togglePlan'){planOpen=!planOpen;projectsOpen=false;render();focusDeskPanel();return;}
        if(el.dataset.action==='closePanels'){projectsOpen=false;planOpen=false;render();return;}
        if(el.dataset.action==='commandScope'){commandScopeDialog();return;}
        if(el.dataset.action==='workspaceHome'){await openContext(projectID,subjectID);return;}
        if(el.dataset.action==='home'){await saveDraft();await store.sync();location.assign('/');return;}
        if(el.dataset.action==='search'){await saveDraft();view='records';projectID='';subjectID='';query='';render();root.querySelector<HTMLInputElement>('#search')?.focus();return;}
        if (el.dataset.view) {
            await saveDraft();
            view = el.dataset.view;projectsOpen=false;planOpen=false;
            query = '';
            render();
            return;
        }
        if (el.dataset.record) {
            await saveDraft();
            await openRecord(el.dataset.record);
            return;
        }
        if (el.dataset.source) {
            await saveDraft();
            await openRecord(el.dataset.source);
            return;
        }
        if (el.dataset.subject) {
            await saveDraft();
            await openContext(el.dataset.withProject||'',el.dataset.subject);
            return;
        }
        if (el.dataset.project) {
            await saveDraft();
            await openContext(el.dataset.project,'');
            return;
        }
        if (el.dataset.complete) {
            const e = store.get(el.dataset.complete);
            if (e)
                await store.complete(e);
            render();
            return;
        }
        if(el.dataset.noteCommand){noteEditor?.run(el.dataset.noteCommand);return;}
        const action = el.dataset.action, id = el.dataset.id;
        if(action==='sourceMode'){draftBody=currentBody();draftFormat=record()?.payload.format||draftFormat;await saveDraft();sourceMode=!sourceMode;render();return;}
        if(action==='noteAttach'&&view!=='editor'){await saveDraft();view='editor';render();}
        if(['noteAttach','exportNote','importNote','insertMath','contextNote'].includes(action||'')){await runNoteCommand(action!);return;}
        if (action === 'save') {
            const e = await saveDraft();
            if (e && e.payload.kind==='plan')
                await store.organize(e);
            else
                await store.sync();
            notify(store.status);
            render();
        }
        if (action === 'newRecord')
            {await saveDraft();newRecord();}
        if (action === 'allRecords') {
            await saveDraft();subjectID = '';projectID = '';view='records';query='';planningDay='';
            render();
        }
        if (action === 'source' && id) { await saveDraft(); await openRecord(id); }
        if (action === 'newSubject')
            createContext('subject');
        if (action === 'newProject')
            createContext('project');
        if (action === 'account') { view = 'account'; query = ''; render(); }
        if (action === 'projects') {
            view = 'projects';
            query = '';
            render();
        }
        if (action === 'projectRecords' && id) {
            projectID = id;
            subjectID = '';
            view = 'records';
            render();
        }
        if (action === 'organize') {
            const e = await saveDraft();
            if (!e)
                throw new Error('먼저 기록을 적어 주세요.');
            const parsed = await store.organize(e);
            notify(parsed.tasks.length + '개의 할 일로 정리했습니다.');
            render();
        }
        if (action === 'analyze') {
            await runDeskCommand('summary','',true);return;
        }
        if (action === 'attach') {
            if (!store.user)
                throw new Error('파일 연결은 로그인 후 사용할 수 있습니다.');
            const input = document.createElement('input');
            input.type = 'file';
            input.onchange = async () => { try {
                const file = input.files?.[0];
                if (!file)
                    return;
                if (file.size > 20 * 1024 * 1024)
                    throw new Error('파일당 20MB까지 연결할 수 있습니다.');
                const id = crypto.randomUUID();
                const response = await fetch('/api/files/' + id, { method: 'PUT', credentials: 'include', headers: { 'Content-Type': file.type || 'application/octet-stream', 'X-File-Name': encodeURIComponent(file.name) }, body: file });
                if (!response.ok)
                    throw new Error((await response.json()).error);
                draftFiles.push(id);
                const e = await saveDraft();
                if (e)
                    await store.put('record', { ...e.payload, fileIDs: [...new Set([...e.payload.fileIDs, id])] }, e.id);
                await store.sync();
                render();
            }
            catch (e) {
                notify((e as Error).message);
            } };
            input.click();
        }
        if (action === 'notifications') {
            if (!('PushManager' in window) || !('Notification' in window)) throw new Error('이 브라우저의 알림 지원을 확인해 주세요. iPhone·iPad에서는 홈 화면 앱에서 설정할 수 있어요.');
            const key = await store.api('notifications/key');
            if (!key.configured) throw new Error('서버의 백업 알림 설정이 아직 준비되지 않았습니다.');
            if (await Notification.requestPermission() !== 'granted') throw new Error('알림 권한이 허용되지 않았습니다.');
            const registration = await navigator.serviceWorker.ready;
            const publicKey = Uint8Array.from(atob(key.publicKey.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
            const subscription = await registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:publicKey});
            await store.api('notifications/subscribe',subscription.toJSON());
            notify('종료일이 지난 프로젝트의 백업 알림을 받도록 연결했습니다.');
        }
        if (action === 'sync')
            await store.sync();
        if (action === 'signIn')
            authDialog();
        if (action === 'signUp')
            authDialog(true);
        if (action === 'signOut') {
            await saveDraft();
            await store.sync();
            await store.signOut();
            selectedRecordID = '';
            draftBody = '';
            draftTitle = '';
            draftFiles = [];
            location.replace('/login/');
        }
        if (action === 'adoptGuest') {
            await store.adoptGuest();
            notify('로그인 전 기록을 이 계정에 연결했습니다.');
        }
        if (action === 'remoteConflict' && id)
            await store.resolveConflict(id, 'remote');
        if (action === 'copyConflict' && id)
            await store.resolveConflict(id, 'copy');
        if (action === 'plannerSettings') {
            const startHour = Number(document.querySelector<HTMLInputElement>('#startHour')!.value), endHour = Number(document.querySelector<HTMLInputElement>('#endHour')!.value), breakMinutes = Number(document.querySelector<HTMLInputElement>('#breakMinutes')!.value);
            if (!Number.isInteger(startHour) || !Number.isInteger(endHour) || startHour < 0 || endHour > 24 || startHour >= endHour || breakMinutes < 0 || breakMinutes > 60)
                throw new Error('작업 시간과 휴식 기준을 확인해 주세요.');
            const old = active(store.entities, 'preference').find(e => e.payload.key === 'planner');
            await store.put('preference', { key: 'planner', startHour, endHour, breakMinutes, autoCalendar:document.querySelector<HTMLInputElement>('#autoCalendar')!.checked }, old?.id);
            await store.sync();
            render();
        }
        if (action === 'ics')
            ics();
        if (action === 'calendar'||action==='calendarScope') {
            await store.sync();
            let tasks=scopedTasks(store.entities,{projectID,subjectID});if(action==='calendarScope'){const day=choosePlanningDay(tasks,planningDay);tasks=tasks.filter(task=>task.payload.day===day);}
            const result = await store.api('calendar/sync', {taskIDs:tasks.map(task=>task.id)});
            notify('새 일정 ' + result.created + '개 · 수정 ' + result.updated + '개 · 배치하지 못한 작업 ' + result.unplaced.length + '개');
        }
        if (action === 'study' && id) {
            if (study) {
                const completed = study;
                study = undefined;
                await store.observe('study', completed.task.payload.recordID, completed.task.id, Math.round(completed.seconds / 60), completed.task.payload.action);
                notify('앱을 사용한 작업 시간 ' + Math.round(completed.seconds / 60) + '분을 기록했습니다.');
            }
            else {
                const task = store.get(id);
                if (task) {
                    study = { task, seconds: 0, last: Date.now() };
                    lastInteraction = Date.now();
                    notify('RAVIL이 보이고 사용 중인 시간만 기록합니다.');
                }
            }
            render();
        }
        if (action === 'correction')
            dialog('<h2>나에 대해 알려주기</h2><form><label>잘못 파악한 점이나 기억할 내용<input name="text" required maxlength="1000" /></label><button type="submit" class="btn primary">반영하기</button></form>', async (f) => { await store.put('preference', { key: 'correction', text: String(f.get('text')), at: new Date().toISOString() }); await store.observe('correction'); await store.sync(); });
        if (action === 'forget' && id) {
            const e = store.get(id);
            if (e)
                await store.put('preference', e.payload, id, true);
            await store.sync();
            render();
        }
        if (action === 'backup' && id) {
            await store.sync();
            const value = await store.api('backup/' + id, {});
            download('RAVIL-' + safeFileName(store.get(id)?.payload.title || '프로젝트') + '-backup.json', JSON.stringify(value));
            notify('백업 파일을 내려받았습니다. 저장한 파일을 선택해 검사해 주세요.');
        }
        if (action === 'finishProject' && id) {
            const receipt = backupReceipts.get(id);
            if (!receipt)
                throw new Error('백업을 먼저 검사해 주세요.');
            await store.api('projects/' + id + '/finish', { snapshotID: receipt });
            backupReceipts.delete(id);
            await store.sync();
            projectID = '';
            notify('프로젝트를 보관했습니다. 원본 기록은 계속 남아 있어요.');
            render();
        }
    }
    catch (error) {
        notify((error as Error).message);
        el.disabled = false;
    }
});
document.addEventListener('keydown', event => { if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
    event.preventDefault();
    void saveDraft().then(() => store.sync()).then(() => notify(store.status));
} });
store.addEventListener('beforelock', () => {
    if (document.querySelector('#body')) void saveDraft().catch(() => {});
});
store.addEventListener('acknowledged', event => {
    const {id,sourceRevision,revision}=(event as CustomEvent).detail;
    if(id===selectedRecordID && editingRevision===sourceRevision) editingRevision=revision;
});
store.addEventListener('change', () => {
    if (!store.user) { clearTimeout(autoSave); study = undefined; modal.close(); modalBody.replaceChildren(); backupReceipts.clear(); render(); return; }
    if (renderedOwner !== store.owner) {
        clearTimeout(autoSave); renderedOwner = store.owner; selectedRecordID = ''; editingRevision = 0;
        draftID = crypto.randomUUID(); draftTitle = ''; draftBody = ''; draftFiles = [];draftAttachments=[];draftFormat='markdown';draftKind='note';sourceMode=false;subjectID = ''; projectID = ''; study = undefined;questionDraft='';commandDraft='';planningDay='';projectsOpen=false;planOpen=false;restoreDesk();
    }
    const current = record();
    const liveBody = currentBody();
    const liveTitle = document.querySelector<HTMLInputElement>('#title')?.value;
    if (current && liveBody === current.payload.body && (liveTitle === current.payload.title || (!liveTitle && liveBody?.split('\n').find(l=>l.trim())?.slice(0,70) === current.payload.title))) editingRevision = current.revision;
    const unsavedEditor=view==='editor' && !!document.querySelector('#body') && (liveBody!==(current?.payload.body??draftBody) || liveTitle!==(current?.payload.title??draftTitle));
    const focused = document.activeElement; if (unsavedEditor || noteEditor?.focused() || focused?.id === 'body' || focused?.id === 'title' || focused?.id === 'search' || focused?.id==='desk-command' || commandBusy || modal.open) {
    const status = document.querySelector('#sync-status');
    if (status)
        status.textContent = store.status;
    const editorStatus = document.querySelector('#editor-status');
    if (editorStatus)
        editorStatus.textContent = store.status;
    refreshAnalysisPanel();
}
else
    render(); });
void store.initialize().then(async () => {
    if(store.user)offerPendingCapture();
    if (store.user && 'serviceWorker' in navigator) void navigator.serviceWorker.register('/workspace-sw.js', {scope:'/workspace/'}).catch(() => {});
}).catch(e => { root.textContent = '이 기기에 기록을 저장하지 못했습니다. 브라우저 저장 공간을 확인해 주세요.'; notify(e.message); });

function offerPendingCapture(){
  let pending:{body:string;kind:string;at:number};
  try{pending=JSON.parse(sessionStorage.getItem('ravil-pending-capture')||'null');}catch{return;}
  if(!pending||typeof pending.body!=='string'||!pending.body.trim()||pending.body.length>60000)return;
  if(!Number.isFinite(pending.at)||Date.now()-pending.at>2*60*60*1000){sessionStorage.removeItem('ravil-pending-capture');return;}
  dialog('<h2>작성하던 기록</h2><p class="info">이 계정의 새 기록으로 저장할까요?</p><pre class="desk-pending-preview">'+h(pending.body.slice(0,700))+'</pre><form><label>프로젝트<select name="project"><option value="">프로젝트 없이</option>'+active(store.entities,'project').filter(e=>e.payload.phase!=='archived').map(e=>'<option value="'+h(e.id)+'">'+h(e.payload.title)+'</option>').join('')+'</select></label><button type="submit" class="btn primary">저장하고 열기</button><button type="button" class="btn" id="discard-pending">지우기</button></form>',async data=>{await saveDraft();projectID=String(data.get('project'));subjectID='';newRecord();draftBody=pending.body;draftTitle=pending.body.split('\n').find(line=>line.trim())?.slice(0,70)||'';draftKind=['note','plan','activity'].includes(pending.kind)?pending.kind:'note';draftFormat='plain';render();const saved=await saveDraft();if(saved&&draftKind==='plan')await store.organize(saved);else await store.sync();sessionStorage.removeItem('ravil-pending-capture');});
  modalBody.querySelector('#discard-pending')?.addEventListener('click',()=>{sessionStorage.removeItem('ravil-pending-capture');modal.close();});
}
