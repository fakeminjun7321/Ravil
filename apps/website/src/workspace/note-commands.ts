export interface NoteCommand {id:string;label:string;icon:string;value?:string;aliases:string[];group:string}
export const noteCommands:NoteCommand[]=[
 {id:'style',value:'p',label:'텍스트',icon:'text',aliases:['text','paragraph','본문'],group:'블록'},
 {id:'style',value:'1',label:'제목 1',icon:'heading',aliases:['h1','heading1','큰제목'],group:'블록'},
 {id:'style',value:'2',label:'제목 2',icon:'heading',aliases:['h2','heading2','제목','중간제목'],group:'블록'},
 {id:'style',value:'3',label:'제목 3',icon:'heading',aliases:['h3','heading3','작은제목'],group:'블록'},
 {id:'bullet',label:'목록',icon:'list',aliases:['bullet','list','리스트'],group:'블록'},
 {id:'number',label:'번호 목록',icon:'number',aliases:['number','ordered'],group:'블록'},
 {id:'check',label:'체크리스트',icon:'check',aliases:['todo','task','check','체크','할일'],group:'블록'},
 {id:'quote',label:'인용',icon:'quote',aliases:['quote'],group:'블록'},
 {id:'table',label:'표',icon:'table',aliases:['table'],group:'블록'},
 {id:'rule',label:'구분선',icon:'divider',aliases:['divider','line','구분'],group:'블록'},
 {id:'code',label:'코드',icon:'code',aliases:['code'],group:'블록'},
 {id:'insertMath',label:'수식',icon:'math',aliases:['math','equation','formula'],group:'자료'},
 {id:'noteAttach',label:'사진 · PDF',icon:'image',aliases:['image','photo','pdf','file','손글씨','사진','파일'],group:'자료'},
 {id:'contextNote',label:'과목 · 프로젝트',icon:'folder',aliases:['context','연결','과목','프로젝트'],group:'자료'},
];
export function filterNoteCommands(query:string){const key=query.normalize('NFKC').toLocaleLowerCase().replace(/\s/g,'');return noteCommands.filter(c=>[c.label,...c.aliases].some(label=>label.toLocaleLowerCase().replace(/\s/g,'').includes(key)));}
export function slashQuery(textBeforeCursor:string):string|null {const match=textBeforeCursor.match(/^\/([^\s/]{0,40})$/);return match?match[1]:null;}
