# Shared helpers. Dot-source only. ASCII only (Windows PowerShell 5.1 safe).
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppRoot = Split-Path -Parent $PSScriptRoot

function Say  ($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# ---------- config: config.psd1 + optional config.local.psd1 (not in git) ----------
$Cfg = Import-PowerShellDataFile (Join-Path $AppRoot 'config.psd1')
$localCfg = Join-Path $AppRoot 'config.local.psd1'
if (Test-Path $localCfg) {
    $o = Import-PowerShellDataFile $localCfg
    foreach ($k in $o.Keys) { $Cfg[$k] = $o[$k] }
}

$Root  = $Cfg.InstallRoot
$Paths = @{
    App       = Join-Path $Root 'app'
    Bin       = Join-Path $Root 'llama.cpp'
    Models    = Join-Path $Root 'models'
    ModelDir  = Join-Path (Join-Path $Root 'models') $Cfg.ModelFolder
    WebUI     = Join-Path $Root 'webui'
    WebUIData = Join-Path (Join-Path $Root 'webui') 'data'
    Secrets   = Join-Path $Root 'secrets'
    Logs      = Join-Path $Root 'logs'
    Downloads = Join-Path $Root 'downloads'
    Run       = Join-Path $Root 'run'
    State     = Join-Path $Root 'state.json'
}

# PS 5.1: with EAP=Stop, redirecting stderr of a native exe throws. Run natives through this.
function Invoke-Native ([scriptblock]$sb) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $sb } finally { $ErrorActionPreference = $old }
}

function Ensure-Dir ($d) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

# ---------- state (what install.ps1 actually set up) ----------
function Get-State {
    if (Test-Path $Paths.State) { return (Get-Content $Paths.State -Raw | ConvertFrom-Json) }
    return $null
}
function Save-State ($h) {
    Ensure-Dir $Root
    ($h | ConvertTo-Json -Depth 5) | Set-Content -Path $Paths.State -Encoding ASCII
}

# ---------- secrets ----------
function Get-MySid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

# Owner + SYSTEM + Administrators only. SIDs, so it works on localized Windows.
function Protect-Path ($p) {
    $sid = Get-MySid
    & icacls.exe $p /inheritance:r /grant:r "*${sid}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
}
function Protect-File ($p) {
    $sid = Get-MySid
    & icacls.exe $p /inheritance:r /grant:r "*${sid}:F" "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
}

