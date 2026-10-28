import type {Entity} from './domain.ts';
import {getRecordAnalysis, type AnalysisSource} from './second-brain.ts';

const h = (value: unknown) => String(value ?? '').replace(/[&<>"']/g, character => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[character]!));
export type ContextTab = 'summary' | 'connections' | 'actions';

export function renderAnalysisPanel(record: Entity | undefined, entities: Entity[], busy: boolean, question = '', tab: ContextTab = 'summary', renderIcon: (name:string)=>string = () => ''): string {
    const icon=renderIcon;
    const payload = record?.payload, analysis = payload && getRecordAnalysis(payload);
    const sources = new Map<string, AnalysisSource>((analysis?.sources || []).map(source => [source.id, source]));
    const evidence = (ids: string[]) => '<span class="brain-evidence">' + [...new Set(ids)].map(id => {
        const source = sources.get(id), entity = entities.find(item => item.id === id && !item.deleted);
        const recordID = entity?.kind === 'record' ? entity.id : entity?.payload.recordID || source?.recordID;
        const target = entities.find(item => item.id === recordID && item.kind === 'record' && !item.deleted);
        const title = target?.payload.title || source?.title || '근거 기록';
        return target ? '<button type="button" data-source="' + h(target.id) + '">' + icon('file') + '<span>' + h(title) + '</span>' + icon('right') + '</button>' : '<span>' + h(source?.title || '근거 기록 없음') + '</span>';
    }).join('') + '</span>';
    const disabled = busy ? ' disabled' : '';
    let result = '';
    if (analysis) {
        const summary = (analysis.summary ? '<div class="brain-summary"><h3>핵심 정리</h3><p>' + h(analysis.summary) + '</p>' + (record ? evidence([record.id]) : '') + '</div>' : '<p class="brain-empty-text">저장된 요약이 없습니다.</p>') +
            (analysis.tags?.length ? '<div class="brain-tags"><span>' + analysis.tags.map(tag => h('#' + tag)).join(' ') + '</span><button type="button" data-ai-tags="true" data-ai-record="' + h(record?.id) + '"' + disabled + '>태그 반영</button></div>' : '');
        const connections = analysis.connections?.length ? '<div class="brain-connections"><h3>이어지는 기록</h3>' + analysis.connections.map(connection => '<article><p>' + h(connection.reason) + '</p>' + evidence([connection.recordID]) + '</article>').join('') + '</div>' : '<p class="brain-empty-text">근거가 확인된 연결이 아직 없습니다.</p>';
        const actions = analysis.suggestions?.length ? '<div class="brain-suggestions"><h3>다음 행동 제안</h3>' + analysis.suggestions.map((suggestion, index) => '<article><div><p>' + h(suggestion.text) + '</p>' + evidence(suggestion.evidenceIDs) + '</div><button type="button" data-ai-task="' + index + '" data-ai-record="' + h(record?.id) + '" data-analysis-at="' + h(analysis.generatedAt) + '"' + disabled + '>' + icon('plus') + '할 일로 추가</button></article>').join('') + '</div>' : '<p class="brain-empty-text">추가할 행동 제안이 없습니다.</p>';
        result = (analysis.question ? '<div class="brain-answer"><h3>' + h(analysis.question) + '</h3><p>' + h(analysis.answer) + '</p>' + evidence(analysis.answerEvidenceIDs || []) + '</div>' : '') + (tab === 'summary' ? summary : tab === 'connections' ? connections : actions);
    } else if (payload?.aiAnalysis?.stale) {
        result = '<div class="brain-stale" role="status">' + icon('link') + '<p>기록이 바뀌었습니다.<br />현재 원문으로 다시 정리해 주세요.</p></div><details class="brain-previous"><summary>이전 AI 결과</summary><p>' + h(payload.aiAnalysis.summary) + '</p>' + (payload.aiAnalysis.answer ? '<p>' + h(payload.aiAnalysis.answer) + '</p>' : '') + '</details>';
    } else {
        result = '<div class="brain-empty">' + icon('sparkle') + '<h3>기록에서 시작하는 도움</h3><p>핵심을 정리하고, 이어지는 기록과<br />해볼 일을 찾아보세요.</p></div>' + (payload?.summary ? '<details class="brain-previous"><summary>이전에 저장한 AI 정리</summary><p>' + h(payload.summary) + '</p></details>' : '');
    }
    return '<section id="record-ai" class="brain-panel" aria-label="기록을 바탕으로 한 AI 도움"><header><div><span class="brain-provider">' + icon('sparkle') + ' RAVIL AI</span><h2>기록에서 찾은 맥락</h2></div><button type="button" class="desk-icon" data-action="togglePlan" data-mobile-context aria-label="AI 맥락 닫기">' + icon('close') + '</button></header>' +
        '<div class="brain-tabs" role="tablist" aria-label="AI 맥락">' + ([['summary', '정리'], ['connections', '연결'], ['actions', '다음 행동']] as const).map(([id, label]) => '<button type="button" role="tab" data-context-tab="' + id + '" aria-selected="' + (tab === id) + '" aria-controls="brain-content" id="brain-tab-' + id + '">' + label + (id === 'connections' && analysis?.connections?.length ? '<span>' + analysis.connections.length + '</span>' : '') + '</button>').join('') + '</div>' +
        '<div class="brain-scroll"><div id="brain-content" role="tabpanel" aria-labelledby="brain-tab-' + tab + '">' + result + '</div><button type="button" class="brain-organize" data-action="analyze"' + disabled + '>' + icon('sparkle') + (busy ? '정리하는 중…' : analysis ? '다시 정리' : 'AI로 정리') + '</button></div>' +
        '<form id="record-question-form" class="brain-question"><label for="record-question">내 기록에 질문</label><div><input id="record-question" name="question" maxlength="2000" required placeholder="이 기록에서 이어서 생각해 볼까?" value="' + h(question) + '"' + disabled + ' /><button type="submit" aria-label="질문하기" title="질문하기"' + disabled + '>' + icon('up') + '</button></div><p>답변의 근거를 원문에서 확인하세요.</p></form></section>';
}
