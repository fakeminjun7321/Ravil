import {Editor,type JSONContent} from '@tiptap/core';
import {noteExtensions} from './note-extensions';
import {plainDocument,documentText,hasUnsupportedMarkdown,splitFrontmatter} from './note-format';
import {filterNoteCommands,slashQuery,type NoteCommand} from './note-commands';
import {icon} from './icons';
import 'katex/dist/katex.min.css';

const escape=(value:string)=>value.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const tool=(action:string,label:string,glyph:string)=>'<button type="button" class="note-tool" data-note-command="'+action+'" aria-label="'+label+'" title="'+label+'">'+icon(glyph)+'</button>';

export class NoteEditor {
  editor:Editor; dirty=false; composing=false;
  private original:string; private prefix:string;
  private commandMenu=document.createElement('div'); private commandList=document.createElement('div');
  private commandSearch=document.createElement('input'); private bubble=document.createElement('div');
  private manual=false; private trigger?:{from:number;to:number;start:number;query:string};
  private dismissedStart?:number; private query=''; private selected=0; private items:NoteCommand[]=[];
  private reposition=()=>this.updateUI();
  private outside=(event:PointerEvent)=>{const target=event.target as Node;if(!this.commandMenu.contains(target)&&!this.bubble.contains(target)&&!this.host.contains(target)&&!(target as Element).closest?.('.note-toolbar'))this.closeCommands();};