function New-Secret ([int]$bytes = 32) {
    $b = New-Object byte[] $bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($b); $rng.Dispose()
    ($b | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-SecretFile ($name) {
    Ensure-Dir $Paths.Secrets
    Protect-Path $Paths.Secrets
    $f = Join-Path $Paths.Secrets "$name.txt"
    if (-not (Test-Path $f)) { [IO.File]::WriteAllText($f, (New-Secret)) }
    return $f
}
function Get-Secret ($name) { ([IO.File]::ReadAllText((Get-SecretFile $name))).Trim() }

# Optional HF token for gated/private repos: env HF_TOKEN or C:\llama\secrets\hf_token.txt
# Passed to curl via header file, so it never shows up in the process list.
function Get-HfAuthArgs {
    $tokFile = Join-Path $Paths.Secrets 'hf_token.txt'
    $tok = $env:HF_TOKEN
    if (-not $tok -and (Test-Path $tokFile)) { $tok = ([IO.File]::ReadAllText($tokFile)).Trim() }
    if (-not $tok) { return @() }
    Ensure-Dir $Paths.Secrets; Protect-Path $Paths.Secrets
    $hdr = Join-Path $Paths.Secrets 'hf_header.txt'
    [IO.File]::WriteAllText($hdr, "Authorization: Bearer $tok`r`n")
    return @('-H', "@$hdr")
}

# ---------- downloads (curl.exe ships with Windows 11) ----------
function Get-CurlExe {
    $c = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $c) { return $c }
    $g = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    Die 'curl.exe not found (should be in C:\Windows\System32 on Windows 11)'
}

function Test-Sha256 ($file, $sha) {
    if (-not $sha) { return $true }
    $marker = "$file.sha256"
    if ((Test-Path $marker) -and (([IO.File]::ReadAllText($marker)).Trim() -eq $sha)) { return $true }
    Say "SHA256 check: $(Split-Path $file -Leaf) ..."
    $h = (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower()
    if ($h -eq $sha) { [IO.File]::WriteAllText($marker, $sha); return $true }
    Warn "SHA256 mismatch: got $h expected $sha"
    return $false
}

# Resumable download with retries. Interrupted? Just run install.bat again.
function Invoke-Download ($url, $dest, $sha = $null, $extraArgs = @(), $expectedSize = 0) {
    $curl = Get-CurlExe
    if (Test-Path $dest) {
        if (Test-Sha256 $dest $sha) { Ok "Already here: $(Split-Path $dest -Leaf)"; return }
        Remove-Item $dest -Force; Remove-Item "$dest.sha256" -Force -ErrorAction SilentlyContinue
    }
    Ensure-Dir (Split-Path $dest -Parent)
    $part = "$dest.part"
    if ($expectedSize -gt 0 -and (Test-Path $part) -and ((Get-Item $part).Length -eq $expectedSize)) {
        Say 'Partial file is already complete'
    } else {
        Say "Downloading $(Split-Path $dest -Leaf)"
        $a = @('-L', '--fail', '--retry', '10', '--retry-delay', '5', '--retry-all-errors',
               '--connect-timeout', '30', '-C', '-', '-A', 'windows-heretic-webui', '-o', $part) + $extraArgs + @($url)
        & $curl @a
        if ($LASTEXITCODE -ne 0) {
            if (-not ($expectedSize -gt 0 -and (Test-Path $part) -and ((Get-Item $part).Length -eq $expectedSize))) {
                Die "Download failed (curl exit $LASTEXITCODE). Run install.bat again, it resumes."
            }
        }
    }
    if (-not (Test-Sha256 $part $sha)) {
        Remove-Item $part -Force
        Die 'Downloaded file is corrupted, removed. Run install.bat again.'
    }
    if ($sha) { Move-Item "$part.sha256" "$dest.sha256" -Force }
    Move-Item $part $dest -Force
    Ok "Saved $dest"
}

# HF LFS files: HEAD on /resolve/ (no redirect follow) returns x-linked-etag (sha256) and x-linked-size
function Get-HfFileMeta ($url, $authArgs) {
    $curl = Get-CurlExe
    $a = @('-sS', '-I', '--max-time', '30', '-A', 'windows-heretic-webui') + $authArgs + @($url)
    $hdr = Invoke-Native { & $curl @a 2>$null }
    $meta = @{ Sha = $null; Size = 0; Status = '' }
    foreach ($line in $hdr) {
        if ($line -match '^HTTP/\S+\s+(\d+)') { $meta.Status = $Matches[1] }
        if ($line -match '^(?i)x-linked-etag:\s*"?([0-9a-f]{64})"?') { $meta.Sha = $Matches[1].ToLower() }
        if ($line -match '^(?i)x-linked-size:\s*(\d+)') { $meta.Size = [int64]$Matches[1] }
    }
    return $meta
}

# ---------- probes ----------
function Test-HttpOk ($url) {
    $curl = Get-CurlExe
    $code = Invoke-Native { & $curl -s -o NUL -w '%{http_code}' --noproxy '*' --max-time 3 $url 2>$null }
    return ($code -eq '200')
}

function Add-DockerToPath {
    $d = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
    if ((Test-Path $d) -and ($env:Path -notlike "*$d*")) { $env:Path = "$d;$env:Path" }
}
function Test-DockerUp {
    Add-DockerToPath
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    Invoke-Native { & docker info --format '{{.ServerVersion}}' *> $null }
    return ($LASTEXITCODE -eq 0)
}
function Start-DockerDesktop ([int]$timeoutSec = 240) {
    if (Test-DockerUp) { return $true }
    $dd = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path $dd)) { return $false }
    Say 'Starting Docker Desktop (first start can take a couple of minutes)...'
    Start-Process -FilePath $dd | Out-Null
    $t = 0
    while ($t -lt $timeoutSec) {
        Start-Sleep -Seconds 3; $t += 3
        if (Test-DockerUp) { Ok 'Docker engine is up'; return $true }
    }
    return $false
}

function Add-UvToPath {
    $d = Join-Path $env:USERPROFILE '.local\bin'
    if ($env:Path -notlike "*$d*") { $env:Path = "$d;$env:Path" }
    $w = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    if ((Test-Path $w) -and ($env:Path -notlike "*$w*")) { $env:Path = "$w;$env:Path" }
}

function Get-Mode {
    $s = Get-State
    if ($s -and $s.Mode) { return $s.Mode }
    return $Cfg.WebUIMode
}

# Quote one argument for Start-Process -ArgumentList string (PS 5.1 does not quote arrays)
function Quote-Arg ($a) {
    $s = [string]$a
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}
