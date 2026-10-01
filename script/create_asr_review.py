#!/usr/bin/env python3
"""Create an offline review sheet for locally transcribed Ravil lecture clips."""

import argparse
import html
import json
import os
from pathlib import Path


def predictions(path: Path) -> dict[str, str]:
    report = json.loads(path.read_text(encoding="utf-8"))
    return {row["id"]: row.get("prediction", "") for row in report["items"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--whisper", type=Path, required=True)
    parser.add_argument("--qwen06", type=Path, required=True)
    parser.add_argument("--qwen17", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rows = json.loads(args.manifest.read_text(encoding="utf-8"))
    reports = {"Whisper Turbo": predictions(args.whisper),
               "Qwen3-ASR 0.6B": predictions(args.qwen06),
               "Qwen3-ASR 1.7B": predictions(args.qwen17)}
    if not rows or any(row["lecture_id"] not in report for report in reports.values() for row in rows):
        parser.error("every clip needs a prediction from each model")
    if any(Path(row["audio_path"]).parent.resolve() != args.output.parent.resolve() for row in rows):
        parser.error("review page must be beside its local audio clips")

    cards = []
    for row in rows:
        identifier = html.escape(row["lecture_id"], quote=True)
        source = html.escape(Path(row["audio_path"]).name, quote=True)
        candidate_html = "".join(
            f'<div class="candidate"><strong>{html.escape(name)}</strong>'
            f'<p>{html.escape(report[row["lecture_id"]])}</p></div>'
            for name, report in reports.items())
        if "weak_alt_reference" in row:
            candidate_html += (
                '<div class="candidate alt"><strong>기존 Alt 전사 · 정답 아님</strong>'
                f'<p>{html.escape(row["weak_alt_reference"])}</p></div>')
        cards.append(
            f'<section class="clip" data-id="{identifier}" '
            f'data-audio="{html.escape(row["audio_path"], quote=True)}" '
            f'data-language="{html.escape(row["language"], quote=True)}" '
            f'data-subject="{html.escape(row["subject"], quote=True)}">'
            f'<header><span>0{len(cards)+1}</span><h2>{html.escape(row["subject"])} · 20초</h2></header>'
            f'<audio controls preload="metadata" src="{source}"></audio>'
            f'<div class="candidates">{candidate_html}</div>'
            '<label>직접 듣고 확인한 정확한 문장'
            '<textarea spellcheck="false" placeholder="모델 출력이 아니라 들린 말을 적어 주세요."></textarea>'
            '</label></section>')
    markup = "\n".join(cards)
    page = f'''<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ravil-ASMR · 음성 정답 검수</title>
<style>
:root{{font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;color-scheme:light;background:#f7f7f5;color:#171717}}
*{{box-sizing:border-box}}body{{margin:0}}main{{max-width:960px;margin:0 auto;padding:48px 28px 96px}}
h1{{font-size:34px;letter-spacing:-.04em;margin:0 0 12px}}.intro{{color:#555;line-height:1.65;margin:0 0 36px}}
.clip{{background:white;border:1px solid #deded9;border-radius:15px;padding:26px;margin:24px 0}}
header{{display:flex;align-items:baseline;gap:14px}}header span{{color:#767676;font-size:13px;font-weight:700}}
h2{{font-size:22px;margin:0 0 20px}}audio{{width:100%;margin-bottom:23px}}
.candidates{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-bottom:22px}}
.candidate{{border:1px solid #e7e7e3;border-radius:10px;padding:15px 17px;min-height:96px}}
.candidate strong{{font-size:12px;color:#666}}.candidate p{{line-height:1.55;margin:8px 0 0;white-space:pre-wrap;overflow-wrap:anywhere}}
.candidate.alt{{background:#faf9f3}}label{{display:block;font-size:13px;font-weight:650}}
textarea{{display:block;width:100%;min-height:94px;margin-top:9px;padding:12px 14px;font-family:inherit;font-size:16px;line-height:1.5;border:1px solid #bcbcb7;border-radius:9px;resize:vertical}}
button{{border:0;background:#171717;color:white;padding:13px 19px;border-radius:9px;font-family:inherit;font-size:14px;font-weight:600;cursor:pointer}}
.footer{{color:#666;font-size:13px;line-height:1.6}}
@media(max-width:680px){{main{{padding:28px 16px 70px}}.candidates{{grid-template-columns:1fr}}.clip{{padding:18px}}}}
</style></head><body><main>
<h1>Ravil-ASMR 음성 정답 검수</h1>
<p class="intro">녹음과 세 모델의 전사를 비교해 들린 문장을 직접 적어 주세요. Alt 결과도 정답으로 취급하지 않습니다. 이 페이지는 로컬 파일만 읽고 서버로 전송하지 않습니다.</p>
{markup}
<button id="export">검수한 문장 JSONL 다운로드</button>
<p class="footer">빈 칸은 제외합니다. 생성된 파일에는 오디오의 로컬 절대 경로가 담기므로 외부에 공유하지 마세요. 검수 전 모델 출력은 학습 정답으로 쓰지 않습니다.</p>
</main><script>
document.getElementById('export').addEventListener('click',()=>{{
  const rows=[...document.querySelectorAll('.clip')].map(el=>({{
    id:el.dataset.id,audio_path:el.dataset.audio,reference:el.querySelector('textarea').value.trim(),
    language:el.dataset.language,subject:el.dataset.subject,split:'eval',
    rights_reference:'user-authorized local audio; human-reviewed transcript'
  }})).filter(row=>row.reference);
  if(!rows.length){{alert('먼저 한 문장 이상 검수해 주세요.');return;}}
  const blob=new Blob([rows.map(row=>JSON.stringify(row)).join('\\n')+'\\n'],{{type:'application/x-ndjson'}});
  const link=document.createElement('a');link.href=URL.createObjectURL(blob);
  link.download='ravil-asmr-reviewed-labels.jsonl';link.click();
  setTimeout(()=>URL.revokeObjectURL(link.href),1000);
}});
</script></body></html>'''
    os.umask(0o077)
    args.output.write_text(page, encoding="utf-8")
    args.output.chmod(0o600)
    print(json.dumps({"clips": len(rows), "output": str(args.output.resolve())}, ensure_ascii=False))


if __name__ == "__main__":
    main()
