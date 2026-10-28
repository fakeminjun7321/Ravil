import {Node, mergeAttributes, type Extensions} from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import {Markdown} from '@tiptap/markdown';
import Image from '@tiptap/extension-image';
import {Table,TableRow,TableCell,TableHeader} from '@tiptap/extension-table';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import Placeholder from '@tiptap/extension-placeholder';
import katex from 'katex';
import {attachmentID,safeLink} from './note-format';

function mathNode(block:boolean){const name=block?'blockMath':'inlineMath';return Node.create({
  name,group:block?'block':'inline',inline:!block,atom:true,
  addAttributes(){return {latex:{default:''}};},
  parseHTML(){return [{tag:(block?'div':'span')+'[data-note-math]',getAttrs:el=>({latex:(el as HTMLElement).dataset.noteMath||''})}];},
  renderHTML({HTMLAttributes}){return [block?'div':'span',mergeAttributes(HTMLAttributes,{'data-note-math':HTMLAttributes.latex,class:block?'note-math-block':'note-math-inline'})];},
  addNodeView(){return ({node})=>{const dom=document.createElement(block?'div':'span');dom.className=block?'note-math-block':'note-math-inline';dom.dataset.noteMath=String(node.attrs.latex);try{katex.render(String(node.attrs.latex),dom,{displayMode:block,throwOnError:false,trust:false,maxExpand:1000});}catch{dom.textContent=String(node.attrs.latex);}return {dom};};},
  markdownTokenizer:{name,level:block?'block':'inline',start:src=>src.indexOf(block?'$$':'$'),tokenize(src){const match=block?src.match(/^\$\$\s*([\s\S]+?)\s*\$\$(?:\n|$)/):src.match(/^\$(?!\$)((?:\\.|[^$\n])+?)\$/);if(match&&match[1].length<5000)return {type:name,raw:match[0],latex:match[1]};}},
  parseMarkdown(token,helpers){return helpers.createNode(name,{latex:token.latex});},
  renderMarkdown(node){const value=String(node.attrs?.latex||'');return block?'$$\n'+value+'\n$$':'$'+value+'$';}
});}
const NoteImage=Image.extend({
  renderHTML({HTMLAttributes}){const src=String(HTMLAttributes.src||'');if(!attachmentID(src))return ['span',{class:'note-external-image'},'외부 이미지: '+String(HTMLAttributes.alt||src)];return ['img',mergeAttributes(HTMLAttributes,{loading:'lazy'})];},
  addNodeView(){return ({node})=>{const src=String(node.attrs.src||'');if(!attachmentID(src)){const dom=document.createElement('span');dom.className='note-external-image';dom.textContent='외부 이미지: '+String(node.attrs.alt||src);return {dom};}const dom=document.createElement('figure');dom.className='note-image';const image=document.createElement('img');image.src=src;image.alt=String(node.attrs.alt||'첨부한 노트');image.loading='lazy';dom.append(image);if(node.attrs.alt){const caption=document.createElement('figcaption');caption.textContent=String(node.attrs.alt);dom.append(caption);}return {dom};};}
});
export function noteExtensions():Extensions{return [StarterKit.configure({link:{openOnClick:false,autolink:false,isAllowedUri:url=>safeLink(url)}}),NoteImage.configure({allowBase64:false}),Table.configure({resizable:false}),TableRow,TableCell,TableHeader,TaskList,TaskItem.configure({nested:true}),mathNode(false),mathNode(true),Markdown.configure({markedOptions:{gfm:true,breaks:false}}),Placeholder.configure({placeholder:'/ 명령'})];}
