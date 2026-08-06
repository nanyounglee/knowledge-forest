#Requires -Version 5.1
<#
    publish.ps1 - 지식의 숲 요약 노트 공개 배포 스크립트

    사내용 원본 HTML(원문 링크 포함)을 공개용으로 변환해
    GitHub Pages 저장소에 커밋/푸시하고 빌드 결과까지 확인합니다.

    사용법
      .\publish.ps1                                  기본 원본으로 배포
      .\publish.ps1 -DryRun                          변환 결과만 확인 (커밋/푸시 안 함)
      .\publish.ps1 -Message "4회차 추가"             커밋 메시지 지정
      .\publish.ps1 -Source "D:\other.html"          다른 원본 사용

    하는 일
      1. 원본을 읽어 모바일 보정 / description 메타가 없으면 채움
      2. daybar 날짜를 모아 푸터 오른쪽 문구를 자동 생성
      3. 푸터의 구글 문서 링크 제거
      4. 사내 링크가 남아 있으면 중단 (그 외 외부 링크는 경고만)
      5. index.html 갱신 -> 커밋 -> 푸시
      6. Pages 빌드 완료까지 대기 후 실제 응답 검증
#>
[CmdletBinding()]
param(
    [string]$Source  = "C:\Users\user\Downloads\knowledge_forest_day1-3.html",
    [string]$RepoDir = $PSScriptRoot,
    [string]$Message,
    [string]$Description = "지식의 숲 강연 요약 - 의사결정·경영철학·전략·리더십·지식기록·조직과 지속가능성, 그리고 MECE·PEST·3C·P&Q 논리 프레임워크의 핵심 개념 정리",
    [switch]$DryRun,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$LF       = [char]10
$Utf8     = New-Object System.Text.UTF8Encoding($false)
$SiteUrl  = "https://nanyounglee.github.io/knowledge-forest/"
$PagesApi = "repos/nanyounglee/knowledge-forest/pages"

# 여기 걸리는 도메인이 결과물에 남아 있으면 배포를 중단합니다.
$InternalHosts = @(
    'docs\.google\.com', 'drive\.google\.com', 'sheets\.google\.com',
    'sharepoint\.com', 'notion\.so', 'atlassian\.net', 'sincerely\.one'
)

function Step($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "   $m" }
function Good($m) { Write-Host "   [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [!]  $m" -ForegroundColor Yellow }
function Halt($m) { Write-Host "   [중단] $m" -ForegroundColor Red }


# ─── 1. 원본 읽기 ────────────────────────────────────────────────
Step "원본 읽기"
if (-not (Test-Path -LiteralPath $Source)) {
    Halt "원본을 찾을 수 없습니다: $Source"
    exit 1
}
$html = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)
Info "$Source"
Info ("{0:N1} KB" -f ($html.Length / 1KB))


# ─── 2. 공개용 변환 ──────────────────────────────────────────────
Step "공개용 변환"

# 2-1. 좁은 화면에서 표가 가로로 넘치지 않도록
if ($html -notmatch 'td\.k\{white-space:normal') {
    $mobile = "$LF  @media (max-width:640px){$LF" +
              "    .page{padding:24px 18px 32px;}$LF" +
              "    td.k{white-space:normal;}$LF  }$LF$LF"
    if ($html.Contains($LF + "  @page{")) {
        $html = $html.Replace($LF + "  @page{", $mobile + "  @page{")
        Info "모바일 표 보정 추가"
    } else {
        Warn "@page 블록을 찾지 못해 모바일 보정을 건너뜁니다"
    }
}

# 2-2. 검색결과 요약용 description
if ($html -notmatch 'name="description"') {
    $vp = '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
    if ($html.Contains($vp)) {
        $desc = '<meta name="description" content="' + $Description + '">'
        $html = $html.Replace($vp, $vp + $LF + $desc)
        Info "description 메타 추가"
    }
}

# 2-3. daybar 날짜를 모아 푸터 오른쪽 문구 생성 (첫 회차만 연도 표기)
$dates = @([regex]::Matches($html, 'class="dmeta">([^<]+)<') |
           ForEach-Object { $_.Groups[1].Value.Trim() })
$footerRight = ""
if ($dates.Count -gt 0) {
    $parts = @()
    $year  = if ($dates[0].Length -ge 4) { $dates[0].Substring(0, 4) } else { "" }
    foreach ($d in $dates) {
        if ($parts.Count -gt 0 -and $year -and $d.StartsWith("$year.")) {
            $parts += $d.Substring(5)
        } else {
            $parts += $d
        }
    }
    $footerRight = $parts -join ' &middot; '
    Info "회차 $($dates.Count)건 -> 푸터: $footerRight"
} else {
    Warn "daybar 날짜를 찾지 못했습니다 (푸터 오른쪽을 비웁니다)"
}

