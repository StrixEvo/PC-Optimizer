# Writes version.json (version, hashes, notes, signature) and SHA256SUMS.txt for the freshly built PCOptimizer.exe.
# Put what changed in release-notes.txt (plain English, one line) before running.
# Signs with the private key in %USERPROFILE%\pcoptimizer-signing-key.xml. That key never goes in the repository.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $PSCommandPath
$ps1 = Join-Path $dir 'PCOptimizer.ps1'
$exe = Join-Path $dir 'PCOptimizer.exe'
$keyFile = Join-Path $env:USERPROFILE 'pcoptimizer-signing-key.xml'

$txt = Get-Content -LiteralPath $ps1 -Raw
if ($txt -match "AppVersion = '([\d\.]+)'") { $ver = $Matches[1] } else { throw 'Could not find AppVersion in PCOptimizer.ps1' }
if (-not (Test-Path -LiteralPath $exe)) { throw 'PCOptimizer.exe not found. Run Build-PCOptimizer-Exe.bat first.' }
if (-not (Test-Path -LiteralPath $keyFile)) { throw "Signing key not found at $keyFile. Without it no update can be published." }
if ((Get-Item -LiteralPath $exe).LastWriteTime -lt (Get-Item -LiteralPath $ps1).LastWriteTime) {
    throw 'PCOptimizer.exe is older than PCOptimizer.ps1. Rebuild the exe so it contains your latest edit.'
}

$hash = (Get-FileHash -LiteralPath $ps1 -Algorithm SHA256).Hash
$exeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$notes = ''
$nf = Join-Path $dir 'release-notes.txt'
if (Test-Path -LiteralPath $nf) { $notes = (Get-Content -LiteralPath $nf -Raw).Trim() }

# A changed script with an unchanged version number would never be offered to anyone: refuse it
$vj = Join-Path $dir 'version.json'
if (Test-Path -LiteralPath $vj) {
    $prev = $null
    try { $prev = (Get-Content -LiteralPath $vj -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { }
    if ($prev -and $prev.sha256 -ne $hash -and [version]$ver -le [version][string]$prev.version) {
        throw "PCOptimizer.ps1 changed but AppVersion is still $ver. Raise it, rebuild, then run this again."
    }
}

# Same payload the app rebuilds in Get-InfoPayload: version | script hash | exe hash | hash of the notes
$sha = New-Object System.Security.Cryptography.SHA256Managed
$notesHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($notes))).Replace('-', '')
$payload = "$ver|$hash|$exeHash|$notesHash"
$k = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$k.FromXmlString((Get-Content -LiteralPath $keyFile -Raw))
$sig = [Convert]::ToBase64String($k.SignData([Text.Encoding]::UTF8.GetBytes($payload), 'SHA256'))

# Check the signature against the public key that is built into the app, so a key mix-up is caught here
if ($txt -match "UpdateKey = '(<RSAKeyValue>.*?</RSAKeyValue>)'") {
    $v = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $v.FromXmlString($Matches[1])
    if (-not $v.VerifyData([Text.Encoding]::UTF8.GetBytes($payload), 'SHA256', [Convert]::FromBase64String($sig))) {
        throw 'The signature does not verify against the public key inside PCOptimizer.ps1. Wrong signing key?'
    }
} else { throw 'Could not find UpdateKey in PCOptimizer.ps1' }

$obj = [ordered]@{ version = $ver; sha256 = $hash; exeSha256 = $exeHash; notes = $notes; sig = $sig }
[IO.File]::WriteAllText($vj, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS.txt'), "$exeHash  PCOptimizer.exe`n", (New-Object Text.ASCIIEncoding))

Write-Host "Version $ver"
Write-Host "PCOptimizer.exe  $exeHash"
Write-Host 'version.json signed and verified, SHA256SUMS.txt written.'
