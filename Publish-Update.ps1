# Builds, signs and publishes a new version. Raise AppVersion in PCOptimizer.ps1 first.
# Order matters: the exe goes up as a GitHub Release first, version.json is pushed last. Friends only
# learn about a version after its download exists.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $PSCommandPath
Set-Location -LiteralPath $dir

function Stop-Here([string]$msg) { Write-Host ''; Write-Host $msg -ForegroundColor Red; Write-Host 'Nothing was published.' -ForegroundColor Red; exit 1 }
function Run([scriptblock]$b, [string]$what) { & $b; if ($LASTEXITCODE -ne 0) { Stop-Here "$what failed." } }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Stop-Here 'The GitHub CLI (gh) is needed: https://cli.github.com' }
Run { git pull --ff-only } 'Syncing with GitHub (git pull)'

$notes = (Read-Host 'What changed? (one line)').Trim()
if (-not $notes) { Stop-Here 'You need to type what changed.' }
[IO.File]::WriteAllText((Join-Path $dir 'release-notes.txt'), $notes + "`n", (New-Object Text.UTF8Encoding($false)))

try { & (Join-Path $dir 'Build-Exe.ps1') } catch { Stop-Here "Build failed: $_" }
try { & (Join-Path $dir 'Make-Release.ps1') } catch { Stop-Here "$_" }

$info = Get-Content -LiteralPath (Join-Path $dir 'version.json') -Raw | ConvertFrom-Json
$tag = 'v' + $info.version
$body = "$notes`n`nSHA256 of PCOptimizer.exe:`n$($info.exeSha256)"
Run { gh release create $tag (Join-Path $dir 'PCOptimizer.exe') --title "PC Optimizer $($info.version)" --notes $body } 'Creating the GitHub release'

Run { git add PCOptimizer.ps1 version.json SHA256SUMS.txt release-notes.txt } 'git add'
Run { git commit -m $notes } 'git commit'
Run { git push } 'git push'

Write-Host ''
Write-Host "Done. Version $($info.version) is live. Friends are offered it next time they open the app." -ForegroundColor Green