# 2-4. 푸터의 사내 문서 링크 제거
$linksBefore = ([regex]::Matches($html, 'href="http')).Count
$replacement = "<span>$footerRight</span>"
$html = [regex]::Replace($html,
    '(?s)<span>\s*<a href="https://docs\.google\.com.*?</span>', $replacement)
# 본문에 흩어진 구글 문서 링크가 있으면 텍스트만 남기고 앵커 제거
$html = [regex]::Replace($html,
    '<a href="https?://docs\.google\.com[^"]*"[^>]*>(.*?)</a>', '$1')
$linksAfter = ([regex]::Matches($html, 'href="http')).Count
Info "외부 링크 $($linksBefore)개 -> $($linksAfter)개"


# ─── 3. 공개 안전 점검 ───────────────────────────────────────────
Step "공개 안전 점검"
$urls = @([regex]::Matches($html, 'href="(https?://[^"]+)"') |
          ForEach-Object { $_.Groups[1].Value })
$pattern  = ($InternalHosts -join '|')
$leftover = @($urls | Where-Object { $_ -match $pattern })

if ($leftover.Count -gt 0) {
    Halt "사내 링크가 남아 있어 배포하지 않습니다."
    $leftover | ForEach-Object { Info $_ }
    Info ""
    Info "원본에서 해당 링크를 지우거나, publish.ps1 의 정규식을 보완한 뒤 다시 실행하세요."
    exit 1
}
Good "사내 링크 없음"

if ($urls.Count -gt 0) {
    Warn "아래 외부 링크는 공개 페이지에 그대로 노출됩니다:"
    $urls | Select-Object -Unique | ForEach-Object { Info $_ }
} else {
    Good "외부 링크 없음"
}


# ─── 4. 변경 여부 확인 ───────────────────────────────────────────
Step "변경 여부 확인"
$target = Join-Path $RepoDir "index.html"
$old = if (Test-Path -LiteralPath $target) {
    [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
} else { "" }

if ($old -eq $html) {
    Good "이전 배포본과 동일합니다. 배포할 내용이 없습니다."
    exit 0
}
Info "변경 감지: $($old.Length) -> $($html.Length) 자"

if ($DryRun) {
    $preview = Join-Path $env:TEMP "knowledge-forest-preview.html"
    [System.IO.File]::WriteAllText($preview, $html, $Utf8)
    Step "DryRun - 배포하지 않았습니다"
    Info "미리보기: $preview"
    exit 0
}

[System.IO.File]::WriteAllText($target, $html, $Utf8)
Good "index.html 갱신"


# ─── 5. 커밋 & 푸시 ──────────────────────────────────────────────
Step "커밋 & 푸시"
if (-not $Message) {
    $Message = "요약 노트 갱신 ($(Get-Date -Format 'yyyy-MM-dd'))"
}

git -C $RepoDir add index.html
if ($LASTEXITCODE -ne 0) { Halt "git add 실패"; exit 1 }

git -C $RepoDir commit -m $Message
if ($LASTEXITCODE -ne 0) { Halt "git commit 실패"; exit 1 }

git -C $RepoDir push
if ($LASTEXITCODE -ne 0) { Halt "git push 실패 - 'gh auth login' 상태를 확인하세요"; exit 1 }
Good "푸시 완료: $Message"


# ─── 6. 빌드 확인 ────────────────────────────────────────────────
if ($SkipVerify) {
    Step "완료"
    Info $SiteUrl
    exit 0
}

Step "Pages 빌드 확인"
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) {
    $fallback = "C:\Program Files\GitHub CLI\gh.exe"
    if (Test-Path $fallback) { $gh = $fallback }
}

if ($gh) {
    for ($i = 1; $i -le 24; $i++) {
        $status = & $gh api $PagesApi --jq '.status' 2>$null
        Info "[$i] $status"
        if ($status -eq 'built') { break }
        if ($status -eq 'errored') { Halt "Pages 빌드 실패"; exit 1 }
        Start-Sleep -Seconds 10
    }
} else {
    Warn "gh CLI를 찾지 못해 빌드 상태 조회를 건너뜁니다"
    Start-Sleep -Seconds 45
}

try {
    $bust = $SiteUrl + "?cb=" + (Get-Random)
    $res = Invoke-WebRequest -Uri $bust -UseBasicParsing -TimeoutSec 30
    Good "HTTP $($res.StatusCode) / $([math]::Round($res.RawContentLength/1KB,1)) KB"
    if ($res.Content -match '<title>(.*?)</title>') { Info "타이틀: $($Matches[1])" }
    $liveLinks = ([regex]::Matches($res.Content, 'href="http')).Count
    if ($liveLinks -eq 0) { Good "라이브 외부 링크 0개" }
    else { Warn "라이브 외부 링크 $($liveLinks)개" }
} catch {
    Warn "응답 확인 실패 (빌드 반영에 1~2분 더 걸릴 수 있습니다): $($_.Exception.Message)"
}

Step "완료"
Info $SiteUrl
