import type {JSONContent} from '@tiptap/core';

export interface NoteAttachment { id:string; name:string; mime:string; size:number; sourceId?:string; pageCount?:number }
export interface NoteSnapshot { title:string; document:JSONContent; markdown:string; subjects:string[]; projects:string[]; updatedAt:string; attachments:NoteAttachment[] }
export const fileIDPattern=/^[a-f0-9]{8}-[a-f0-9-]{27}$/i;
export function attachmentID(src:string):string|null {const m=src.match(/^\/api\/files\/([a-f0-9-]{36})(?:#[^\s]*)?$/i);return m&&fileIDPattern.test(m[1])?m[1]:null;}
export function sourcePDFID(src:string):string|null {const id=src.match(/#pdf=([a-f0-9-]{36})$/i)?.[1];return id&&fileIDPattern.test(id)?id:null;}
export function safeLink(url:string):boolean {return /^(https?:\/\/|mailto:|\/workspace\/?(?:[?#]|$)|\/api\/files\/[a-f0-9-]{36}(?:$|#))/i.test(url);}
export function plainDocument(text:string):JSONContent {return {type:'doc',content:text.split(/\r?\n/).map(line=>({type:'paragraph',content:line?[{type:'text',text:line}]:[]}))};}
export function documentText(node:JSONContent):string {
  if(node.type==='text')return node.text||'';
  if(node.type==='inlineMath'||node.type==='blockMath')return String(node.attrs?.latex||'');
  if(node.type==='image')return String(node.attrs?.alt||'');
  if(node.type==='hardBreak')return '\n';
  const separator=['doc','bulletList','orderedList','taskList','table','tableRow'].includes(node.type||'')?'\n':'';
  return (node.content||[]).map(documentText).join(separator)+(node.type==='paragraph'||node.type==='heading'?'\n':'');
}
export function planningText(markdown:string):string {return markdown.replace(/^---\n[\s\S]*?\n---\n/,'').replace(/^#{1,6}\s+/gm,'').replace(/^\s*[-*]\s+\[[ xX]\]\s*/gm,'- ').replace(/\*\*|__|~~/g,'').replace(/\\([()[\]_*])/g,'$1').replace(/!\[[^\]]*\]\([^)]*\)/g,'');}
export function safeFileName(name:string):string {return (name.replace(/[\\/:*?"<>|\u0000-\u001f]/g,'_').replace(/^\.+/,'').trim()||'RAVIL 노트').slice(0,100);}
export function splitFrontmatter(body:string):{prefix:string;content:string} {const m=body.match(/^(---\r?\n[\s\S]*?\r?\n---\r?\n)/);return m?{prefix:m[1],content:body.slice(m[1].length)}:{prefix:'',content:body};}
export function hasUnsupportedMarkdown(body:string):boolean {return /!\[\[|\[\^|^>\s*\[!|^:::|<script|<iframe|<svg|<style/im.test(body);}
export function referencedFileIDs(node:JSONContent):string[] {const ids:string[]=[];const walk=(n:JSONContent)=>{if(n.type==='image'){const src=String(n.attrs?.src||'');const id=attachmentID(src),pdf=sourcePDFID(src);if(id)ids.push(id);if(pdf)ids.push(pdf);}for(const c of n.content||[])walk(c);};walk(node);return [...new Set(ids)];}
