import test from 'node:test';
import assert from 'node:assert/strict';
import {renderAnalysisPanel} from '../src/workspace/analysis-view.ts';
import type {Entity} from '../src/workspace/domain.ts';

const source:Entity={id:'record-a',kind:'record',revision:1,deleted:false,updatedAt:'2026-10-19',payload:{title:'내 <기록>',body:'원문',subjectIDs:[],projectIDs:[],fileIDs:[],tags:['수동']}};
test('AI help offers organization and questions before classifying a record',()=>{
 const html=renderAnalysisPanel(source,[source],false);
 assert.ok(html.includes('AI로 정리'));assert.ok(html.includes('기록에 질문'));assert.ok(!html.includes('과목을 먼저'));
});
test('AI answers and actions show escaped text and only navigate to existing records',()=>{
 const record={...source,payload:{...source.payload,aiAnalysis:{summary:'<script>unsafe</script>',tags:['사진집'],question:'다음에는?',answer:'견적을 비교한다.',answerEvidenceIDs:[source.id],sources:[{id:source.id,title:source.payload.title,kind:'record',updatedAt:source.updatedAt}],suggestions:[{text:'인쇄 견적 비교',evidenceIDs:[source.id]}],connections:[],generatedAt:'2026-10-19',stale:false}}};
 const html=renderAnalysisPanel(record,[record],false,'<질문>');
 assert.ok(html.includes('&lt;script&gt;unsafe&lt;/script&gt;'));assert.ok(!html.includes('<script>'));
 assert.ok(html.includes('data-source="record-a"'));assert.ok(html.includes('value="&lt;질문&gt;"'));
 const actions=renderAnalysisPanel(record,[record],false,'','actions');
 assert.ok(actions.includes('할 일로 추가'));assert.ok(actions.includes('data-ai-task="0"'));
 const removed=renderAnalysisPanel(record,[],false);assert.ok(!removed.includes('data-source="record-a"'));
});
test('stale analysis remains inspectable without offering old suggestions as current actions',()=>{
 const record={...source,payload:{...source.payload,aiAnalysis:{summary:'이전 요약',stale:true,suggestions:[{text:'오래된 제안',evidenceIDs:[source.id]}]}}};
 const html=renderAnalysisPanel(record,[record],false);
 assert.ok(html.includes('이전 AI 결과'));assert.ok(html.includes('이전 요약'));assert.ok(!html.includes('data-ai-task='));
});