  constructor(private host:HTMLElement,body:string,format:string,onChange:()=>void,onFiles:(files:File[])=>void,private onAction:(action:string)=>void=()=>{}){
    this.original=body;const split=splitFrontmatter(body);this.prefix=format==='markdown'?split.prefix:'';
    this.commandMenu.className='note-command-menu';this.commandMenu.hidden=true;
    this.commandSearch.type='search';this.commandSearch.placeholder='검색';this.commandSearch.setAttribute('aria-label','명령 검색');
    this.commandSearch.addEventListener('input',()=>{this.query=this.commandSearch.value;this.selected=0;this.renderCommands();});
    this.commandSearch.addEventListener('keydown',event=>{if(this.key(event)){event.preventDefault();event.stopPropagation();}});
    this.commandList.setAttribute('role','listbox');this.commandList.setAttribute('aria-label','블록 명령');
    this.commandList.id='note-commands-'+crypto.randomUUID();
    const keys=document.createElement('div');keys.className='note-command-keys';keys.textContent='↑ ↓    ↵    esc';
    this.commandMenu.append(this.commandSearch,this.commandList,keys);document.body.append(this.commandMenu);
    this.bubble.className='note-selection-tools';this.bubble.setAttribute('role','toolbar');this.bubble.setAttribute('aria-label','선택한 글 서식');this.bubble.hidden=true;
    this.bubble.innerHTML=[['bold','굵게','bold'],['italic','기울임','italic'],['underline','밑줄','underline'],['strike','취소선','strike'],['inlineCode','코드','code']].map(([action,label,glyph])=>tool(action,label,glyph)).join('');
    this.bubble.addEventListener('pointerdown',event=>event.preventDefault());
    this.bubble.addEventListener('click',event=>{const action=(event.target as Element).closest<HTMLButtonElement>('[data-note-command]')?.dataset.noteCommand;if(action)this.run(action);});document.body.append(this.bubble);
    this.editor=new Editor({element:host,extensions:noteExtensions(),content:format==='markdown'?split.content:plainDocument(body),contentType:format==='markdown'?'markdown':'json',editorProps:{attributes:{class:'note-prose',role:'textbox','aria-label':'기록 본문','aria-multiline':'true'},handleKeyDown:(_view,event)=>this.key(event),transformPastedHTML:html=>{const doc=new DOMParser().parseFromString(html,'text/html');doc.querySelectorAll('script,iframe,svg,style,object').forEach(e=>e.remove());doc.querySelectorAll('img').forEach(e=>{if(!/^\/api\/files\/[a-f0-9-]{36}/i.test(e.getAttribute('src')||''))e.remove();});return doc.body.innerHTML;},handlePaste:(_view,event)=>{const files=[...event.clipboardData?.files||[]];if(files.length){onFiles(files);return true;}return false;},handleDrop:(_view,event)=>{const files=[...event.dataTransfer?.files||[]];if(files.length){onFiles(files);return true;}return false;}},onUpdate:()=>{this.dirty=true;this.updateUI();if(!this.composing)onChange();},onSelectionUpdate:()=>this.updateUI(),onFocus:()=>this.updateUI(),onBlur:()=>{setTimeout(()=>{if(!this.editor?.isDestroyed)this.updateUI();},0);}});
    host.addEventListener('compositionstart',()=>{this.composing=true;});host.addEventListener('compositionend',()=>{this.composing=false;this.dirty=true;this.updateUI();onChange();});
    if(format==='markdown'&&hasUnsupportedMarkdown(body)){this.editor.setEditable(false);host.insertAdjacentHTML('beforebegin','<p class="banner">특수 문법 · 원문에서 편집</p>');}
    window.visualViewport?.addEventListener('resize',this.reposition);window.visualViewport?.addEventListener('scroll',this.reposition);window.addEventListener('resize',this.reposition);window.addEventListener('scroll',this.reposition,true);document.addEventListener('pointerdown',this.outside);this.updateUI();
  }
  body(){return this.dirty?this.prefix+this.editor.getMarkdown():this.original;}
  format(){return this.dirty?'markdown':undefined;}
  text(){return documentText(this.editor.getJSON());}
  json():JSONContent{return this.editor.getJSON();}
  focused(){return this.editor.isFocused||this.composing||(!this.commandMenu.hidden&&this.manual);}
  destroy(){window.visualViewport?.removeEventListener('resize',this.reposition);window.visualViewport?.removeEventListener('scroll',this.reposition);window.removeEventListener('resize',this.reposition);window.removeEventListener('scroll',this.reposition,true);document.removeEventListener('pointerdown',this.outside);this.commandMenu.remove();this.bubble.remove();this.editor.destroy();}
  run(action:string,value?:string){
    if(!this.editor.isEditable)throw new Error('특수 문법이 있는 기존 노트는 원문 모드에서 편집해 주세요.');
    if(action==='commands'){this.openCommands();return;}
    if(['insertMath','noteAttach','contextNote'].includes(action)){this.onAction(action);return;}
    const chain=this.editor.chain().focus();
    switch(action){case 'bold':chain.toggleBold().run();break;case 'italic':chain.toggleItalic().run();break;case 'underline':chain.toggleUnderline().run();break;case 'strike':chain.toggleStrike().run();break;case 'inlineCode':chain.toggleCode().run();break;case 'bullet':chain.toggleBulletList().run();break;case 'number':chain.toggleOrderedList().run();break;case 'check':chain.toggleTaskList().run();break;case 'quote':chain.toggleBlockquote().run();break;case 'table':chain.insertTable({rows:3,cols:2,withHeaderRow:true}).run();break;case 'row':chain.addRowAfter().run();break;case 'column':chain.addColumnAfter().run();break;case 'undo':chain.undo().run();break;case 'redo':chain.redo().run();break;case 'style':value==='p'?chain.setParagraph().run():chain.setHeading({level:Number(value) as 1|2|3}).run();break;case 'rule':chain.setHorizontalRule().run();break;case 'code':chain.toggleCodeBlock().run();break;case 'insertMath':case 'noteAttach':case 'contextNote':this.onAction(action);break;}
    this.updateUI();
  }
  image(src:string,alt:string){if(!this.editor.isEditable)throw new Error('특수 문법 노트의 원문을 먼저 확인해 주세요.');this.editor.chain().focus().setImage({src,alt}).insertContent({type:'paragraph'}).run();}
  math(latex:string,block:boolean){if(!this.editor.isEditable)throw new Error('특수 문법 노트의 원문을 먼저 확인해 주세요.');this.editor.chain().focus().insertContent({type:block?'blockMath':'inlineMath',attrs:{latex}}).run();}
  private key(event:KeyboardEvent):boolean {
    if(event.isComposing||this.composing||event.key==='Process')return false;
    if((event.metaKey||event.ctrlKey)&&event.key==='/'){this.openCommands();return true;}
    if(this.commandMenu.hidden)return false;
    if(event.key==='Escape'){this.closeCommands();this.editor.commands.focus();return true;}
    if(event.key==='ArrowDown'||event.key==='ArrowUp'){this.selected=(this.selected+(event.key==='ArrowDown'?1:-1)+Math.max(1,this.items.length))%Math.max(1,this.items.length);this.renderCommands();return true;}
    if(event.key==='Enter'){if(this.items.length)this.choose(this.selected);return true;}
    return false;
  }
  private closeCommands(){this.dismissedStart=this.trigger?.start;this.manual=false;this.commandMenu.hidden=true;this.editor?.view.dom.removeAttribute('aria-activedescendant');}
  private openCommands(){if(!this.editor.isEditable)return;this.manual=true;this.trigger=undefined;this.query='';this.selected=0;this.commandSearch.value='';this.renderCommands();this.commandSearch.focus();}
  private choose(index:number){
    const item=this.items[index];if(!item)return;const range=this.trigger;
    this.closeCommands();this.trigger=undefined;this.dismissedStart=range?.start;
    if(range)this.editor.chain().focus().deleteRange({from:range.from,to:range.to}).run();
    this.run(item.id,item.value);
  }
  private place(element:HTMLElement,position:number,above=false){try{const caret=this.editor.view.coordsAtPos(position);const vv=window.visualViewport;const right=vv?vv.offsetLeft+vv.width:innerWidth,bottom=vv?vv.offsetTop+vv.height:innerHeight;if(element===this.commandMenu)element.style.maxHeight=Math.min(420,bottom-(vv?.offsetTop||0)-24)+'px';const width=Math.min(element.offsetWidth,right-16),height=Math.min(element.offsetHeight,bottom-16);element.style.left=Math.max(8,Math.min(caret.left,right-width-8))+'px';const top=above?caret.top-height-8:caret.bottom+8;element.style.top=Math.max(8,Math.min(top,bottom-height-8))+'px';}catch{element.hidden=true;}}
  private renderCommands(){
    this.items=filterNoteCommands(this.query);this.selected=Math.min(this.selected,Math.max(0,this.items.length-1));this.commandSearch.hidden=!this.manual;
    let group='';this.commandList.innerHTML=this.items.map((item,index)=>{const label=group!==item.group?'<div class="note-command-group">'+item.group+'</div>':'';group=item.group;return label+'<button type="button" id="'+this.commandList.id+'-'+index+'" role="option" aria-selected="'+(index===this.selected)+'" data-command-index="'+index+'">'+icon(item.icon)+'<span>'+escape(item.label)+'</span>'+(item.value&&item.value!=='p'?'<kbd>H'+item.value+'</kbd>':'')+'</button>';}).join('')||'<div class="note-command-empty">결과 없음</div>';
    this.commandList.querySelectorAll<HTMLButtonElement>('[data-command-index]').forEach(button=>{button.addEventListener('pointerdown',event=>event.preventDefault());button.addEventListener('click',()=>this.choose(Number(button.dataset.commandIndex)));});
    this.commandMenu.hidden=false;this.commandList.querySelector('[aria-selected=true]')?.scrollIntoView({block:'nearest'});this.place(this.commandMenu,this.trigger?.from??this.editor.state.selection.from);
    this.editor.view.dom.setAttribute('aria-controls',this.commandList.id);if(this.items.length)this.editor.view.dom.setAttribute('aria-activedescendant',this.commandList.id+'-'+this.selected);else this.editor.view.dom.removeAttribute('aria-activedescendant');
  }
  private updateUI(){
    if(!this.editor||this.editor.isDestroyed)return;
    const toolbar=this.host.parentElement?.querySelector('.note-toolbar');
    this.bubble.querySelectorAll<HTMLButtonElement>('[data-note-command]').forEach(button=>button.setAttribute('aria-pressed',String(this.editor.isActive(button.dataset.noteCommand==='inlineCode'?'code':button.dataset.noteCommand!))));
    toolbar?.querySelectorAll<HTMLButtonElement>('[data-note-command]').forEach(button=>{button.disabled=!this.editor.isEditable;const mark=button.dataset.noteCommand;if(mark&&['bold','italic','underline'].includes(mark))button.setAttribute('aria-pressed',String(this.editor.isActive(mark)));});
    const style=toolbar?.querySelector<HTMLSelectElement>('#note-style');if(style){style.disabled=!this.editor.isEditable;style.value=this.editor.isActive('heading')?String(this.editor.getAttributes('heading').level):'p';}
    const table=toolbar?.querySelector<HTMLElement>('.note-table-tools');if(table)table.hidden=!this.editor.isActive('table');
    const selection=this.editor.state.selection;
    this.bubble.hidden=!this.editor.isFocused||selection.empty||!this.editor.isEditable||!['paragraph','heading'].includes(selection.$from.parent.type.name)||this.composing;
    if(!this.bubble.hidden)this.place(this.bubble,selection.from,true);
    if(this.manual){this.place(this.commandMenu,selection.from);return;}
    if(!this.editor.isFocused||!this.editor.isEditable||this.composing||!selection.empty||selection.$from.parent.type.name!=='paragraph'){this.commandMenu.hidden=true;return;}
    const query=slashQuery(selection.$from.parent.textBetween(0,selection.$from.parentOffset,'\n','\ufffc'));
    if(query===null){this.trigger=undefined;this.dismissedStart=undefined;this.commandMenu.hidden=true;return;}
    const start=selection.$from.start();if(start===this.dismissedStart)return;
    if(this.trigger?.query!==query)this.selected=0;
    this.trigger={from:start,to:selection.from,start,query};this.query=query;this.renderCommands();
  }
}
export function noteToolbar(){return '<div class="note-toolbar" role="toolbar" aria-label="노트 서식">'+tool('commands','블록 삽입 (/)','plus')+'<span class="note-tool-divider"></span><label class="note-style"><span class="sr-only">문단 서식</span><select id="note-style" aria-label="문단 서식"><option value="p">Aa</option><option value="1">H1</option><option value="2">H2</option><option value="3">H3</option></select></label>'+[['bold','굵게','bold'],['italic','기울임','italic'],['underline','밑줄','underline']].map(([action,label,glyph])=>tool(action,label,glyph)).join('')+'<span class="note-tool-divider"></span>'+[['bullet','목록','list'],['check','체크리스트','check'],['table','표','table'],['noteAttach','사진 · PDF','image'],['insertMath','수식','math']].map(([action,label,glyph])=>tool(action,label,glyph)).join('')+'<span class="note-table-tools" hidden>'+tool('row','행 추가','row')+tool('column','열 추가','column')+'</span><span class="note-tool-spacer"></span>'+tool('undo','되돌리기','undo')+tool('redo','다시하기','redo')+'</div>';}
