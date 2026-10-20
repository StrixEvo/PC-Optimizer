# Turns PCOptimizer.ps1 into PCOptimizer.exe with ps2exe. Needs internet once, to get the ps2exe tool.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $PSCommandPath
$ps1 = Join-Path $dir 'PCOptimizer.ps1'
$exe = Join-Path $dir 'PCOptimizer.exe'
$pin = '1.0.18'      # pinned so every build uses the same compiler

if (-not (Get-Module -ListAvailable -Name ps2exe | Where-Object { $_.Version -eq [version]$pin })) {
    Write-Host "Installing ps2exe $pin ..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module ps2exe -RequiredVersion $pin -Scope CurrentUser -Force
}
Import-Module ps2exe -RequiredVersion $pin

$txt = Get-Content -LiteralPath $ps1 -Raw
if ($txt -match "AppVersion = '([\d\.]+)'") { $ver = $Matches[1] } else { throw 'Could not find AppVersion in PCOptimizer.ps1' }
$fileVer = ($ver.Split('.') + @('0', '0', '0', '0') | Select-Object -First 4) -join '.'

if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
# -DPIAware: crisp on scaled displays. -supportOS: Windows 10/11 manifest. Version info gives antivirus something to read.
Invoke-ps2exe -inputFile $ps1 -outputFile $exe -noConsole -requireAdmin -STA -DPIAware -supportOS `
    -title 'PC Optimizer' -product 'PC Optimizer' -company 'Strix' -copyright 'MIT License' -version $fileVer | Out-Null

if (-not (Test-Path -LiteralPath $exe)) { throw 'Build failed: PCOptimizer.exe was not created.' }
Write-Host "Built PCOptimizer.exe ($ver, $((Get-Item $exe).Length) bytes)"
