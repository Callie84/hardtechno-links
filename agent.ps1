#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root       = 'C:\HardtechnoAgent'
$EnvFile    = Join-Path $Root '.env'
$LinksFile  = Join-Path $Root 'links.md'
$ArtistsFile= Join-Path $Root 'config\artists.txt'
$SourcesFile= Join-Path $Root 'config\sources.txt'
$LogFile    = Join-Path $Root 'logs\agent.log'
$RepoRemote = 'origin'
$RepoBranch = 'main'

function Load-DotEnv($path){
  if(-not(Test-Path $path)){ return @{} }
  $out=@{}
  Get-Content $path | ForEach-Object {
    if($_ -match '^(?<k>[^#=]+)=(?<v>.*)$'){
      $out[$Matches.k.Trim()]=$Matches.v.Trim()
    }
  }
  $out
}

function Write-Log($msg){
  $ts=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Add-Content -Path $LogFile -Value "[$ts] $msg"
}

function Get-Http($url){
  try{
    (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content
  }catch{
    Write-Log "HTTP-Fehler: $url :: $($_.Exception.Message)"
    $null
  }
}

function Extract-Links($html,[string]$filterPattern){
  if(-not $html){ return @() }
  $urls=[System.Collections.Generic.List[string]]::new()
  foreach($m in [regex]::Matches($html,'(?i)href=\"(https?://[^\" >]+)\"')){
    $u=$m.Groups[1].Value
    if($filterPattern -and ($u -notmatch $filterPattern)){ continue }
    if($u -match '\.(m3u8|m3u|zip|rar)$'){ continue }
    if(-not $urls.Contains($u)){ $urls.Add($u) }
  }
  $urls
}

function Add-Links-ToMarkdown([string]$section,[string[]]$links){
  if(-not $links -or $links.Count -eq 0){ return 0 }
  $md = if(Test-Path $LinksFile){ Get-Content $LinksFile -Raw } else { '' }
  if($md -notmatch "(?ms)^##\s+$([regex]::Escape($section))$"){
    $md += "`r`n## $section`r`n"
  }
  $existing = [regex]::Matches($md,'(?im)https?://\S+') | ForEach-Object { $_.Value.Trim() } | Sort-Object -Unique
  $new = @()
  foreach($l in $links){ if($existing -notcontains $l){ $new += $l } }
  if($new.Count -gt 0){
    $block = ("`r`n" + ($new | ForEach-Object { "- $_" }) -join "`r`n") + "`r`n"
    $md = $md + $block
    if($md -match '\*Zuletzt aktualisiert:\*'){
      $md = [regex]::Replace($md,'(?ms)\*Zuletzt aktualisiert:\*.*$',"*Zuletzt aktualisiert:* $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    } else {
      $md += "`r`n*Zuletzt aktualisiert:* $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }
    Set-Content -Encoding UTF8 $LinksFile -Value $md
  }
  $new.Count
}

function Git-CommitPush([string]$message){
  git add $LinksFile 2>$null | Out-Null
  $status = git status --porcelain
  if([string]::IsNullOrWhiteSpace($status)){ return $false }
  git commit -m $message | Out-Null
  git push $RepoRemote $RepoBranch | Out-Null
  $true
}

function Notify-Discord([string]$webhook,[string]$text){
  if([string]::IsNullOrWhiteSpace($webhook)){ return }
  $payload = @{ content = $text } | ConvertTo-Json
  try{
    Invoke-RestMethod -Uri $webhook -Method Post -Body $payload -ContentType 'application/json' | Out-Null
  }catch{
    Write-Log "Discord-Notify Fehler: $($_.Exception.Message)"
  }
}

# ==== Lauf ====
New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
Write-Log "Start Agent"

$envs = Load-DotEnv $EnvFile
$DISCORD_WEBHOOK = $envs['DISCORD_WEBHOOK']

if(-not (Test-Path $LinksFile)){ throw "links.md fehlt: $LinksFile" }

$allNew=0

# a) Quellen
$sources = Get-Content $SourcesFile | Where-Object { $_ -and -not $_.StartsWith('#') }
foreach($s in $sources){
  $html = Get-Http $s
  $lnks = Extract-Links $html '' | Where-Object { $_ -match '(soundcloud|mixcloud|youtube|archive)' }
  $allNew += Add-Links-ToMarkdown 'Auto-Funde' $lnks
  Start-Sleep -Milliseconds 400
}

# b) Künstler-Suche über Google
$artists = Get-Content $ArtistsFile | Where-Object { $_ -and -not $_.StartsWith('#') }
foreach($a in $artists){
  $q   = [uri]::EscapeDataString("$a live set schranz hardtechno")
  $url = "https://www.google.com/search?q=$q"
  $html= Get-Http $url
  $lnks= Extract-Links $html '' | Where-Object { $_ -match '(soundcloud|mixcloud|youtube|archive)' }
  $allNew += Add-Links-ToMarkdown $a $lnks
  Start-Sleep -Milliseconds 800
}

$didPush = Git-CommitPush ("Auto: +{0} neue Links" -f $allNew)
if($didPush){
  Notify-Discord $DISCORD_WEBHOOK (":zap: Hardtechno-Agent: {0} neue Links gepusht." -f $allNew)
} else {
  Write-Log "Keine Änderungen"
}
Write-Log "Ende Agent"
