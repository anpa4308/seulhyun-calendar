# KBO 공식 일정(koreabaseball.com)에서 KIA 타이거즈 경기를 모아 games.json으로 저장한다.
# GitHub Actions(pwsh)에서 매일 실행되며, Windows PowerShell 5.1에서도 돌아간다.
param([string]$Out = (Join-Path $PSScriptRoot 'games.json'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Team = 'KIA'
$Codes = @{ 'LG' = 'LG'; '한화' = 'HH'; 'SSG' = 'SK'; '삼성' = 'SS'; 'NC' = 'NC'; 'KT' = 'KT'; '롯데' = 'LT'; 'KIA' = 'HT'; '두산' = 'OB'; '키움' = 'WO' }
$Rounds = @{ 'WC' = '와일드카드'; '준PO' = '준플레이오프'; 'PO' = '플레이오프'; 'KS' = '한국시리즈' }
$NextRound = @{ 'WC' = '준PO'; '준PO' = 'PO'; 'PO' = 'KS' }
$WinsNeeded = @{ '준PO' = 3; 'PO' = 3; 'KS' = 4 }

$kst = [DateTime]::UtcNow.AddHours(9)
$season = $kst.Year

function Get-Rows([string]$srIdList, [int]$month) {
  $res = Invoke-WebRequest -UseBasicParsing -Method Post `
    -Uri 'https://www.koreabaseball.com/ws/Schedule.asmx/GetScheduleList' `
    -Headers @{ Referer = 'https://www.koreabaseball.com/Schedule/Schedule.aspx' } `
    -Body @{ leId = '1'; srIdList = $srIdList; seasonId = "$season"; gameMonth = ('{0:D2}' -f $month); teamId = 'HT' }
  $text = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
  @(($text | ConvertFrom-Json).rows)
}

function Strip([string]$html) { ([regex]::Replace("$html", '<[^>]+>', '')).Trim() }

# 1) 정규시즌 + 포스트시즌 전체 행을 파싱
$all = New-Object System.Collections.ArrayList
foreach ($kind in @(@{ sr = '0,9,6'; post = $false }, @{ sr = '3,4,5,7'; post = $true })) {
  foreach ($m in 3..11) {
    $date = $null
    foreach ($r in (Get-Rows $kind.sr $m)) {
      $cells = @($r.row)
      $dayCell = $cells | Where-Object { $_.Class -eq 'day' } | Select-Object -First 1
      if ($dayCell) {
        $md = [regex]::Match($dayCell.Text, '(\d{2})\.(\d{2})')
        $date = '{0}-{1}-{2}' -f $season, $md.Groups[1].Value, $md.Groups[2].Value
      }
      $play = $cells | Where-Object { $_.Class -eq 'play' } | Select-Object -First 1
      if (-not $play -or -not $date) { continue }

      # 팀 이름 안에 <br/>이 들어가는 경우가 있다 (예: 준PO<br/>승리팀)
      $p = [regex]::Match($play.Text, '^<span>(.*?)</span><em>(.*)</em><span>(.*?)</span>$')
      if (-not $p.Success) { continue }
      $scores = @([regex]::Matches($p.Groups[2].Value, '<span[^>]*>(\d+)</span>') | ForEach-Object { [int]$_.Groups[1].Value })
      $label = Strip $cells[-1].Text
      if ($label -eq '-') { $label = '' }

      [void]$all.Add([pscustomobject]@{
        date = $date
        time = Strip (($cells | Where-Object { $_.Class -eq 'time' } | Select-Object -First 1).Text)
        away = Strip $p.Groups[1].Value
        home = Strip $p.Groups[3].Value
        awayScore = if ($scores.Count -eq 2) { $scores[0] } else { $null }
        homeScore = if ($scores.Count -eq 2) { $scores[1] } else { $null }
        park = Strip $cells[-2].Text
        label = $label
        post = $kind.post
        round = $null
        placeholder = $null
      })
    }
  }
}

# 2) 포스트시즌 라운드 판별: "준PO 3차전" 같은 라벨, 없으면 "준PO승리팀" 자리표시로 다음 라운드를 추론
foreach ($g in $all | Where-Object { $_.post }) {
  foreach ($side in @($g.away, $g.home)) {
    if ($side -match '^(.+)승리팀$') { $g.placeholder = $side; $g.round = $NextRound[$Matches[1]] }
  }
  if ($g.label -match '^(WC|준PO|PO|KS) ') { $g.round = $Matches[1] }
}

$kiaPost = @($all | Where-Object { $_.post -and ($_.away -eq $Team -or $_.home -eq $Team) })

function Get-SeriesWins([string]$round) {
  $kia = 0; $opp = 0
  foreach ($g in $kiaPost | Where-Object { $_.round -eq $round -and $null -ne $_.awayScore }) {
    $k = if ($g.away -eq $Team) { $g.awayScore } else { $g.homeScore }
    $o = if ($g.away -eq $Team) { $g.homeScore } else { $g.awayScore }
    if ($k -gt $o) { $kia++ } elseif ($o -gt $k) { $opp++ }
  }
  @{ kia = $kia; opp = $opp }
}

function Test-SeriesOver([string]$round) {
  if (-not $WinsNeeded.ContainsKey($round)) { return $false }
  $w = Get-SeriesWins $round
  ($w.kia -ge $WinsNeeded[$round]) -or ($w.opp -ge $WinsNeeded[$round])
}

# KIA가 해당 라운드에 있거나, 아직 올라갈 가능성이 남아 있는지
function Test-Alive([string]$round, [int]$depth = 0) {
  if ($depth -gt 4 -or -not $round) { return $false }
  if ($kiaPost | Where-Object { $_.round -eq $round }) {
    if (-not $WinsNeeded.ContainsKey($round)) { return $true }
    $w = Get-SeriesWins $round
    return $w.opp -lt $WinsNeeded[$round]
  }
  $ph = $all | Where-Object { $_.post -and $_.round -eq $round -and $_.placeholder } | Select-Object -First 1
  if ($ph) { return (Test-Alive ($ph.placeholder -replace '승리팀$', '') ($depth + 1)) }
  return $false
}

# 3) KIA 경기만 골라 출력 형태로 변환
$games = [ordered]@{}
foreach ($g in $all) {
  $isKia = $g.away -eq $Team -or $g.home -eq $Team
  $prevRound = if ($g.placeholder) { $g.placeholder -replace '승리팀$', '' } else { $null }
  $viaPlaceholder = (-not $isKia) -and $g.placeholder -and (Test-Alive $prevRound)
  if (-not $isKia -and -not $viaPlaceholder) { continue }

  $kiaHome = if ($isKia) { $g.home -eq $Team } else { $g.home -eq $g.placeholder }
  $opp = if ($kiaHome) { $g.away } else { $g.home }
  $played = $null -ne $g.awayScore
  $conds = @()

  $stage = '정규시즌'
  if ($g.post) {
    $sameRound = @($all | Where-Object { $_.post -and $_.round -eq $g.round } | Sort-Object date)
    $num = if ($g.label -match '(\d+)차전') { [int]$Matches[1] } else { [array]::IndexOf(@($sameRound | ForEach-Object date), $g.date) + 1 }
    $stage = '{0} {1}차전' -f $Rounds[$g.round], $num
    if ($viaPlaceholder) { $conds += "$prevRound 승리 시" }
    if (-not $played -and $WinsNeeded.ContainsKey($g.round)) {
      if ($isKia -and (Test-SeriesOver $g.round)) { continue }   # 시리즈가 끝나 열리지 않는 경기
      if ($num -gt $WinsNeeded[$g.round]) { $conds += '필요 시' }
    }
  }

  $item = [ordered]@{
    stage = $stage
    opp = $opp
    oppCode = $Codes[$opp]
    home = $kiaHome
    park = if ($kiaHome -and $g.park -eq '미정') { '광주' } else { $g.park }
    time = $g.time
  }
  if ($conds.Count) { $item.maybe = $conds -join ' · ' }
  if ($played) {
    $item.kia = if ($kiaHome) { $g.homeScore } else { $g.awayScore }
    $item.oppScore = if ($kiaHome) { $g.awayScore } else { $g.homeScore }
  }
  if ($g.label -match '취소|순연|서스펜디드') { $item.note = $g.label }

  if (-not $games.Contains($g.date)) { $games[$g.date] = @() }
  $games[$g.date] += , $item
}

# 4) 일정 내용이 바뀌었을 때만 저장 (매시간 돌아도 변화 없으면 커밋·배포하지 않음)
$gamesJson = $games | ConvertTo-Json -Depth 5 -Compress
$sha = [Security.Cryptography.SHA256]::Create()
$hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($gamesJson)) | ForEach-Object { $_.ToString('x2') })

$oldHash = $null
if (Test-Path $Out) {
  try { $oldHash = ([IO.File]::ReadAllText($Out, [Text.Encoding]::UTF8) | ConvertFrom-Json).hash } catch { }
}
$changed = $hash -ne $oldHash
if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "changed=$($changed.ToString().ToLower())" }

if (-not $changed) {
  Write-Host "No schedule changes ($($games.Count) game days)"
  return
}

$result = [ordered]@{
  updated = $kst.ToString('yyyy-MM-dd HH:mm')
  season = $season
  hash = $hash
  games = $games
}
$json = $result | ConvertTo-Json -Depth 6 -Compress
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Saved $($games.Count) game days to $Out (updated $($result.updated) KST)"
