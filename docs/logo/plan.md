# 로고 보강 계획

README 맨 위에 pr-quorum 로고를 넣는 계획이다. 영문 README PR(#12 `docs/english-docs`)이 머지된 뒤 별도 PR 로 낸다.

2026-10-23 에 원격 저장소(`thswlsqls/pr-quorum`)와 `feat/english` 브랜치를 읽고, GitHub 트렌딩 저장소 49곳의 README 머리를 조사해 정했다. 트렌딩은 2026-10-23 하루 기준이다. 같은 날 계획서를 근거·컨셉·기술 정확성·실행성 네 축으로 검증해 고친 판이다.

## 1. 원칙

- **SVG 두 벌과 README 머리만 바꾼다.** README 에서 부르지 않는 파일은 만들지 않는다.
- **SVG 를 저장소 안에 둔다.** 텍스트라서 diff 로 리뷰할 수 있다. 기존 캡처처럼 `assets/` 아래 상대 경로로 부른다.
- **다크·라이트 두 벌을 둔다.** 단색 로고는 한쪽 테마에서 묻힌다.
- **실행 캡처(`assets/pr34-*.png`)는 건드리지 않는다.**

## 2. 현재 상태

| 항목 | 상태 |
|---|---|
| README 머리 | `# pr-quorum` 텍스트 H1 으로 바로 시작한다. 로고·배지 없음. `#pr-quorum` 앵커를 거는 문서는 없다 |
| `assets/` | `pr34-review-summary.png`, `pr34-inline-comment.png` 두 장 |
| Release | 없다. 태그 `pr-quorum--v0.1.0`, `pr-quorum--v0.1.1` 만 있다 |

## 3. 조사 결과

트렌딩 49곳(daily 9, weekly·monthly 12, TS·Python weekly 와 AI 개발도구 15, Go·Rust·Java weekly 와 JS monthly 및 리뷰 도구 19, 중복 6 제외) 중 31곳이 README 상단에 로고를 둔다. 목록은 부록에 있다.

| 유형 | 수 |
|---|---|
| 심볼+워드마크 | 9 |
| 가로 배너 | 8 |
| 워드마크만 | 5 |
| 아이콘만 (64–170px) | 5 |
| 마스코트 | 4 |

- 31곳 중 28곳이 가운데 정렬이다. 로고 아래에는 태그라인이나 배지가 온다. 그 사이에 H1 을 두는 곳도 있다(bun, ollama).
- 크기는 조합 로고·워드마크 150–480px, 아이콘 64–170px 이다. kafka(50%)·engram·uzu(100%)는 폭을 비율로 준다.
- 다크모드를 처리한 곳은 10/31 이다. 9곳이 `<picture>` + `prefers-color-scheme`, supabase 한 곳이 `#gh-dark-mode-only` 를 쓴다.
- 유형 순위는 심볼+워드마크 9, 배너 8 로 차이가 작다. 유형은 추세가 아니라 제품 성격으로 고른다.
- 플러그인·스킬 모음 7곳(claude-plugins-official, knowledge-work-plugins, cursor/plugins, wshobson/agents, vercel-labs/skills, addyosmani/agent-skills, cloudflare/security-audit-skill)은 모두 로고가 없다.
- 조사한 리뷰 도구 5곳은 로봇 얼굴(pr-agent, cline), 개 마스코트(reviewdog), 워드마크(danger-js, aider)를 쓴다. 판정·투표·정족수를 그린 로고는 49곳 중 없었다.

## 4. 컨셉

pr-quorum 은 **서로 결과를 보지 않는 심사 4개가 축을 나눠 보고, 게이트를 모두 통과해야 머지된다**. 이름의 quorum 은 비유이고 투표 집계는 없다(README, `rules/` 에 vote·majority 가 없다). 그래서 투표나 다수결로 읽히는 그림은 피한다.

| 시안 | 형태 | 판단 |
|---|---|---|
| **A. 점 4개와 게이트 (채택)** | 같은 크기 점 4개가 세로로 서고, 오른쪽에 세로 막대 하나가 떨어져 선다. 점과 막대는 선으로 잇지 않는다 | 독립 심사 4개와 그 뒤의 게이트가 드러난다. 점 넷이 모두 같아 켜짐·꺼짐이 없고, 단색에서도 깨지지 않는다 |
| B. 투표 집계 | 집계 표시에 머지 화살표를 합친 모양 | 투표로 읽혀 실제 동작과 어긋난다 |
| C. 게이지 | 반원 위험도 게이지와 바늘 | 리스크 게이트만 보이고 리뷰 단계가 빠진다 |
| D. 워드마크만 | `pr-quorum` 글자만 | 가장 싸고 안 깨진다. A 가 너비 240 에서 메뉴 아이콘으로 읽히거나 점이 뭉치면 이걸로 간다 |

- GitHub 의 git-merge·pull-request 옥티콘, 세로 점 메뉴(⋮)와 닮지 않게 한다. 점을 선으로 잇지 않고, 시안마다 이 아이콘들 옆에 두고 비교한다.
- 피할 것: 로봇 얼굴, `{ }`, 방패, 체크, 눈, 판사봉.

## 5. 산출물

| 파일 | 내용 |
|---|---|
| `assets/logo-light.svg` | 라이트 테마용. 심볼 A + 워드마크 `pr-quorum` |
| `assets/logo-dark.svg` | 다크 테마용. 같은 도형, 색만 바꾼다 |

SVG 규칙:
- 단색 하나로 그린다. 라이트 `#1f2328`, 다크 `#f0f6fc` 를 기본으로 하고 소유자가 확정한다.
- 심볼 높이 32 기준으로 점 지름 5 이상, 점 간격 3 이상으로 그린다.
- 막대 폭은 점 지름 이상, 점과의 간격은 점 간격의 2배 이상으로 둔다. 막대 높이는 점 4개를 세운 높이와 같게 맞춘다. 막대가 점보다 얇거나 짧으면 줄였을 때 흐려지거나 따로 떨어진 선으로 읽힌다.
- 글자는 처음부터 `<path>` 로 그린다. `<text>` 는 보는 사람 시스템 폰트로 바뀌어 모양이 달라진다.
- `<script>`, 외부 참조(`href`, `url()`, `@import`), `data:` 이미지·폰트를 넣지 않는다. GitHub 는 SVG 를 고치지 않지만 `<img>` 로 띄우고 raw.githubusercontent.com 이 `Content-Security-Policy: default-src 'none'` 을 붙여서 안 보인다.
- `npx svgo assets/logo-light.svg assets/logo-dark.svg` 로 메타데이터를 지운다.

## 6. README 변경

`# pr-quorum` H1 을 아래로 바꾼다.

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="pr-quorum" width="240">
  </picture>
</p>
```

- H1 을 빼면 `#pr-quorum` 앵커와 문서 첫 제목이 없어진다. 거는 문서가 없어 그대로 뺀다. `alt` 는 이미지 이름만 남긴다.
- 태그라인·배지는 넣지 않는다. 바로 아래 README 첫 문단이 설명을 맡고, Release 가 없어 release 배지는 `no releases or repo not found` 로 찍힌다.

## 7. 순서

1. #12 를 먼저 머지한다. README 머리가 겹친다.
2. `main` 에서 `docs/logo` 브랜치를 판다. 커밋은 `docs : [docs/logo] …` 꼴이다.
3. Claude 가 시안 A 로 SVG 초안 2–3개를 쓰고 소유자가 심볼과 워드마크 글자 모양을 함께 하나로 고른다. §4 의 D 조건에 걸리면 D 로 간다.
4. 다크·라이트 두 벌을 만들고 §5 의 svgo 명령으로 정리한다.
5. README 머리를 §6 대로 바꾼다.
6. PR 을 올리고 §8 을 마친 뒤 머지한다. 문서만 바뀌므로 `plugin.json` 의 `version` 과 `CHANGELOG.md` 는 건드리지 않는다. `.claude-plugin/` 을 건드리면 하네스 신호 15점이 붙어 `medium` 이 된다.

## 8. 확인

- [ ] 브랜치 README 를 GitHub 라이트·다크 테마로 각각 열어 로고가 보인다 (Settings → Appearance 에서 바꾼다)
- [ ] 시안을 git-merge 옥티콘·⋮ 메뉴 옆에 두고 봐도 닮지 않았다. 소유자가 판단한다
- [ ] `grep -nE '<(text|script|image|foreignObject)|href=|url\(|@import' assets/logo-*.svg` 가 비어 있다
- [ ] `gh pr diff <번호> --name-only` 에 `README.md`, `assets/logo-*.svg`, `docs/logo/plan.md` 만 나온다. 모두 `scripts/risk.jq:5` 의 문서 패턴이라 리스크 점수표가 0점 `low` 다 (`rules/03-risk.md:29`)

## 하지 않을 것

- 심볼 단독 SVG, 파비콘. GitHub 저장소에는 파비콘 자리가 없다.
- Social preview PNG. 필요해지면 따로 한다. GitHub 기준은 PNG·JPG·GIF 1 MB 이하, 최소 640×320, 권장 1280×640 이다.
- 배지, 태그라인, topics, `plugin.json` 의 `keywords` 수정.
- 애니메이션 GIF·가로 배너·마스코트.
- Inkscape 설치. 글자를 처음부터 경로로 그려 필요 없다.

## 부록. 조사 저장소

로고 있음 31곳. 가운데 정렬이 아닌 곳은 †, 다크모드 처리는 ◐.

| 유형 | 저장소 |
|---|---|
| 심볼+워드마크 | supabase ◐, fastapi, php-src, graphify, claude-howto † ◐, qodo-ai/pr-agent ◐, OpenHands, ai-memory ◐, apache/kafka ◐ |
| 가로 배너 | ruflo, paperclip, hindsight, NVIDIA/OpenShell † ◐, ECC, continue, engram, trymirai/uzu |
| 워드마크만 | opencode ◐, aider, taste-skill ◐, ghidra †, danger-js |
| 아이콘만 | orca, CLI-Anything, cline, bun, HMCL |
| 마스코트 | ponytail ◐, ollama, LocalAI, reviewdog ◐ |

로고 없음 18곳: knowledge-work-plugins, cloudflare/security-audit-skill, PCL, ComfyUI, claude-plugins-official, t3code, impeccable, vercel-labs/skills, cursor/plugins, wshobson/agents, context-mode, pentagi, gitleaks, etcd, gitea, googleworkspace/cli, addyosmani/agent-skills, Apktool.
