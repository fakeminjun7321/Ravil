import test from 'node:test';
import assert from 'node:assert/strict';
import {MarkdownManager} from '@tiptap/markdown';
import {noteExtensions} from '../src/workspace/note-extensions';
import {attachmentID,sourcePDFID,planningText,splitFrontmatter,hasUnsupportedMarkdown,safeLink} from '../src/workspace/note-format';
import {parsePlan,examplePlan} from '../src/workspace/domain';
import {filterNoteCommands,slashQuery} from '../src/workspace/note-commands';
const id='ab123456-1234-1234-1234-123456789abc';
test('rich notes preserve headings, emphasis, tables, mathematics and PDF attachment references',()=>{
 const manager=new MarkdownManager({extensions:noteExtensions()});
 const body='## 축전기\n\n**에너지**를 정리합니다.\n\n| 값 | 의미 |\n| --- | --- |\n| C | 전기용량 |\n\n$$\nE=\\frac{1}{2}CV^2\n$$\n\n![필기 PDF](/api/files/'+id+'#pdf='+id+')';
 const json=manager.parse(body);const serialized=manager.serialize(json);
 assert.ok(serialized.includes('## 축전기'));assert.ok(serialized.includes('**에너지**'));assert.ok(serialized.includes('전기용량'));assert.ok(serialized.includes('\\frac{1}{2}'));assert.ok(serialized.includes('#pdf='+id));
 assert.ok(json.content?.some(n=>n.type==='blockMath'));assert.ok(json.content?.some(n=>n.type==='table'));
});
test('formatted study plans preserve original dates, actions and repetitions',()=>{
 const formatted=examplePlan.replace(/^([12]\. 10\.\d+)$/gm,'## $1').replace(/^(기하광학|파동광학|정전기학|축전기 & 전기회로)$/gm,'### $1');
 const parsed=parsePlan(planningText(formatted),new Date('2026-10-05'));
 assert.equal(parsed.tasks.length,22);assert.equal(parsed.tasks.reduce((n,t)=>n+t.repetitions,0),25);
});
test('attachment URLs remain owner-resolved and source properties remain intact',()=>{
 assert.equal(attachmentID('/api/files/'+id+'#pdf='+id),id);assert.equal(sourcePDFID('/api/files/'+id+'#pdf='+id),id);
 assert.equal(attachmentID('https://evil.test/'+id),null);assert.equal(safeLink('javascript:alert(1)'),false);
 assert.equal(splitFrontmatter('---\ncustom: preserved\n---\n## 본문').prefix,'---\ncustom: preserved\n---\n');
 assert.equal(hasUnsupportedMarkdown('> [!note] 원본 메모'),true);
});
test('slash insertion accepts Korean and English aliases without intercepting dates or URLs',()=>{
 assert.equal(slashQuery('/표'),'표');assert.equal(filterNoteCommands('표')[0].id,'table');
 assert.equal(filterNoteCommands('PDF')[0].id,'noteAttach');assert.equal(filterNoteCommands('h2')[0].value,'2');
 for(const text of ['10/14','https://ravil.example/path','값 / 2','본문 /table'])assert.equal(slashQuery(text),null);
});
