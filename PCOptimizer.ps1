#Requires -Version 5.1
<#
  PC Optimizer - macOS-style glass UI
  Tabs: Tune-Up | Dashboard | Services | Startup | Apps | Cleaner | Gaming | Privacy | Windows Update | Repair | Presets and Log
  Everything is reversible:
    Services -> original startup types saved, "Restore originals"
    Startup  -> uses Windows' own StartupApproved flags (same as Task Manager), just toggle back on
    Cleaner  -> only deletes caches / temp files, shows sizes first
    Gaming   -> original power plan and Game Mode values saved, "Restore normal"
#>

[CmdletBinding()]
param([switch]$ShowConsole)

$script:ShowConsole = [bool]$ShowConsole
# A -noConsole exe shows Write-Progress and warnings in popup windows, and progress also slows downloads in PS 5.1
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
function Say([string]$t, [string]$color = 'Gray') { if ($script:ShowConsole) { Write-Host $t -ForegroundColor $color } }

# Any startup error: log it and show a popup (the console is hidden)
trap {
    try {
        $d = Join-Path $env:ProgramData 'PCOptimizer'
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
        Add-Content -Path (Join-Path $d 'error.log') -Value ("[{0}] startup: {1}" -f (Get-Date), ($_ | Out-String))
    } catch { }
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(("PC Optimizer hit an error:`n`n" + ($_ | Out-String)), 'PC Optimizer', 'OK', 'Error')
    } catch { }
    break
}

# ---- Self-elevate to Administrator, run in STA (console hidden unless -ShowConsole) ----
$winStyle = if ($ShowConsole) { 'Normal' } else { 'Hidden' }
$noExit = if ($ShowConsole) { '-NoExit' } else { '' }
$passOn = if ($ShowConsole) { '-ShowConsole' } else { '' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -WindowStyle $winStyle -ArgumentList "-NoProfile -STA $noExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" $passOn"
    exit
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process powershell -WindowStyle $winStyle -ArgumentList "-NoProfile -STA $noExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" $passOn"
    exit
}

Say 'PC Optimizer starting...' 'Cyan'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Say 'WPF loaded'

# ---- Native glass helper (Windows 11 acrylic, Windows 10 acrylic fallback) ----
if (-not ('Glass' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Glass {
  [StructLayout(LayoutKind.Sequential)] struct MARGINS { public int L; public int R; public int T; public int B; }
  [StructLayout(LayoutKind.Sequential)] struct ACCENT { public int State; public int Flags; public int Color; public int AnimId; }
  [StructLayout(LayoutKind.Sequential)] struct WCAD { public int Attr; public IntPtr Data; public int Size; }
  [StructLayout(LayoutKind.Sequential)] struct SHQUERYRBININFO { public int cbSize; public long i64Size; public long i64NumItems; }
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
  [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
  [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr h, ref WCAD d);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHQueryRecycleBin(string root, ref SHQUERYRBININFO info);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHEmptyRecycleBin(IntPtr hwnd, string root, uint flags);
  public static long BinSize() {
    SHQUERYRBININFO i = new SHQUERYRBININFO();
    i.cbSize = Marshal.SizeOf(i);
    int r = SHQueryRecycleBin(null, ref i);
    if (r != 0) return 0;
    return i.i64Size;
  }
  public static int EmptyBin() { return SHEmptyRecycleBin(IntPtr.Zero, null, 7); }
  public static int Backdrop(IntPtr h, int t) { int v = t; return DwmSetWindowAttribute(h, 38, ref v, 4); }
  public static void Dark(IntPtr h, bool on) { int v = on ? 1 : 0; DwmSetWindowAttribute(h, 20, ref v, 4); }
  public static void Round(IntPtr h) { int v = 2; DwmSetWindowAttribute(h, 33, ref v, 4); }
  public static void Extend(IntPtr h, int n) {
    MARGINS m = new MARGINS(); m.L = n; m.R = n; m.T = n; m.B = n;
    DwmExtendFrameIntoClientArea(h, ref m);
  }
  public static void Acrylic(IntPtr h, int a, int r, int g, int b) {
    ACCENT ac = new ACCENT();
    ac.State = 4; ac.Flags = 2; ac.Color = (a << 24) | (b << 16) | (g << 8) | r; ac.AnimId = 0;
    int size = Marshal.SizeOf(ac);
    IntPtr p = Marshal.AllocHGlobal(size);
    Marshal.StructureToPtr(ac, p, false);
    WCAD d = new WCAD(); d.Attr = 19; d.Data = p; d.Size = size;
    SetWindowCompositionAttribute(h, ref d);
    Marshal.FreeHGlobal(p);
  }
}
'@
}

# ---- Window drag at the Windows level (works even if WPF mouse events do not) ----
try {
    if (-not ('CaptionHook' -as [type])) {
        Add-Type -ReferencedAssemblies 'PresentationCore', 'WindowsBase' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;
public static class CaptionHook {
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L; public int T; public int R; public int B; }
  [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetStyle(IntPtr h, int i);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetStyle(IntPtr h, int i, IntPtr v);
  // Borderless windows need the min/max/resize style bits for Windows to snap them to screen edges and quadrants.
  public static void EnableSnap(IntPtr h) {
    long st = GetStyle(h, -16).ToInt64();
    SetStyle(h, -16, new IntPtr(st | 0x00010000L | 0x00020000L | 0x00040000L));
  }
  static double sc = 1.0;
  static HwndSourceHook hook;
  static IntPtr Proc(IntPtr hwnd, int msg, IntPtr wp, IntPtr lp, ref bool handled) {
    if (msg == 0x84) {
      long l = lp.ToInt64();
      POINT p; p.X = (short)(l & 0xFFFF); p.Y = (short)((l >> 16) & 0xFFFF);
      ScreenToClient(hwnd, ref p);
      RECT r; GetClientRect(hwnd, out r);
      double x = p.X / sc, y = p.Y / sc, w = (r.R - r.L) / sc;
      if (x < 6 || x > w - 6 || y < 6) return IntPtr.Zero;
      bool side = (x < 220 && y < 56 && !(x < 90 && y > 14 && y < 42));
      bool main = (x >= 220 && y < 70 && x < w - 260);
      if (side || main) { handled = true; return (IntPtr)2; }
    }
    return IntPtr.Zero;
  }
  public static void Install(IntPtr h, double scale) {
    sc = scale > 0 ? scale : 1.0;
    HwndSource src = HwndSource.FromHwnd(h);
    hook = new HwndSourceHook(Proc);
    src.AddHook(hook);
  }
}
'@
    }
} catch { }

Say 'Glass helper ready'
# ---- Paths ----
$script:DataDir = Join-Path $env:ProgramData 'PCOptimizer'
$script:BackupFile = Join-Path $script:DataDir 'service-backup.json'
$script:GameFile = Join-Path $script:DataDir 'gaming-backup.json'
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir | Out-Null }
# This app runs as administrator and executes files from this folder, so a standard user must not be able to write here.
# SIDs (not names) so it works on any Windows language: SYSTEM + Administrators full control, Users read-only.
try { & icacls.exe $script:DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null } catch { }
# Drop anything executable that was already in the folder (could have been planted before the lock-down)
foreach ($pat in @('*.cmd', '*.bat', '*.exe', '*.new*')) { Get-ChildItem -LiteralPath $script:DataDir -Filter $pat -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
$script:UiFile = Join-Path $script:DataDir 'ui-settings.json'

# ---- Service catalogue ----
$script:Catalogue = @(
    @{ N='DiagTrack';        C='Safe';     D='Telemetry: sends usage data to Microsoft' },
    @{ N='dmwappushservice'; C='Safe';     D='WAP Push message routing (telemetry helper)' },
    @{ N='MapsBroker';       C='Safe';     D='Downloaded Maps Manager (offline maps)' },
    @{ N='Fax';              C='Safe';     D='Fax service' },
    @{ N='RetailDemo';       C='Safe';     D='Retail demo mode (store display PCs)' },
    @{ N='WMPNetworkSvc';    C='Safe';     D='Windows Media Player network sharing' },
    @{ N='WerSvc';           C='Safe';     D='Windows Error Reporting' },
    @{ N='RemoteRegistry';   C='Safe';     D='Lets remote users edit your registry (security risk)' },
    @{ N='lfsvc';            C='Optional'; D='Location (apps asking where you are, Find my device, automatic time zone)' },
    @{ N='WpcMonSvc';        C='Optional'; D='Parental Controls / Family Safety. Do not switch off on a child''s PC' },
    @{ N='PhoneSvc';         C='Optional'; D='Phone Link calls and texts' },
    @{ N='SmsRouter';        C='Optional'; D='Phone Link text messages' },
    @{ N='icssvc';           C='Optional'; D='Mobile hotspot (sharing this PC''s internet)' },
    @{ N='XblAuthManager';   C='Optional'; D='Xbox Live sign-in (needed for Xbox app / Game Pass)' },
    @{ N='XblGameSave';      C='Optional'; D='Xbox cloud saves' },
    @{ N='XboxNetApiSvc';    C='Optional'; D='Xbox Live networking' },
    @{ N='XboxGipSvc';       C='Optional'; D='Xbox accessories (controllers / headsets)' },
    @{ N='SysMain';          C='Optional'; D='Superfetch: preloads apps, pointless on an SSD' },
    @{ N='WSearch';          C='Optional'; D='Windows Search indexing (file search gets slower)' },
    @{ N='Spooler';          C='Optional'; D='Print Spooler (only if you never print)' },
    @{ N='bthserv';          C='Optional'; D='Bluetooth support (only if you use no Bluetooth)' },
    @{ N='TermService';      C='Optional'; D='Remote Desktop (inbound RDP)' },
    @{ N='WbioSrvc';         C='Optional'; D='Biometrics (Windows Hello fingerprint / face)' },
    @{ N='DoSvc';            C='Optional'; D='Delivery Optimization (update sharing). Never fully disabled: Store downloads need it' },
    @{ N='FrameServer';      C='Optional'; D='Camera Frame Server (webcam sharing between apps)' },
    @{ N='TabletInputService'; C='Optional'; D='Touch keyboard, emoji panel and handwriting. Never fully disabled' },
    @{ N='PcaSvc';           C='Optional'; D='Program Compatibility Assistant' },
    @{ N='SEMgrSvc';         C='Optional'; D='Payments and NFC manager' }
)
# Strict mode sets these to Manual instead of Disabled: disabling them breaks Store downloads / the touch keyboard
$script:NeverDisable = @('DoSvc', 'TabletInputService')

# ---- Cleaner targets ----
$script:CleanTargets = @(
    @{ Name='User temp files';          Desc='Your %TEMP% folder';                                  Paths=@($env:TEMP); Default=$true },
    @{ Name='Windows temp files';       Desc='C:\Windows\Temp';                                     Paths=@("$env:WINDIR\Temp"); Default=$true },
    @{ Name='Windows Update cache';     Desc='Downloaded update files already installed. Update services are paused while it is cleaned'; Paths=@("$env:WINDIR\SoftwareDistribution\Download"); Default=$false; StopSvc=@('wuauserv', 'bits') },
    @{ Name='Crash dumps and reports';  Desc='Minidumps and Windows Error Reporting queues';        Paths=@("$env:LOCALAPPDATA\CrashDumps","$env:WINDIR\Minidump","$env:ProgramData\Microsoft\Windows\WER\ReportQueue","$env:ProgramData\Microsoft\Windows\WER\ReportArchive"); Default=$true },
    @{ Name='Chrome cache';             Desc='Cached web files (close Chrome first)';               Paths=@("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache","$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache"); Default=$true },
    @{ Name='Edge cache';               Desc='Cached web files (close Edge first)';                 Paths=@("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"); Default=$true },
    @{ Name='GPU shader caches';        Desc='DirectX, AMD and NVIDIA caches. Games rebuild them, first load can stutter'; Paths=@("$env:LOCALAPPDATA\D3DSCache","$env:LOCALAPPDATA\AMD\DxCache","$env:LOCALAPPDATA\AMD\DxcCache","$env:LOCALAPPDATA\NVIDIA\DXCache","$env:LOCALAPPDATA\NVIDIA\GLCache"); Default=$false },
    @{ Name='Recycle Bin';              Desc='Permanently empties it. Unticked by default';         Paths=@(); Special='Recycle'; Default=$false }
)

# ---- Startup sources ----
$script:ApprovedBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:StartupRunKeys = @(
    @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';              Approved="HKCU:\$($script:ApprovedBase)\Run";           Scope='User' },
    @{ Path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';              Approved="HKLM:\$($script:ApprovedBase)\Run";           Scope='System' },
    @{ Path='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';  Approved="HKLM:\$($script:ApprovedBase)\Run32";         Scope='System' }
)
$script:StartupFolders = @(
    @{ Dir="$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup";        Approved="HKCU:\$($script:ApprovedBase)\StartupFolder"; Scope='User' },
    @{ Dir="$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp";    Approved="HKLM:\$($script:ApprovedBase)\StartupFolder"; Scope='System' }
)
# "Update" keeps browser updaters (GoogleUpdate, MicrosoftEdgeUpdate...) away from the switch-off lists: they carry security fixes
$script:KeepPattern = 'SecurityHealth|Defender|Windows Security|Realtek|RtkAud|Nahimic|Intel.*(Graphics|Rapid)|Radeon|AMD|NVIDIA|Update'

# ---- State ----
$script:Win = $null
$script:Hwnd = [IntPtr]::Zero
$script:Dark = $false
$script:GlassOk = $false
$script:UseAccent = $false
$script:SvcRows = @()
$script:StartRows = @()
$script:CleanRows = @()
$script:GameRows = @()
$script:AppRows = @()
$script:PkgRows = @()
$script:AppsLoaded = $false
$script:FixLoaded = $false
$script:Baseline = $null
$script:BootSecs = $null
$script:Timer = $null
$script:DashTimer = $null
$script:Gauges = @{}
$script:Stats = $null
$script:BgPs = @()
$script:DashStatic = @{}
$script:NetDownTb = $null
$script:NetUpTb = $null
$script:DashErr = $false

# ============================================================
#  Generic helpers
# ============================================================
function Get-El([string]$name) { return $script:Win.FindName($name) }

function Pump {
    try { $script:Win.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) } catch { }
}

function Set-Status([string]$text) {
    (Get-El 'StatusText').Text = $text
    Pump
}

function Show-Msg([string]$text) {
    [void][System.Windows.MessageBox]::Show($text, 'PC Optimizer', 'OK', 'Information')
}

function Confirm-Msg([string]$text) {
    $r = [System.Windows.MessageBox]::Show($text, 'PC Optimizer', 'YesNo', 'Question')
    return ($r -eq 'Yes')
}

function Write-Log([string]$m) {
    try {
        $f = Join-Path $script:DataDir 'error.log'
        Add-Content -Path $f -Value ("[{0}] {1}" -f (Get-Date), $m)
        if ((Get-Item -LiteralPath $f).Length -gt 512KB) {
            $keep = @(Get-Content -LiteralPath $f -Tail 1000)
            Set-Content -Path $f -Value $keep -Encoding UTF8
        }
    } catch { }
}

# Busy guard. Pump runs a nested message loop, so without this a click (or the update timer) could start a
# second action in the middle of the first. A depth counter, not a flag, because actions legitimately nest
# (Do-ImportPreset -> Ensure-Loaded -> Invoke-Safe).
$script:Depth = 0
function Enter-Busy {
    $script:Depth++
    if ($script:Depth -eq 1) {
        try { (Get-El 'Tint').IsEnabled = $false; $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait } catch { }
    }
}
function Exit-Busy {
    $script:Depth--
    if ($script:Depth -le 0) {
        $script:Depth = 0
        try { (Get-El 'Tint').IsEnabled = $true; $script:Win.Cursor = $null } catch { }
    }
}

function Invoke-Safe([string]$fn) {
    Enter-Busy
    try { & $fn } catch {
        Write-Log ($fn + ': ' + ($_ | Out-String))
        [void][System.Windows.MessageBox]::Show(("Something went wrong:`n`n" + ($_ | Out-String)), 'PC Optimizer', 'OK', 'Error')
    } finally { Exit-Busy }
}

# Run slow work (network, big scans) on another thread. $work must be self-contained: it runs in its own runspace
# and cannot see this script's functions. $done runs back on the UI thread with the result.
# (No .GetNewClosure() here: it rebinds the block to global scope and the script-level functions disappear.)
function Invoke-Background([scriptblock]$work, [scriptblock]$done, $arg) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($work.ToString()).AddArgument($arg)
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(150)
    $t.Tag = @{ Ps = $ps; H = $ps.BeginInvoke(); Done = $done }
    $t.Add_Tick({
        param($s, $e)
        $j = $s.Tag
        if (-not $j.H.IsCompleted) { return }
        $s.Stop()
        try {
            $res = $null
            try { $res = $j.Ps.EndInvoke($j.H) } catch { Write-Log ('background: ' + $_) }
            & $j.Done $res
        } catch { Write-Log ('background done: ' + $_) } finally { $j.Ps.Dispose() }
    })
    $t.Start()
}

# The clipboard throws if another app is holding it, so retry a few times
function Set-ClipboardSafe([string]$text) {
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.Windows.Clipboard]::SetText($text); return $true } catch { Start-Sleep -Milliseconds 80 }
    }
    return $false
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$b B"
}

function New-Header([string]$text) {
    $t = [Security.SecurityElement]::Escape($text)
    $x = "<TextBlock xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" Text=`"$t`" FontSize=`"12`" FontWeight=`"SemiBold`" Margin=`"4,12,0,8`" Foreground=`"{DynamicResource SubTextBrush}`"/>"
    return [System.Windows.Markup.XamlReader]::Parse($x)
}

# One glass card row: title + description on the left, badge, switch on the right
function New-Row {
    param(
        [string]$Title, [string]$Desc, [string]$Badge = '',
        [string]$BadgeBg = '#22808080', [string]$BadgeFg = '#808080',
        [bool]$Checked = $false
    )
    $t = [Security.SecurityElement]::Escape($Title)
    $d = [Security.SecurityElement]::Escape($Desc)
    $b = [Security.SecurityElement]::Escape($Badge)
    $vis = if ($Badge) { 'Visible' } else { 'Collapsed' }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="12" Padding="16,12" Margin="0,0,0,8" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <StackPanel Grid.Column="0" VerticalAlignment="Center">
      <TextBlock Text="$t" FontWeight="SemiBold" FontSize="13.5" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource TextBrush}"/>
      <TextBlock Text="$d" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0" Foreground="{DynamicResource SubTextBrush}"/>
    </StackPanel>
    <Border Grid.Column="1" CornerRadius="6" Padding="8,2" Margin="12,0" VerticalAlignment="Center" Background="$BadgeBg" Visibility="$vis">
      <TextBlock Text="$b" FontSize="11" FontWeight="SemiBold" Foreground="$BadgeFg"/>
    </Border>
    <CheckBox Grid.Column="2" VerticalAlignment="Center"/>
  </Grid>
</Border>
"@
    $border = [System.Windows.Markup.XamlReader]::Parse($x)
    $grid = $border.Child
    $cb = $grid.Children[2]
    $cb.Style = $script:Win.FindResource('Switch')
    $cb.IsChecked = $Checked
    $cb.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, $Title)   # screen readers read the row title
    return [pscustomobject]@{
        Root      = $border
        Check     = $cb
        BadgeText = $grid.Children[1].Child
        DescText  = $grid.Children[0].Children[1]
    }
}

# ============================================================
#  Theme + glass
# ============================================================
function Set-Brush([string]$key, [string]$hex) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $brush = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]$c)
    $script:Win.Resources[$key] = $brush.psobject.BaseObject
}

function Set-Theme([bool]$dark) {
    $script:Dark = $dark
    if ($dark) {
        $p = @{ Text='#F5F5F7'; Sub='#A1A1A6'; Card='#1FFFFFFF'; Border='#1AFFFFFF'; Side='#33000000'; Tint='#4D1C1C1E'; Btn='#1FFFFFFF'; Hover='#1FFFFFFF'; NavSel='#2EFFFFFF' }
        if (-not $script:GlassOk) { $p.Tint='#1C1C1E'; $p.Side='#161618'; $p.Card='#2C2C2E' }
    } else {
        $p = @{ Text='#1D1D1F'; Sub='#6E6E73'; Card='#A6FFFFFF'; Border='#1A000000'; Side='#40FFFFFF'; Tint='#40F2F2F7'; Btn='#12000000'; Hover='#14000000'; NavSel='#1F000000' }
        if (-not $script:GlassOk) { $p.Tint='#F2F2F7'; $p.Side='#E8E8ED'; $p.Card='#FFFFFF' }
    }
    Set-Brush 'TextBrush' $p.Text
    Set-Brush 'SubTextBrush' $p.Sub
    Set-Brush 'CardBrush' $p.Card
    Set-Brush 'CardBorderBrush' $p.Border
    Set-Brush 'SidebarBrush' $p.Side
    Set-Brush 'TintBrush' $p.Tint
    Set-Brush 'ButtonBrush' $p.Btn
    Set-Brush 'HoverBrush' $p.Hover
    Set-Brush 'NavSelBrush' $p.NavSel
    if ($script:Hwnd -ne [IntPtr]::Zero) {
        try { [Glass]::Dark($script:Hwnd, $dark) } catch { }
        if ($script:UseAccent) {
            try {
                if ($dark) { [Glass]::Acrylic($script:Hwnd, 153, 32, 32, 36) } else { [Glass]::Acrylic($script:Hwnd, 153, 245, 245, 247) }
            } catch { }
        }
    }
}

function Initialize-Glass {
    $h = $script:Hwnd
    $build = 0
    try { $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber } catch { }
    $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
    $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
    [Glass]::Extend($h, -1)
    [Glass]::Round($h)
    [Glass]::Dark($h, $script:Dark)
    $ok = $false
    if ($build -ge 22621) {
        if ([Glass]::Backdrop($h, 3) -ge 0) { $ok = $true }
    }
    if (-not $ok) {
        try { [Glass]::Acrylic($h, 153, 245, 245, 247); $ok = $true; $script:UseAccent = $true } catch { }
    }
    if (-not $ok) {
        [Glass]::Extend($h, 0)
        $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::White
    }
    $script:GlassOk = $ok
}

# ============================================================
#  Services
# ============================================================
function Get-Backup {
    $h = @{}
    if (Test-Path $script:BackupFile) {
        try {
            $obj = Get-Content $script:BackupFile -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                $h[$p.Name] = @{ StartType = [string]$p.Value.StartType; Delayed = [bool]$p.Value.Delayed }
            }
        } catch { }
    }
    return $h
}

function Save-Backup($h) {
    $h | ConvertTo-Json -Depth 4 | Set-Content -Path $script:BackupFile -Encoding UTF8
}

function Test-Delayed([string]$name) {
    try {
        $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart
        return ($v -eq 1)
    } catch { return $false }
}

function Load-Services {
    $list = Get-El 'ListSvc'
    $list.Children.Clear()
    $script:SvcRows = @()
    [void]$list.Children.Add((New-Header 'Tick the services you want to switch off'))
    foreach ($e in $script:Catalogue) {
        $svc = Get-Service -Name $e.N -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $start = [string]$svc.StartType
        if ($start -eq 'Automatic' -and (Test-Delayed $e.N)) { $start = 'Automatic (Delayed)' }
        $isSafe = ($e.C -eq 'Safe')
        $bg = if ($isSafe) { '#3328C840' } else { '#33FF9500' }
        $fg = if ($isSafe) { '#1F9D3A' } else { '#C77700' }
        $badge = if ($isSafe) { 'Safe' } else { 'Optional' }
        if ($start -eq 'Disabled') { $badge = 'Already off'; $bg = '#22808080'; $fg = '#808080' }
        $desc = "$($e.D)  -  $($e.N)  -  now: $start, $($svc.Status)"
        $row = New-Row -Title $svc.DisplayName -Desc $desc -Badge $badge -BadgeBg $bg -BadgeFg $fg -Checked $false
        $script:SvcRows += [pscustomobject]@{ Name = $e.N; Cat = $e.C; Start = $start; Check = $row.Check }
        [void]$list.Children.Add($row.Root)
    }
    Set-Status ("{0} services from the list were found on this PC." -f $script:SvcRows.Count)
}

function Do-TickSafe {
    foreach ($r in $script:SvcRows) { $r.Check.IsChecked = ($r.Cat -eq 'Safe' -and $r.Start -ne 'Disabled') }
}
function Do-UntickAll {
    foreach ($r in $script:SvcRows) { $r.Check.IsChecked = $false }
}

function Do-ApplyServices {
    $rows = @($script:SvcRows | Where-Object { $_.Check.IsChecked })
    if ($rows.Count -eq 0) { Show-Msg 'Nothing is ticked.'; return }
    $strict = [bool](Get-El 'StrictSwitch').IsChecked
    $target = if ($strict) { 'Disabled' } else { 'Manual' }
    if (-not (Confirm-Msg "Set $($rows.Count) service(s) to $target and stop them now?`n`nYour original settings are saved so you can restore them.")) { return }

    Set-Status 'Creating a restore point (skipped if System Protection is off)...'
    if (-not (New-RestorePoint)) { Set-Status 'Restore point skipped (System Protection is off or Windows refused, see error.log).' }

    $backup = Get-Backup
    $ok = 0; $fail = 0
    foreach ($r in $rows) {
        $name = $r.Name
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            if (-not $backup.ContainsKey($name)) {
                $backup[$name] = @{ StartType = [string]$svc.StartType; Delayed = (Test-Delayed $name) }
                Save-Backup $backup
            }
            Set-Status "Processing $name..."
            if ($svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
            $newType = $target
            if ($newType -eq 'Disabled' -and ($script:NeverDisable -contains $name)) { $newType = 'Manual' }
            Set-Service -Name $name -StartupType $newType -ErrorAction Stop
            $ok++
            Add-Activity 'Services' "$name set to $newType"
        } catch { $fail++; Add-Activity 'Services' "FAILED: $name" }
    }
    Save-Backup $backup
    Load-Services
    Update-SysInfo
    Set-Status "Done: $ok changed, $fail failed or protected. Restart for the full effect."
}

function Do-RestoreServices {
    $backup = Get-Backup
    if ($backup.Count -eq 0) { Show-Msg 'No backup found, nothing to restore.'; return }
    if (-not (Confirm-Msg "Restore $($backup.Count) service(s) to their original startup type?")) { return }
    $ok = 0
    $left = @{}
    foreach ($name in @($backup.Keys)) {
        try {
            $orig = $backup[$name].StartType
            if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { continue }   # service no longer exists: nothing to restore
            if ($orig -eq 'Automatic' -and $backup[$name].Delayed) {
                & sc.exe config $name start= delayed-auto | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "sc.exe exit code $LASTEXITCODE" }
            } else {
                Set-Service -Name $name -StartupType $orig -ErrorAction Stop
            }
            if ($orig -eq 'Automatic') { Start-Service -Name $name -ErrorAction SilentlyContinue }
            $ok++
        } catch {
            $left[$name] = $backup[$name]     # keep the original value so Restore can be tried again
            Write-Log ("Restore $name failed: " + $_)
        }
    }
    if ($left.Count -gt 0) { Save-Backup $left } else { Remove-Item $script:BackupFile -ErrorAction SilentlyContinue }
    Add-Activity 'Services' "Restored $ok service(s) to their original startup type"
    Load-Services
    if ($left.Count -gt 0) { Set-Status "Restored $ok service(s). $($left.Count) could not be restored and are still saved, press Restore originals again." }
    else { Set-Status "Restored $ok service(s) to their original settings." }
}

# ============================================================
#  Startup apps
# ============================================================
function Get-Approved([string]$key, [string]$name) {
    try {
        $k = Get-Item -LiteralPath $key -ErrorAction Stop
        $v = $k.GetValue($name)
        if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
        return $true
    } catch { return $true }
}

function Set-Approved([string]$key, [string]$name, [bool]$enabled) {
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
    $b = New-Object byte[] 12
    if ($enabled) {
        $b[0] = 2
    } else {
        $b[0] = 3
        [BitConverter]::GetBytes([long](Get-Date).ToFileTime()).CopyTo($b, 4)
    }
    Set-ItemProperty -LiteralPath $key -Name $name -Value $b -Type Binary -ErrorAction Stop
}

function Add-StartupRow($list, [string]$name, [string]$cmd, [string]$approvedKey, [string]$scope) {
    $enabled = Get-Approved $approvedKey $name
    $short = if ($cmd.Length -gt 110) { $cmd.Substring(0, 110) + '...' } else { $cmd }
    $bg = '#22808080'; $fg = '#808080'; $badge = $scope
    if ("$name $cmd" -match $script:KeepPattern) { $badge = 'Keep'; $bg = '#33007AFF'; $fg = '#0A63D6' }
    $row = New-Row -Title $name -Desc $short -Badge $badge -BadgeBg $bg -BadgeFg $fg -Checked $enabled
    $script:StartRows += [pscustomobject]@{ Name = $name; Key = $approvedKey; Orig = $enabled; Check = $row.Check; Kind = 'Reg'; TaskPath = '' }
    [void]$list.Children.Add($row.Root)
}

function Load-Startup {
    $list = Get-El 'ListStart'
    $list.Children.Clear()
    $script:StartRows = @()
    [void]$list.Children.Add((New-Header 'ON means the app launches when you sign in. Switch off what you do not need'))
    foreach ($src in $script:StartupRunKeys) {
        $k = Get-Item -LiteralPath $src.Path -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            Add-StartupRow $list $n ([string]$k.GetValue($n)) $src.Approved $src.Scope
        }
    }
    foreach ($f in $script:StartupFolders) {
        if (-not (Test-Path -LiteralPath $f.Dir)) { continue }
        Get-ChildItem -LiteralPath $f.Dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            Add-StartupRow $list $_.Name $_.FullName $f.Approved 'Folder'
        }
    }
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskPath -notlike '\Microsoft\*' -and
            (@($_.Triggers | Where-Object { $_.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger') }).Count -gt 0)
        }
        foreach ($tk in $tasks) {
            $enabled = ($tk.State -ne 'Disabled')
            $act = @($tk.Actions)[0]
            $cmd = (([string]$act.Execute) + ' ' + ([string]$act.Arguments)).Trim()
            $short = if ($cmd.Length -gt 110) { $cmd.Substring(0, 110) + '...' } else { $cmd }
            $bg = '#22808080'; $fg = '#808080'; $badge = 'Task'
            if (("$($tk.TaskName) $cmd") -match $script:KeepPattern) { $badge = 'Keep'; $bg = '#33007AFF'; $fg = '#0A63D6' }
            $row = New-Row -Title $tk.TaskName -Desc $short -Badge $badge -BadgeBg $bg -BadgeFg $fg -Checked $enabled
            $script:StartRows += [pscustomobject]@{ Name = $tk.TaskName; Key = ''; Orig = $enabled; Check = $row.Check; Kind = 'Task'; TaskPath = $tk.TaskPath }
            [void]$list.Children.Add($row.Root)
        }
    } catch { Write-Log ('Scheduled task list failed: ' + $_) }
    Set-Status ("{0} startup entries found." -f $script:StartRows.Count)
}

function Do-ApplyStartup {
    $n = 0; $fail = 0
    foreach ($r in $script:StartRows) {
        $want = [bool]$r.Check.IsChecked
        if ($want -ne $r.Orig) {
            try {
                if ($r.Kind -eq 'Task') {
                    if ($want) { [void](Enable-ScheduledTask -TaskName $r.Name -TaskPath $r.TaskPath -ErrorAction Stop) }
                    else { [void](Disable-ScheduledTask -TaskName $r.Name -TaskPath $r.TaskPath -ErrorAction Stop) }
                } else {
                    Set-Approved $r.Key $r.Name $want
                }
                $r.Orig = $want
                $n++
                $verb = 'Switched off'
                if ($want) { $verb = 'Switched on' }
                Add-Activity 'Startup' "$verb $($r.Name)"
            } catch {
                $fail++
                Write-Log ('Startup change failed ' + $r.Name + ': ' + $_)
                Add-Activity 'Startup' "FAILED: $($r.Name)"
            }
        }
    }
    $failText = ''
    if ($fail -gt 0) { $failText = " $fail could not be changed (see the log)." }
    Set-Status "$n startup entries changed.$failText Takes effect next time you sign in. Toggle back on any time."
}

# ============================================================
#  Cleaner
# ============================================================
function Get-PathSize($paths) {
    $sum = [long]0
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            $m = Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($m.Sum) { $sum += [long]$m.Sum }
        }
    }
    return $sum
}

# Empty a cleaner target and return the bytes freed. Targets with StopSvc (the Windows Update cache) have those
# services stopped around the delete and started again afterwards if they were running.
function Clear-Target($t) {
    $was = @()
    foreach ($sn in @($t.StopSvc)) {
        if (-not $sn) { continue }
        $sv = Get-Service -Name $sn -ErrorAction SilentlyContinue
        if ($sv -and $sv.Status -eq 'Running') { $was += $sn; Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue }
    }
    try {
        $before = Get-PathSize $t.Paths
        foreach ($p in $t.Paths) {
            if ($p -and (Test-Path -LiteralPath $p)) {
                Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $after = Get-PathSize $t.Paths
        return [math]::Max([long]0, ($before - $after))
    } finally {
        foreach ($sn in $was) { Start-Service -Name $sn -ErrorAction SilentlyContinue }
    }
}

function Get-RecycleSize {
    try { return [long][Glass]::BinSize() } catch { return [long]0 }
}

function Load-Clean {
    $list = Get-El 'ListClean'
    $list.Children.Clear()
    $script:CleanRows = @()
    [void]$list.Children.Add((New-Header 'Press Scan to see how much space each item uses'))
    foreach ($t in $script:CleanTargets) {
        $row = New-Row -Title $t.Name -Desc $t.Desc -Badge '' -Checked ([bool]$t.Default)
        $script:CleanRows += [pscustomobject]@{ Target = $t; Check = $row.Check; BadgeText = $row.BadgeText; Badge = $row.BadgeText.Parent }
        [void]$list.Children.Add($row.Root)
    }
    Set-Status 'Ready. Press Scan.'
}

function Do-Scan {
    $total = [long]0
    foreach ($r in $script:CleanRows) {
        Set-Status ("Scanning " + $r.Target.Name + "...")
        $size = if ($r.Target.Special -eq 'Recycle') { Get-RecycleSize } else { Get-PathSize $r.Target.Paths }
        $r.BadgeText.Text = (Format-Size $size)
        $r.Badge.Visibility = 'Visible'
        $r.Badge.Background = [System.Windows.Media.Brushes]::Transparent
        $r.Badge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'ButtonBrush')
        $r.BadgeText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
        if ($r.Check.IsChecked) { $total += $size }
    }
    Set-Status ("Scan done. Ticked items total about " + (Format-Size $total) + ".")
}

function Do-Clean {
    $rows = @($script:CleanRows | Where-Object { $_.Check.IsChecked })
    if ($rows.Count -eq 0) { Show-Msg 'Nothing is ticked.'; return }
    if (-not (Confirm-Msg "Delete the contents of $($rows.Count) ticked item(s)? This cannot be undone.")) { return }
    $freed = [long]0
    foreach ($r in $rows) {
        Set-Status ("Cleaning " + $r.Target.Name + "...")
        if ($r.Target.Special -eq 'Recycle') {
            $before = Get-RecycleSize
            try { [void][Glass]::EmptyBin() } catch { Write-Log ('Empty recycle bin failed: ' + $_) }
            $freed += $before
        } else {
            $freed += Clear-Target $r.Target
        }
    }
    Add-Activity 'Cleaner' ("Cleaned " + $rows.Count + " item(s), freed about " + (Format-Size $freed))
    Do-Scan
    Set-Status ("Freed about " + (Format-Size $freed) + ". Files in use were skipped.")
}

# ============================================================
#  Gaming mode
# ============================================================
$script:GameRegs = @(
    @{ Key='GM1';  Path='HKCU:\Software\Microsoft\GameBar';                          Name='AutoGameModeEnabled' },
    @{ Key='GM2';  Path='HKCU:\Software\Microsoft\GameBar';                          Name='AllowAutoGameMode' },
    @{ Key='DVR1'; Path='HKCU:\System\GameConfigStore';                              Name='GameDVR_Enabled' },
    @{ Key='DVR2'; Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR';   Name='AppCaptureEnabled' }
)

function Get-RegVal([string]$path, [string]$name) {
    try { return (Get-ItemProperty -LiteralPath $path -ErrorAction Stop).$name } catch { return $null }
}
function Set-RegVal([string]$path, [string]$name, $val) {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -LiteralPath $path -Name $name -Value ([int]$val) -Type DWord -ErrorAction Stop
}

function Get-ActiveScheme {
    $o = (powercfg /getactivescheme) -join ' '
    if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    return $null
}

# The plan we create is remembered by GUID in the gaming backup ($bk['UltGuid']), not found by its English name:
# the name differs on non-English Windows, and a name match returns several lines once plans pile up.
$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
function Set-UltimatePlan($bk) {
    $guid = [string]$bk['UltGuid']
    if (-not $guid -or -not ((powercfg /list) -match [regex]::Escape($guid))) {
        $out = (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1) -join ' '
        if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $guid = $Matches[1] }
        else { $guid = $script:HighPerfGuid }      # Ultimate Performance is not available here: use High performance
        $bk['UltGuid'] = $guid
    }
    powercfg /setactive $guid | Out-Null
}

function Get-GameBackup {
    $h = @{}
    if (Test-Path $script:GameFile) {
        try {
            $obj = Get-Content $script:GameFile -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch { }
    }
    return $h
}

function Load-Game {
    $list = Get-El 'ListGame'
    $list.Children.Clear()
    $script:GameRows = @()
    $script:AppRows = @()
    [void]$list.Children.Add((New-Header 'Tweaks'))
    $defs = @(
        @{ Id='Power';    T='Ultimate Performance power plan'; D='Stops the CPU from throttling down while you play. Your current plan is saved and restored.' },
        @{ Id='GameMode'; T='Windows Game Mode';               D='Tells Windows to prioritise your game over background tasks.' },
        @{ Id='DVR';      T='Turn off background game recording'; D='Disables Xbox Game Bar recording, which can cost a few FPS.' }
    )
    foreach ($d in $defs) {
        $row = New-Row -Title $d.T -Desc $d.D -Checked $true
        $script:GameRows += [pscustomobject]@{ Id = $d.Id; Check = $row.Check }
        [void]$list.Children.Add($row.Root)
    }
    [void]$list.Children.Add((New-Header 'Close these running apps first (they are asked to close politely, unsaved work will prompt you)'))
    $skip = @('explorer','powershell','pwsh','ApplicationFrameHost','TextInputHost','SystemSettings','ShellExperienceHost','SearchHost','StartMenuExperienceHost','dwm','Idle','WindowsTerminal','conhost')
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and ($skip -notcontains $_.ProcessName) -and $_.Id -ne $PID
    }
    foreach ($p in $procs) {
        $row = New-Row -Title $p.ProcessName -Desc $p.MainWindowTitle -Checked $false
        $script:AppRows += [pscustomobject]@{ Proc = $p; Check = $row.Check }
        [void]$list.Children.Add($row.Root)
    }
    Set-Status 'Ready. Pick your tweaks and press Gaming mode on.'
}

function Do-GameOn {
    $bk = Get-GameBackup
    $on = @{}
    foreach ($r in $script:GameRows) { $on[$r.Id] = [bool]$r.Check.IsChecked }

    if ($on['Power']) {
        if (-not $bk.ContainsKey('Scheme')) { $bk['Scheme'] = Get-ActiveScheme }
        Set-UltimatePlan $bk
    }
    foreach ($g in $script:GameRegs) {
        $wanted = (($g.Key -like 'GM*' -and $on['GameMode']) -or ($g.Key -like 'DVR*' -and $on['DVR']))
        if (-not $wanted) { continue }
        if (-not $bk.ContainsKey($g.Key)) { $bk[$g.Key] = Get-RegVal $g.Path $g.Name }
        $val = if ($g.Key -like 'GM*') { 1 } else { 0 }
        Set-RegVal $g.Path $g.Name $val
    }
    $bk | ConvertTo-Json -Depth 3 | Set-Content -Path $script:GameFile -Encoding UTF8

    $closed = 0
    foreach ($a in $script:AppRows) {
        if ($a.Check.IsChecked) {
            try { if ($a.Proc.CloseMainWindow()) { $closed++ } } catch { }
        }
    }
    Add-Activity 'Gaming' "Gaming mode on (closed $closed app(s))"
    Set-Status "Gaming mode on. Closed $closed app(s). Use Restore normal afterwards to undo."
}

function Do-GameOff {
    $bk = Get-GameBackup
    if ($bk.Count -eq 0) { Show-Msg 'Nothing to restore. Gaming mode has not been switched on.'; return }
    if ($bk.ContainsKey('Scheme') -and $bk['Scheme']) { powercfg /setactive $bk['Scheme'] | Out-Null }
    # Delete the plan we created (never the built-in High performance one)
    if ($bk.ContainsKey('UltGuid') -and $bk['UltGuid'] -and ([string]$bk['UltGuid'] -ne $script:HighPerfGuid)) { powercfg /delete ([string]$bk['UltGuid']) | Out-Null }
    foreach ($g in $script:GameRegs) {
        if (-not $bk.ContainsKey($g.Key)) { continue }
        $orig = $bk[$g.Key]
        if ($null -eq $orig) {
            Remove-ItemProperty -LiteralPath $g.Path -Name $g.Name -ErrorAction SilentlyContinue
        } else {
            Set-RegVal $g.Path $g.Name $orig
        }
    }
    Remove-Item $script:GameFile -ErrorAction SilentlyContinue
    Add-Activity 'Gaming' 'Gaming mode off, original settings restored'
    Set-Status 'Restored your original power plan and Game Mode settings.'
}

# ============================================================
#  Restore point
# ============================================================
# -EnableProtection turns System Protection on for the system drive first. Only the explicit "Create a restore point"
# button does that (after asking); the automatic ones before Apply / Tune-Up leave the setting alone and just skip.
function New-RestorePoint([switch]$EnableProtection) {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = $null
    try {
        if ($EnableProtection) { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop }
        $old = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        Set-ItemProperty -LiteralPath $key -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'PC Optimizer' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        return $true
    } catch {
        Write-Log ('Restore point failed: ' + $_)
        return $false
    } finally {
        try {
            if ($null -eq $old) { Remove-ItemProperty -LiteralPath $key -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -LiteralPath $key -Name 'SystemRestorePointCreationFrequency' -Value $old -Type DWord -ErrorAction SilentlyContinue }
        } catch { }
    }
}

function Do-RestorePoint {
    if (-not (Confirm-Msg "Create a restore point now?`n`nIf System Protection is off for $env:SystemDrive it is switched on first. It keeps a few GB of old file versions on that drive, and you can turn it off again in Start > Create a restore point.")) { return }
    Set-Status 'Creating restore point... this can take up to a minute'
    if (New-RestorePoint -EnableProtection) {
        Add-Activity 'System' 'Restore point created'
        Set-Status 'Restore point created. Roll back from Start > Create a restore point > System Restore.'
    } else {
        Show-Msg "Windows would not create a restore point.`n`nSee error.log in the data folder for the reason. Search 'Create a restore point' in Start to check that protection is on for $env:SystemDrive."
        Set-Status 'Restore point not created.'
    }
}

# ============================================================
#  Apps (preinstalled Store apps)
# ============================================================
$script:BloatPattern = 'Clipchamp|Copilot|Cortana|549981C3F5F10|BingNews|BingFinance|BingSports|BingSearch|Getstarted|OfficeHub|SolitaireCollection|People|FeedbackHub|YourPhone|PhoneLink|ZuneMusic|ZuneVideo|MixedReality|SkypeApp|MicrosoftTeams|MSTeams|PowerAutomate|3DBuilder|3DViewer|OneConnect|Wallet|CandyCrush|Disney|TikTok|Facebook|Instagram|LinkedIn|Netflix|AmazonPrime|Twitter|Roblox|FarmVille|MarchofEmpires|Hulu|PicsArt|Duolingo|McAfee|Norton|OfficeLens|Print3D|Sway|Family|DevHome|OutlookForWindows|WindowsCommunicationsApps|CrossDevice|BingFoodAndDrink|BingHealthAndFitness|BingTranslator|BingTravel|Microsoft\.Messaging|MicrosoftJournal|PowerBIForWindows|NetworkSpeedTest|Microsoft\.News$|Office\.OneNote|Photoshop|Amazon\.com\.Amazon|Asphalt8|Sketchbook|Casino|Slots|COOKINGFEVER|CyberLink|DisneyMagicKingdoms|Drawboard|EclipseManager|fitbit|Flipboard|HiddenCity|iHeartRadio|king\.com|NYTCrossword|OneCalendar|Pandora|Phototastic|Plex|Polarr|RoyalRevolt|Shazam|Sidia|SlingTV|SpeedTest|TuneInRadio|Viber|WinZip|Wunderlist|XING|ACGMediaPlayer|ActiproSoftware|DellInc|AD2F1837|LenovoCompany|E046963F|AcerIncorporated|WildTangent|ExpressVPN|Dropbox|Evernote|BookingCom'
$script:ProtectPattern = 'WindowsStore|StorePurchaseApp|DesktopAppInstaller|WindowsCalculator|Windows\.Photos|WindowsNotepad|WindowsTerminal|MicrosoftEdge|Xbox|GamingApp|SecHealthUI|SecurityHealth|Paint|ScreenSketch|WindowsCamera|WindowsSoundRecorder|VCLibs|NET\.Native|UI\.Xaml|WindowsAlarms|ShellExperienceHost|StartMenuExperienceHost|Windows\.Search|SearchApp|AAD\.BrokerPlugin|AccountsControl|LockApp|Win32WebViewHost|WebExperience|HEIFImageExtension|WebpImageExtension|VP9VideoExtensions|AV1VideoExtension|RawImageExtension|WebMediaExtensions|MPEG2VideoExtension|HEVCVideoExtension|AVCEncoderVideoExtension|Realtek|Intel|AMD|Radeon|NVIDIA|Nahimic|DolbyAccess|ImmersiveControlPanel|CBSPreview|CapturePicker|FilePicker|AssignedAccess|BioEnrollment|CredDialogHost|ECApp|OOBE|ParentalControls|PeopleExperienceHost|PinningConfirmationDialog|AsyncTextService|NcsiUwp|ContentDeliveryManager|Apprep|XGpuEjectDialog|Services\.Store|CloudExperienceHost|PrintDialog|Win32Bridge|QuickAssist|WinAppRuntime|WindowsAppRuntime|DirectXRuntime'

# "Bloat" only means an app that shipped with the Windows image or the PC maker. An app someone installed themselves
# (Roblox, Netflix, Plex...) matches the name list but is not provisioned, so it is never auto-ticked or called junk.
$script:ProvNames = $null
function Test-IsBloat([string]$name) {
    if ($null -eq $script:ProvNames) {
        $script:ProvNames = @()
        try { $script:ProvNames = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { [string]$_.DisplayName }) }
        catch { Write-Log ('Provisioned app list failed: ' + $_) }
    }
    return [bool](($script:ProvNames -contains $name) -and ($name -match $script:BloatPattern))
}

$script:FriendlyApps = @(
    @('Clipchamp', 'Clipchamp', 'Video editor from Microsoft'),
    @('Copilot', 'Copilot', 'Microsoft AI assistant app'),
    @('Cortana|549981C3F5F10', 'Cortana', 'Old Microsoft voice assistant'),
    @('BingNews', 'News', 'Microsoft News headlines app'),
    @('BingWeather', 'Weather', 'Microsoft Weather app'),
    @('BingFinance', 'Money', 'Microsoft finance and stocks app'),
    @('BingSports', 'Sports', 'Microsoft Sports scores app'),
    @('BingSearch', 'Bing Search', 'Bing search integration'),
    @('GetHelp', 'Get Help', 'Microsoft support chat app'),
    @('Getstarted', 'Tips', 'Windows tips and tutorials app'),
    @('Todos', 'Microsoft To Do', 'To-do list app'),
    @('OfficeHub', 'Microsoft 365 hub', 'Shortcut app that advertises Office'),
    @('SolitaireCollection', 'Solitaire Collection', 'Microsoft card games'),
    @('(^|\.)People$', 'People', 'Contacts app'),
    @('FeedbackHub', 'Feedback Hub', 'Sends feedback to Microsoft'),
    @('YourPhone|PhoneLink', 'Phone Link', 'Connects your phone to Windows'),
    @('CrossDevice', 'Cross Device Experience', 'Phone Link and nearby sharing features'),
    @('ZuneMusic', 'Media Player', 'Music player (formerly Groove Music)'),
    @('ZuneVideo', 'Movies and TV', 'Video player app'),
    @('MixedReality', 'Mixed Reality Portal', 'VR headset software'),
    @('SkypeApp', 'Skype', 'Video calling app'),
    @('MicrosoftTeams|MSTeams', 'Microsoft Teams', 'Chat and meetings app'),
    @('PowerAutomate', 'Power Automate', 'Task automation tool'),
    @('WindowsMaps', 'Maps', 'Microsoft Maps app'),
    @('3DBuilder', '3D Builder', 'Basic 3D modelling app'),
    @('3DViewer', '3D Viewer', 'Opens 3D model files'),
    @('Print3D', 'Print 3D', '3D printing app'),
    @('OneConnect', 'Mobile Plans', 'Cellular data plan app'),
    @('Wallet', 'Microsoft Wallet', 'Payment cards app'),
    @('CandyCrush', 'Candy Crush', 'Preinstalled mobile-style game'),
    @('Disney', 'Disney+', 'Streaming app'),
    @('TikTok', 'TikTok', 'Social video app'),
    @('Facebook', 'Facebook', 'Social media app'),
    @('Instagram', 'Instagram', 'Social media app'),
    @('LinkedIn', 'LinkedIn', 'Professional network app'),
    @('Netflix', 'Netflix', 'Streaming app'),
    @('AmazonPrime', 'Prime Video', 'Streaming app'),
    @('Twitter', 'Twitter', 'Social media app'),
    @('Roblox', 'Roblox', 'Game platform'),
    @('FarmVille', 'FarmVille', 'Preinstalled game'),
    @('MarchofEmpires', 'March of Empires', 'Preinstalled game'),
    @('Hulu', 'Hulu', 'Streaming app'),
    @('PicsArt', 'PicsArt', 'Photo editing app'),
    @('Duolingo', 'Duolingo', 'Language learning app'),
    @('McAfee', 'McAfee', 'Trial antivirus software'),
    @('Norton', 'Norton', 'Trial antivirus software'),
    @('OfficeLens', 'Office Lens', 'Scans documents with your camera'),
    @('(^|\.)Sway$', 'Sway', 'Presentation and newsletter app'),
    @('Family', 'Microsoft Family', 'Parental controls app'),
    @('DevHome', 'Dev Home', 'Developer dashboard'),
    @('OutlookForWindows', 'Outlook (new)', 'New Outlook mail app'),
    @('WindowsCommunicationsApps', 'Mail and Calendar', 'Old Mail and Calendar apps'),
    @('StickyNotes', 'Sticky Notes', 'Desktop notes'),
    @('Whiteboard', 'Whiteboard', 'Digital whiteboard app'),
    @('SpotifyMusic', 'Spotify', 'Music streaming app'),
    @('WindowsSubsystemForLinux', 'Windows Subsystem for Linux', 'Runs Linux on Windows. Keep it if you use WSL'),
    @('PythonManager', 'Python Install Manager', 'Installs and switches Python versions'),
    @('SeelenUI', 'Seelen UI', 'Custom desktop and taskbar'),
    @('WinRAR', 'WinRAR right-click menu', 'Adds WinRAR options to the right-click menu'),
    @('BingFoodAndDrink', 'Food and Drink', 'Recipes app (discontinued)'),
    @('BingHealthAndFitness', 'Health and Fitness', 'Fitness tips app (discontinued)'),
    @('BingTranslator', 'Translator', 'Bing translation app'),
    @('BingTravel', 'Travel', 'Bing travel app (discontinued)'),
    @('Microsoft\.Messaging', 'Messaging', 'Old text messaging app'),
    @('MicrosoftJournal', 'Journal', 'Pen and notes journal app'),
    @('PowerBIForWindows', 'Power BI', 'Business analytics app'),
    @('NetworkSpeedTest', 'Network Speed Test', 'Basic speed test app'),
    @('Microsoft\.News$', 'News (old)', 'Old Microsoft News app'),
    @('Office\.OneNote', 'OneNote (old)', 'Old OneNote Store app'),
    @('Photoshop', 'Photoshop Express', 'Adobe photo editor'),
    @('Amazon\.com\.Amazon', 'Amazon', 'Amazon shopping app'),
    @('Asphalt8', 'Asphalt 8', 'Racing game'),
    @('Sketchbook', 'Autodesk SketchBook', 'Drawing app'),
    @('Casino|Slots', 'Casino game', 'Preinstalled casino-style game'),
    @('COOKINGFEVER', 'Cooking Fever', 'Preinstalled game'),
    @('CyberLink', 'CyberLink Media Suite', 'Trial media software'),
    @('DisneyMagicKingdoms', 'Disney Magic Kingdoms', 'Preinstalled game'),
    @('Drawboard', 'Drawboard PDF', 'PDF markup app'),
    @('EclipseManager', 'Eclipse Manager', 'Preinstalled utility'),
    @('fitbit', 'Fitbit', 'Fitness tracker app'),
    @('Flipboard', 'Flipboard', 'News reader'),
    @('HiddenCity', 'Hidden City', 'Preinstalled game'),
    @('iHeartRadio', 'iHeartRadio', 'Radio streaming app'),
    @('king\.com', 'King puzzle game', 'Preinstalled mobile-style game'),
    @('NYTCrossword', 'NYT Crossword', 'Puzzle app'),
    @('OneCalendar', 'One Calendar', 'Calendar app'),
    @('Pandora', 'Pandora', 'Music streaming app'),
    @('Phototastic', 'Phototastic Collage', 'Photo collage app'),
    @('Plex', 'Plex', 'Media streaming app'),
    @('Polarr', 'Polarr Photo Editor', 'Photo editing app'),
    @('RoyalRevolt', 'Royal Revolt', 'Preinstalled game'),
    @('Shazam', 'Shazam', 'Music recognition app'),
    @('Sidia', 'Live Wallpaper', 'Animated wallpaper app'),
    @('SlingTV', 'Sling TV', 'Streaming app'),
    @('SpeedTest', 'Speed Test', 'Internet speed test app'),
    @('TuneInRadio', 'TuneIn Radio', 'Radio app'),
    @('Viber', 'Viber', 'Messaging app'),
    @('WinZip', 'WinZip', 'Trial archive tool'),
    @('Wunderlist', 'Wunderlist', 'Old to-do app'),
    @('XING', 'XING', 'Professional network app'),
    @('ACGMediaPlayer', 'ACG Media Player', 'Media player'),
    @('ActiproSoftware', 'Actipro apps', 'Preinstalled demo software'),
    @('DellInc', 'Dell app', 'Preinstalled by Dell'),
    @('AD2F1837', 'HP app', 'Preinstalled by HP'),
    @('LenovoCompany|E046963F', 'Lenovo app', 'Preinstalled by Lenovo'),
    @('AcerIncorporated', 'Acer app', 'Preinstalled by Acer'),
    @('WildTangent', 'WildTangent Games', 'Trial game bundle'),
    @('ExpressVPN', 'ExpressVPN', 'Trial VPN'),
    @('Dropbox', 'Dropbox', 'Cloud storage promo app'),
    @('Evernote', 'Evernote', 'Notes app'),
    @('BookingCom', 'Booking.com', 'Travel booking app')
)

function Split-Camel([string]$t) {
    $t = [regex]::Replace($t, '(?<=[a-z0-9])(?=[A-Z])', ' ')
    $t = [regex]::Replace($t, '(?<=[A-Z])(?=[A-Z][a-z])', ' ')
    return $t.Trim()
}

# Turn a raw package into a readable title and one-line description
function Get-FriendlyApp($p) {
    $name = [string]$p.Name
    foreach ($f in $script:FriendlyApps) {
        if ($name -match $f[0]) { return @{ Title = $f[1]; Desc = $f[2] } }
    }
    $parts = @($name -split '\.')
    $pub = ''
    $rest = $name
    if ($parts.Count -gt 1) {
        $pub = $parts[0]
        $rest = (($parts[1..($parts.Count - 1)]) -join ' ')
    }
    $pubText = 'an unknown publisher'
    if ($pub -match '^Microsoft') { $pubText = 'Microsoft' } elseif ($pub) { $pubText = Split-Camel $pub }
    return @{ Title = (Split-Camel $rest); Desc = ("By $pubText  -  version " + $p.Version) }
}

# ---- OneDrive (a normal program, not a Store app, so it has its own uninstaller) ----
function Get-OneDriveSetup {
    $c = @(
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe"
    )
    foreach ($f in @(Get-ChildItem -Path "$env:ProgramFiles\Microsoft OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue)) { $c += $f.FullName }
    foreach ($f in @(Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue)) { $c += $f.FullName }
    foreach ($x in $c) { if ($x -and (Test-Path -LiteralPath $x)) { return $x } }
    return $null
}

# Which of Desktop / Documents / Pictures are backed up to OneDrive right now?
function Get-OneDriveFolders {
    $out = @()
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    foreach ($pair in @(@('Desktop', 'Desktop'), @('Personal', 'Documents'), @('My Pictures', 'Pictures'))) {
        $v = Get-RegVal $k $pair[0]
        if ($v -and ([string]$v -match 'OneDrive')) { $out += $pair[1] }
    }
    return ,$out
}

function Load-Apps {
    $list = Get-El 'ListApps'
    $list.Children.Clear()
    $script:PkgRows = @()
    Set-Status 'Loading installed apps... this can take a few seconds'
    [void]$list.Children.Add((New-Header 'Tick the apps you want to remove. Only apps that are safe to remove are listed'))
    $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
        -not $_.IsFramework -and -not $_.NonRemovable -and -not $_.IsResourcePackage -and $_.SignatureKind -ne 'System' -and ($_.Name -notmatch $script:ProtectPattern)
    })
    $items = @()
    foreach ($p in $pkgs) {
        $fa = Get-FriendlyApp $p
        $items += [pscustomobject]@{ P = $p; Title = [string]$fa.Title; Desc = [string]$fa.Desc; Bloat = (Test-IsBloat ([string]$p.Name)) }
    }
    $ordered = @($items | Where-Object { $_.Bloat } | Sort-Object Title) + @($items | Where-Object { -not $_.Bloat } | Sort-Object Title)
    $odSetup = Get-OneDriveSetup
    if ($odSetup) {
        $odFolders = @(Get-OneDriveFolders)
        $odBloat = ($odFolders.Count -eq 0)
        $odDesc = 'Microsoft cloud storage. Removing it keeps the files already in your OneDrive folder.'
        $odBadge = 'Bloat'; $odBg = '#33FF3B30'; $odFg = '#D70015'
        if (-not $odBloat) {
            $odDesc = 'Your ' + ($odFolders -join ', ') + ' are backed up to OneDrive. Removing it will not delete files, but those folders keep living inside the OneDrive folder.'
            $odBadge = 'Check first'; $odBg = '#33FF9500'; $odFg = '#C77700'
        }
        $odRow = New-Row -Title 'Microsoft OneDrive' -Desc $odDesc -Badge $odBadge -BadgeBg $odBg -BadgeFg $odFg -Checked $false
        $odRow.Root.ToolTip = ('Uninstaller: ' + $odSetup)
        $script:PkgRows += [pscustomobject]@{ Full = 'ONEDRIVE'; Name = 'Microsoft OneDrive'; Bloat = $odBloat; Check = $odRow.Check; Setup = $odSetup; Folders = $odFolders }
        [void]$list.Children.Add($odRow.Root)
    }
    foreach ($it in $ordered) {
        $bg = if ($it.Bloat) { '#33FF3B30' } else { '#22808080' }
        $fg = if ($it.Bloat) { '#D70015' } else { '#808080' }
        $badge = if ($it.Bloat) { 'Bloat' } else { 'App' }
        $row = New-Row -Title $it.Title -Desc $it.Desc -Badge $badge -BadgeBg $bg -BadgeFg $fg -Checked $false
        $row.Root.ToolTip = ('Package name: ' + $it.P.Name)
        $script:PkgRows += [pscustomobject]@{ Full = $it.P.PackageFullName; Name = $it.Title; Bloat = $it.Bloat; Check = $row.Check }
        [void]$list.Children.Add($row.Root)
    }
    Set-Status ("{0} removable apps found." -f $script:PkgRows.Count)
}

function Do-TickBloat {
    foreach ($r in $script:PkgRows) { $r.Check.IsChecked = [bool]$r.Bloat }
}

function Do-RemoveApps {
    $rows = @($script:PkgRows | Where-Object { $_.Check.IsChecked })
    if ($rows.Count -eq 0) { Show-Msg 'Nothing is ticked.'; return }
    if (-not (Confirm-Msg "Remove $($rows.Count) app(s) for your account?`n`nYou can reinstall them from the Microsoft Store, but this tool cannot undo it.")) { return }
    $ok = 0; $fail = 0
    foreach ($r in $rows) {
        Set-Status ("Removing " + $r.Name + "...")
        if ($r.Full -eq 'ONEDRIVE') {
            if (@($r.Folders).Count -gt 0) {
                if (-not (Confirm-Msg ("Your " + (@($r.Folders) -join ', ') + " are backed up to OneDrive.`n`nYour files are NOT deleted, but those folders will stay inside the OneDrive folder and stop syncing.`n`nRemove OneDrive anyway?"))) { continue }
            }
            try {
                & taskkill.exe /f /im OneDrive.exe 2>&1 | Out-Null
                $argList = '/uninstall'
                if ($r.Setup -like "$env:ProgramFiles*") { $argList = '/uninstall /allusers' }
                Start-Process -FilePath $r.Setup -ArgumentList $argList -Wait -WindowStyle Hidden
                $ok++
                Add-Activity 'Apps' 'Uninstalled Microsoft OneDrive'
            } catch { $fail++; Write-Log ('Remove OneDrive failed: ' + $_) }
            continue
        }
        try { Remove-AppxPackage -Package $r.Full -ErrorAction Stop; $ok++; Add-Activity 'Apps' ('Removed ' + $r.Name) }
        catch { $fail++; Write-Log ('Remove app failed ' + $r.Name + ': ' + $_) }
    }
    Load-Apps
    Set-Status "Removed $ok app(s), $fail failed."
}

# ============================================================
#  System info panel
# ============================================================
function Get-BootSecs {
    $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
    $x = [xml]$e.ToXml()
    $ms = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
    if ($ms) { return [math]::Round(([double]$ms) / 1000, 1) }
    return $null
}

function Update-SysInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $total = [double]$os.TotalVisibleMemorySize / 1MB
        $used = $total - ([double]$os.FreePhysicalMemory / 1MB)
        $svc = @(Get-Service | Where-Object { $_.Status -eq 'Running' }).Count
        $procs = @(Get-Process).Count
        $up = (Get-Date) - $os.LastBootUpTime
        if (-not $script:Baseline) { $script:Baseline = @{ Svc = $svc; Used = $used; Procs = $procs } }
        $ds = $svc - $script:Baseline.Svc
        $dr = $used - $script:Baseline.Used
        $dsText = if ($ds -eq 0) { 'same as at start' } elseif ($ds -lt 0) { "$ds since opening" } else { "+$ds since opening" }
        $drText = if ([math]::Abs($dr) -lt 0.05) { 'same as at start' } elseif ($dr -lt 0) { ('{0:N1} GB since opening' -f $dr) } else { ('+{0:N1} GB since opening' -f $dr) }
        $lines = @()
        $lines += ("RAM used: {0:N1} / {1:N1} GB" -f $used, $total)
        $lines += ("   ($drText)")
        $lines += ("Services running: $svc")
        $lines += ("   ($dsText)")
        $lines += ("Processes: $procs")
        $lines += ("Uptime: {0}d {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes)
        if ($script:BootSecs) { $lines += ("Last boot time: {0} s" -f $script:BootSecs) }
        (Get-El 'SysInfo').Text = ($lines -join "`n")
    } catch { Write-Log ('SysInfo failed: ' + $_) }
}

# ============================================================
#  Dashboard (live gauges)
# ============================================================
$script:BgFast = @'
param($S)
$S.Run = $true
function Prime($c) { try { [void]$c.NextValue() } catch { } }
$cpu = $null; $disk = $null; $nets = @()
try { $cpu = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total'); Prime $cpu } catch { }
try { $disk = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', '% Disk Time', '_Total'); Prime $disk } catch { }
try {
    $cat = New-Object System.Diagnostics.PerformanceCounterCategory('Network Interface')
    foreach ($i in $cat.GetInstanceNames()) {
        if ($i -match 'Loopback|isatap|Teredo|Pseudo|WAN Miniport|Bluetooth|Virtual') { continue }
        $rx = New-Object System.Diagnostics.PerformanceCounter('Network Interface', 'Bytes Received/sec', $i)
        $tx = New-Object System.Diagnostics.PerformanceCounter('Network Interface', 'Bytes Sent/sec', $i)
        Prime $rx; Prime $tx
        $nets += [pscustomobject]@{ Rx = $rx; Tx = $tx }
    }
} catch { }
while ($S.Run) {
    try { if ($cpu) { $S.Cpu = [math]::Min(100.0, [double]$cpu.NextValue()) } } catch { }
    try { if ($disk) { $S.Disk = [math]::Min(100.0, [double]$disk.NextValue()) } } catch { }
    try {
        $d = 0.0; $u = 0.0
        foreach ($x in $nets) { $d += [double]$x.Rx.NextValue(); $u += [double]$x.Tx.NextValue() }
        $S.NetDown = $d; $S.NetUp = $u
    } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $S.RamTotal = [double]$os.TotalVisibleMemorySize / 1MB
        $S.RamUsed = $S.RamTotal - ([double]$os.FreePhysicalMemory / 1MB)
    } catch { }
    Start-Sleep -Milliseconds 1000
}
'@

$script:BgGpu = @'
param($S)
# WMI class names are the same on every Windows language (the Get-Counter paths are translated)
while ($true) {
    try {
        $g = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $_.Name -like '*engtype_3D*' })
        $sum = ($g | Measure-Object -Property UtilizationPercentage -Sum).Sum
        $S.Gpu = [math]::Min(100.0, [double]$sum)
    } catch { $S.Gpu = $null }
    try {
        # The adapter using the most dedicated memory is the real graphics card (the integrated one barely uses any)
        $m = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop)
        $S.VramUsed = [double](($m | Measure-Object -Property DedicatedUsage -Maximum).Maximum)
    } catch { $S.VramUsed = $null }
    if ($S.Run -eq $false) { break }
    Start-Sleep -Milliseconds 1000
}
'@

function Get-Brush([string]$hex) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $b = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]$c)
    return $b.psobject.BaseObject
}

# Draw a 270-degree arc (gauge) filled to $v (0..1) inside a 130x130 box
function Set-Arc($path, [double]$v) {
    $cx = 65.0; $cy = 65.0; $r = 59.0
    if ($v -lt 0.003) { $v = 0.003 }
    if ($v -gt 1.0) { $v = 1.0 }
    $a0 = 135.0 * [math]::PI / 180.0
    $a1 = (135.0 + 270.0 * $v) * [math]::PI / 180.0
    $p0 = New-Object System.Windows.Point(($cx + $r * [math]::Cos($a0)), ($cy + $r * [math]::Sin($a0)))
    $p1 = New-Object System.Windows.Point(($cx + $r * [math]::Cos($a1)), ($cy + $r * [math]::Sin($a1)))
    $seg = New-Object System.Windows.Media.ArcSegment
    $seg.Point = $p1
    $seg.Size = New-Object System.Windows.Size($r, $r)
    $seg.SweepDirection = 'Clockwise'
    $seg.IsLargeArc = ((270.0 * $v) -gt 180.0)
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = $p0
    [void]$fig.Segments.Add($seg)
    $geo = New-Object System.Windows.Media.PathGeometry
    [void]$geo.Figures.Add($fig)
    $path.Data = $geo
}

function New-Gauge([string]$key, [string]$title) {
    $t = [Security.SecurityElement]::Escape($title)
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="180" Margin="0,0,12,12" CornerRadius="14" Padding="14,12" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <StackPanel>
    <TextBlock Text="$t" FontWeight="SemiBold" FontSize="13" Foreground="{DynamicResource TextBrush}"/>
    <Grid Width="130" Height="130" Margin="0,6,0,4" HorizontalAlignment="Center">
      <Path x:Name="Track" Stroke="#33808080" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
      <Path x:Name="Arc" Stroke="#34C759" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
      <TextBlock x:Name="Val" Text="--" FontSize="26" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{DynamicResource TextBrush}"/>
    </Grid>
    <TextBlock x:Name="Sub" Text=" " FontSize="11.5" TextAlignment="Center" TextWrapping="Wrap" MinHeight="30" Foreground="{DynamicResource SubTextBrush}"/>
  </StackPanel>
</Border>
"@
    $b = [System.Windows.Markup.XamlReader]::Parse($x)
    $arc = $b.FindName('Arc')
    Set-Arc ($b.FindName('Track')) 1.0
    Set-Arc $arc 0.003
    $script:Gauges[$key] = [pscustomobject]@{ Arc = $arc; Val = $b.FindName('Val'); Sub = $b.FindName('Sub') }
    return $b
}

function New-NetTile {
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="180" Margin="0,0,12,12" CornerRadius="14" Padding="14,12" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <StackPanel>
    <TextBlock Text="Network" FontWeight="SemiBold" FontSize="13" Foreground="{DynamicResource TextBrush}"/>
    <TextBlock Text="Download" Margin="0,22,0,0" FontSize="11.5" Foreground="{DynamicResource SubTextBrush}"/>
    <TextBlock x:Name="NetDownTb" Text="--" FontSize="22" FontWeight="Bold" Foreground="#34C759"/>
    <TextBlock Text="Upload" Margin="0,14,0,0" FontSize="11.5" Foreground="{DynamicResource SubTextBrush}"/>
    <TextBlock x:Name="NetUpTb" Text="--" FontSize="22" FontWeight="Bold" Foreground="#0A84FF"/>
    <TextBlock Text=" " Margin="0,0,0,14"/>
  </StackPanel>
</Border>
"@
    $b = [System.Windows.Markup.XamlReader]::Parse($x)
    $script:NetDownTb = $b.FindName('NetDownTb')
    $script:NetUpTb = $b.FindName('NetUpTb')
    return $b
}

function New-InfoCard($pairs) {
    $rows = ''
    foreach ($kv in $pairs) {
        $l = [Security.SecurityElement]::Escape([string]$kv[0])
        $v = [Security.SecurityElement]::Escape([string]$kv[1])
        $rows += "<Grid Margin=`"0,4`"><Grid.ColumnDefinitions><ColumnDefinition Width=`"90`"/><ColumnDefinition Width=`"*`"/></Grid.ColumnDefinitions><TextBlock Text=`"$l`" Foreground=`"{DynamicResource SubTextBrush}`"/><TextBlock Grid.Column=`"1`" Text=`"$v`" TextWrapping=`"Wrap`" Foreground=`"{DynamicResource TextBrush}`"/></Grid>"
    }
    $x = "<Border xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" CornerRadius=`"14`" Padding=`"16,10`" Margin=`"0,0,0,8`" Background=`"{DynamicResource CardBrush}`" BorderBrush=`"{DynamicResource CardBorderBrush}`" BorderThickness=`"1`"><StackPanel>$rows</StackPanel></Border>"
    return [System.Windows.Markup.XamlReader]::Parse($x)
}

function New-DriveCard([string]$title, [string]$right, [double]$usedFrac) {
    $t = [Security.SecurityElement]::Escape($title)
    $r = [Security.SecurityElement]::Escape($right)
    if ($usedFrac -lt 0.001) { $usedFrac = 0.001 }
    if ($usedFrac -gt 0.999) { $usedFrac = 0.999 }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $u = $usedFrac.ToString('0.0000', $inv)
    $f = (1.0 - $usedFrac).ToString('0.0000', $inv)
    $col = if ($usedFrac -lt 0.7) { '#34C759' } elseif ($usedFrac -lt 0.9) { '#FF9F0A' } else { '#FF3B30' }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="12" Padding="16,12" Margin="0,0,0,8" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <StackPanel>
    <DockPanel>
      <TextBlock DockPanel.Dock="Right" Text="$r" FontSize="12" Foreground="{DynamicResource SubTextBrush}"/>
      <TextBlock Text="$t" FontWeight="SemiBold" FontSize="13.5" Foreground="{DynamicResource TextBrush}"/>
    </DockPanel>
    <Grid Height="8" Margin="0,8,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="${u}*"/>
        <ColumnDefinition Width="${f}*"/>
      </Grid.ColumnDefinitions>
      <Border CornerRadius="4,0,0,4" Background="$col"/>
      <Border Grid.Column="1" CornerRadius="0,4,4,0" Background="#33808080"/>
    </Grid>
  </StackPanel>
</Border>
"@
    return [System.Windows.Markup.XamlReader]::Parse($x)
}

function Format-Rate([double]$bps) {
    if ($bps -ge 1MB) { return ('{0:N1} MB/s' -f ($bps / 1MB)) }
    return ('{0:N0} KB/s' -f ($bps / 1KB))
}

function Get-VramTotalGB {
    try {
        # Laptops list an integrated and a dedicated adapter: the largest one is the dedicated card
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $best = [double]0
        foreach ($k in (Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
            $v = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
            if ($v) {
                if ($v -is [byte[]]) { $v = [BitConverter]::ToUInt64($v, 0) }
                if ([double]$v -gt $best) { $best = [double]$v }
            }
        }
        if ($best -gt 0) { return [math]::Round($best / 1GB, 0) }
    } catch { }
    return $null
}

function Load-Dash {
    $list = Get-El 'ListDash'
    $list.Children.Clear()
    $script:Gauges = @{}
    Set-Status 'Reading hardware info...'

    $cpuName = 'Unknown'; $cores = 0; $threads = 0
    $gpuName = 'Unknown'; $boardText = 'Unknown'; $osText = 'Windows'; $memText = 'Unknown'
    try {
        $c = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cpuName = ([string]$c.Name).Trim(); $cores = $c.NumberOfCores; $threads = $c.NumberOfLogicalProcessors
    } catch { }
    try {
        $g = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual|Meta' }) | Select-Object -First 1
        if ($g) { $gpuName = [string]$g.Name }
    } catch { }
    $vram = Get-VramTotalGB
    try {
        $mem = @(Get-CimInstance Win32_PhysicalMemory)
        $cap = ($mem | Measure-Object -Property Capacity -Sum).Sum
        $spd = ($mem | Select-Object -First 1).ConfiguredClockSpeed
        if (-not $spd) { $spd = ($mem | Select-Object -First 1).Speed }
        $memText = ('{0:N0} GB ({1} sticks) at {2} MHz' -f ($cap / 1GB), $mem.Count, $spd)
    } catch { }
    try { $b = Get-CimInstance Win32_BaseBoard; $boardText = (([string]$b.Manufacturer) + ' ' + ([string]$b.Product)).Trim() } catch { }
    try { $o = Get-CimInstance Win32_OperatingSystem; $osText = ('{0} (build {1})' -f $o.Caption, $o.BuildNumber) } catch { }

    $script:DashStatic = @{
        CpuSub = "$cores cores / $threads threads"
        GpuName = $gpuName
        VramTotal = $vram
    }

    [void]$list.Children.Add((New-Header 'Live'))
    $wrap = [System.Windows.Markup.XamlReader]::Parse('<WrapPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Orientation="Horizontal"/>')
    [void]$wrap.Children.Add((New-Gauge 'CPU' 'CPU'))
    [void]$wrap.Children.Add((New-Gauge 'GPU' 'GPU (3D load)'))
    [void]$wrap.Children.Add((New-Gauge 'VRAM' 'GPU memory'))
    [void]$wrap.Children.Add((New-Gauge 'RAM' 'Memory'))
    [void]$wrap.Children.Add((New-Gauge 'DISK' 'Disk activity'))
    [void]$wrap.Children.Add((New-NetTile))
    [void]$list.Children.Add($wrap)

    [void]$list.Children.Add((New-Header 'System'))
    $pairs = @(
        @('CPU', $cpuName),
        @('GPU', $(if ($vram) { "$gpuName ($vram GB)" } else { $gpuName })),
        @('Memory', $memText),
        @('Board', $boardText),
        @('Windows', $osText)
    )
    [void]$list.Children.Add((New-InfoCard $pairs))

    [void]$list.Children.Add((New-Header 'Storage'))
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
            $total = [double]$d.TotalSize; $free = [double]$d.AvailableFreeSpace
            $label = if ($d.VolumeLabel) { $d.Name + '  ' + $d.VolumeLabel } else { $d.Name }
            $right = ('{0:N0} GB free of {1:N0} GB' -f ($free / 1GB), ($total / 1GB))
            [void]$list.Children.Add((New-DriveCard $label $right (($total - $free) / $total)))
        } catch { }
    }
    Set-Status 'Dashboard ready.'
}

function Start-Sampler {
    $script:Stats = [hashtable]::Synchronized(@{ Run = $true })
    $script:BgPs = @()
    foreach ($txt in @($script:BgFast, $script:BgGpu)) {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($txt).AddArgument($script:Stats)
        [void]$ps.BeginInvoke()
        $script:BgPs += $ps
    }
}

function Stop-Sampler {
    try { $script:Stats.Run = $false } catch { }
    foreach ($ps in $script:BgPs) { try { [void]$ps.BeginStop($null, $null) } catch { } }
    $script:BgPs = @()
}

function Set-Gauge([string]$key, $pct, [string]$sub) {
    $g = $script:Gauges[$key]
    if (-not $g) { return }
    if ($null -eq $pct) {
        $v = 0.0; $col = '#8E8E93'; $text = 'n/a'
    } else {
        $v = [math]::Max(0.0, [math]::Min(100.0, [double]$pct)) / 100.0
        $col = if ($v -lt 0.6) { '#34C759' } elseif ($v -lt 0.85) { '#FF9F0A' } else { '#FF3B30' }
        $text = ('{0:N0}%' -f ($v * 100.0))
    }
    Set-Arc $g.Arc $v
    $g.Arc.Stroke = Get-Brush $col
    $g.Val.Text = $text
    $g.Sub.Text = $sub
}

function Update-Dashboard {
    try {
        $s = $script:Stats
        if (-not $s) { return }
        if ((Get-El 'TabDash').Visibility -ne 'Visible') { return }
        $d = $script:DashStatic

        Set-Gauge 'CPU' $s.Cpu ([string]$d.CpuSub)
        Set-Gauge 'GPU' $s.Gpu ([string]$d.GpuName)

        if ($null -ne $s.VramUsed) {
            $usedGB = [double]$s.VramUsed / 1GB
            if ($d.VramTotal) { Set-Gauge 'VRAM' (($usedGB / [double]$d.VramTotal) * 100.0) ('{0:N1} / {1:N0} GB' -f $usedGB, $d.VramTotal) }
            else { Set-Gauge 'VRAM' $null ('{0:N1} GB in use' -f $usedGB) }
        } else { Set-Gauge 'VRAM' $null 'not available' }

        if ($s.RamTotal) { Set-Gauge 'RAM' (([double]$s.RamUsed / [double]$s.RamTotal) * 100.0) ('{0:N1} / {1:N1} GB' -f $s.RamUsed, $s.RamTotal) }
        Set-Gauge 'DISK' $s.Disk 'time the disk is busy'

        if ($script:NetDownTb -and $null -ne $s.NetDown) {
            $script:NetDownTb.Text = Format-Rate ([double]$s.NetDown)
            $script:NetUpTb.Text = Format-Rate ([double]$s.NetUp)
        }
    } catch {
        if (-not $script:DashErr) { $script:DashErr = $true; Write-Log ('Dashboard update failed: ' + $_) }
    }
}

# ============================================================
#  Tune-Up (simple mode) and Simple/Advanced switch
# ============================================================
$script:SafeStartupPattern = 'Spotify|Teams|MicrosoftEdgeAutoLaunch|Skype|AdobeAAMUpdater|Adobe Creative Cloud|CCXProcess|EpicGamesLauncher|YourPhone|PhoneLink|iTunesHelper|Cortana|Webex'
$script:TuneRows = @()
$script:TunePlan = @{}

function Get-StartupEntries {
    $out = @()
    foreach ($src in $script:StartupRunKeys) {
        $k = Get-Item -LiteralPath $src.Path -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            $out += [pscustomobject]@{ Name = $n; Cmd = [string]$k.GetValue($n); Key = $src.Approved; Enabled = (Get-Approved $src.Approved $n) }
        }
    }
    foreach ($f in $script:StartupFolders) {
        if (-not (Test-Path -LiteralPath $f.Dir)) { continue }
        Get-ChildItem -LiteralPath $f.Dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            $out += [pscustomobject]@{ Name = $_.Name; Cmd = $_.FullName; Key = $f.Approved; Enabled = (Get-Approved $f.Approved $_.Name) }
        }
    }
    return ,$out
}

function Join-Short($items, [int]$max = 110) {
    $t = (@($items) -join ', ')
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max) + '...' }
    return $t
}

function Load-Tune {
    $list = Get-El 'ListTune'
    $list.Children.Clear()
    $script:TuneRows = @()
    Set-Status 'Scanning your PC, one moment...'
    [void]$list.Children.Add((New-Header 'Here is what the tune-up will do. Untick anything you want to skip'))

    # 1. temp files
    $cleanTargets = @($script:CleanTargets | Where-Object { $_.Default -and -not $_.Special })
    $bytes = [long]0
    foreach ($t in $cleanTargets) { $bytes += (Get-PathSize $t.Paths); Pump }

    # 2. background services (safe list only)
    $svcs = @(); $svcNames = @()
    foreach ($e in @($script:Catalogue | Where-Object { $_.C -eq 'Safe' })) {
        $sv = Get-Service -Name $e.N -ErrorAction SilentlyContinue
        if ($sv -and (([string]$sv.StartType -eq 'Automatic') -or ($sv.Status -eq 'Running'))) { $svcs += $e.N; $svcNames += $sv.DisplayName }
    }

    # 3. startup apps (only a short list of well-known time wasters)
    $entries = @(Get-StartupEntries)
    $starts = @($entries | Where-Object {
        $_.Enabled -and (("$($_.Name) $($_.Cmd)") -match $script:SafeStartupPattern) -and (("$($_.Name) $($_.Cmd)") -notmatch $script:KeepPattern)
    })
    Pump

    # 4. preinstalled junk apps
    $bloat = @()
    try {
        $bloat = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System' -and ($_.Name -notmatch $script:ProtectPattern) -and (Test-IsBloat ([string]$_.Name))
        })
    } catch { }
    $bloatNames = @($bloat | ForEach-Object { (Get-FriendlyApp $_).Title })

    $script:TunePlan = @{ Clean = $cleanTargets; Bytes = $bytes; Svcs = $svcs; Starts = $starts; Bloat = $bloat }

    $green = '#3328C840'; $greenFg = '#1F9D3A'; $grey = '#22808080'; $greyFg = '#808080'; $orange = '#33FF9500'; $orangeFg = '#C77700'

    $r1 = New-Row -Title 'Clean temporary files' -Desc 'Temp files, update leftovers, crash dumps and browser caches. Your documents are never touched.' -Badge ('Frees ' + (Format-Size $bytes)) -BadgeBg $green -BadgeFg $greenFg -Checked ($bytes -gt 0)
    $r2 = if ($svcs.Count -gt 0) {
        New-Row -Title 'Switch off unneeded background services' -Desc (Join-Short $svcNames) -Badge ("$($svcs.Count) services") -BadgeBg $green -BadgeFg $greenFg -Checked $true
    } else {
        New-Row -Title 'Switch off unneeded background services' -Desc 'Nothing to do, already tidy.' -Badge 'Done' -BadgeBg $grey -BadgeFg $greyFg -Checked $false
    }
    $r3 = if ($starts.Count -gt 0) {
        New-Row -Title 'Stop slow apps launching at startup' -Desc ((Join-Short @($starts | ForEach-Object { $_.Name })) + '. You can still open them yourself.') -Badge ("$($starts.Count) apps") -BadgeBg $green -BadgeFg $greenFg -Checked $true
    } else {
        New-Row -Title 'Stop slow apps launching at startup' -Desc 'Nothing to do, no known time wasters found.' -Badge 'Done' -BadgeBg $grey -BadgeFg $greyFg -Checked $false
    }
    $r4 = if ($bloat.Count -gt 0) {
        New-Row -Title 'Remove preinstalled junk apps' -Desc ((Join-Short $bloatNames) + '. Only apps that came with Windows or your PC. Can be reinstalled from the Store, off by default.') -Badge ("$($bloat.Count) apps") -BadgeBg $orange -BadgeFg $orangeFg -Checked $false
    } else {
        New-Row -Title 'Remove preinstalled junk apps' -Desc 'Nothing to do, no junk apps found.' -Badge 'Done' -BadgeBg $grey -BadgeFg $greyFg -Checked $false
    }
    if ($bytes -le 0) { $r1.Check.IsEnabled = $false }
    if ($svcs.Count -eq 0) { $r2.Check.IsEnabled = $false }
    if ($starts.Count -eq 0) { $r3.Check.IsEnabled = $false }
    if ($bloat.Count -eq 0) { $r4.Check.IsEnabled = $false }

    $script:TuneRows = @(
        [pscustomobject]@{ Id = 'Clean'; Check = $r1.Check },
        [pscustomobject]@{ Id = 'Svc'; Check = $r2.Check },
        [pscustomobject]@{ Id = 'Start'; Check = $r3.Check },
        [pscustomobject]@{ Id = 'Apps'; Check = $r4.Check }
    )
    foreach ($r in @($r1, $r2, $r3, $r4)) { [void]$list.Children.Add($r.Root) }
    Set-Status 'Scan complete. Review the list and press Run tune-up.'
}

function Do-TuneUp {
    $plan = $script:TunePlan
    $on = @{}
    foreach ($r in $script:TuneRows) { $on[$r.Id] = [bool]$r.Check.IsChecked }
    if (-not ($on.Values -contains $true)) { Show-Msg 'Nothing is ticked.'; return }
    if (-not (Confirm-Msg "Run the tune-up with the ticked items?`n`nA restore point is created first, and service and startup changes can be undone from the Advanced tabs.")) { return }

    Set-Status 'Creating a restore point (up to a minute)...'
    $rp = New-RestorePoint
    $freed = [long]0; $svcCount = 0; $startCount = 0; $appCount = 0

    if ($on['Clean']) {
        foreach ($t in $plan.Clean) {
            Set-Status ('Cleaning ' + $t.Name + '...')
            $freed += Clear-Target $t
        }
    }
    if ($on['Svc']) {
        $backup = Get-Backup
        foreach ($name in $plan.Svcs) {
            try {
                $svc = Get-Service -Name $name -ErrorAction Stop
                if (-not $backup.ContainsKey($name)) {
                    $backup[$name] = @{ StartType = [string]$svc.StartType; Delayed = (Test-Delayed $name) }
                    Save-Backup $backup
                }
                Set-Status "Switching off $name..."
                if ($svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
                Set-Service -Name $name -StartupType Manual -ErrorAction Stop
                $svcCount++
            } catch { Write-Log ("Tune-up service failed $name : " + $_) }
        }
        Save-Backup $backup
    }
    if ($on['Start']) {
        foreach ($e in $plan.Starts) {
            try { Set-Approved $e.Key $e.Name $false; $startCount++ } catch { Write-Log ("Tune-up startup failed " + $e.Name + ': ' + $_) }
        }
    }
    if ($on['Apps']) {
        foreach ($p in $plan.Bloat) {
            Set-Status ('Removing ' + (Get-FriendlyApp $p).Title + '...')
            try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $appCount++ } catch { Write-Log ("Tune-up app failed " + $p.Name + ': ' + $_) }
        }
    }

    $list = Get-El 'ListTune'
    $list.Children.Clear()
    [void]$list.Children.Add((New-Header 'Tune-up complete'))
    $rpText = if ($rp) { 'Created, so you can roll back if needed' } else { 'Skipped (System Protection is off, or Windows refused it)' }
    $pairs = @(
        @('Space freed', (Format-Size $freed)),
        @('Services', "$svcCount switched to on-demand"),
        @('Startup', "$startCount apps stopped from auto-starting"),
        @('Apps removed', "$appCount"),
        @('Restore point', $rpText),
        @('Next step', 'Restart your PC so everything takes effect.')
    )
    [void]$list.Children.Add((New-InfoCard $pairs))
    Add-Activity 'Tune-Up' ("Freed " + (Format-Size $freed) + ", $svcCount service(s) to on-demand, $startCount startup app(s) stopped, $appCount app(s) removed, restore point: $rp")
    Update-SysInfo
    Set-Status ('Done. Freed ' + (Format-Size $freed) + '. Restart your PC to finish.')
}

# Dark mode and Advanced mode are remembered between launches. With no saved choice, dark mode follows Windows.
$script:RestoringUi = $false
function Save-UiSettings {
    if ($script:RestoringUi) { return }
    try {
        $o = [ordered]@{ Dark = [bool](Get-El 'ThemeSwitch').IsChecked; Advanced = [bool](Get-El 'AdvSwitch').IsChecked }
        $o | ConvertTo-Json | Set-Content -LiteralPath $script:UiFile -Encoding UTF8
    } catch { Write-Log ('Save UI settings: ' + $_) }
}

function Restore-UiSettings {
    $script:RestoringUi = $true
    try {
        $dark = $false
        $adv = $false
        $saved = $null
        if (Test-Path -LiteralPath $script:UiFile) { try { $saved = Get-Content -LiteralPath $script:UiFile -Raw | ConvertFrom-Json } catch { } }
        if ($saved -and ($null -ne $saved.Dark)) { $dark = [bool]$saved.Dark; $adv = [bool]$saved.Advanced }
        else {
            $light = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'
            if ($null -ne $light -and [int]$light -eq 0) { $dark = $true }
        }
        (Get-El 'ThemeSwitch').IsChecked = $dark
        (Get-El 'AdvSwitch').IsChecked = $adv
    } catch { Write-Log ('Restore UI settings: ' + $_) }
    finally { $script:RestoringUi = $false }
}

function Do-WinDrag { try { (Get-El 'Tint') | Out-Null; $script:Win.DragMove() } catch { Write-Log ('Drag: ' + $_) } }
function Do-WinClose { $script:Win.Close() }
function Do-WinMin { $script:Win.WindowState = [System.Windows.WindowState]::Minimized }
function Do-WinMax {
    if ($script:Win.WindowState -eq [System.Windows.WindowState]::Maximized) { $script:Win.WindowState = [System.Windows.WindowState]::Normal }
    else { $script:Win.WindowState = [System.Windows.WindowState]::Maximized }
}

# Hover menu on the green dot (like macOS tiling): pick where the window goes on the screen it is on.
function Move-WinTo([double]$x, [double]$y, [double]$w, [double]$h) {
    Add-Type -AssemblyName System.Windows.Forms
    $sc = [System.Windows.Interop.HwndSource]::FromHwnd($script:Hwnd).CompositionTarget.TransformToDevice.M11
    $wa = [System.Windows.Forms.Screen]::FromHandle($script:Hwnd).WorkingArea
    $script:Win.WindowState = [System.Windows.WindowState]::Normal
    $script:Win.Left = ($wa.X + $wa.Width * $x) / $sc
    $script:Win.Top = ($wa.Y + $wa.Height * $y) / $sc
    $script:Win.Width = $wa.Width * $w / $sc
    $script:Win.Height = $wa.Height * $h / $sc
}

function Initialize-SnapMenu {
    $dot = Get-El 'DotMax'
    $pop = New-Object System.Windows.Controls.Primitives.Popup
    $pop.PlacementTarget = $dot
    $pop.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $pop.VerticalOffset = 6
    $pop.StaysOpen = $true
    $pop.AllowsTransparency = $true
    $frame = New-Object System.Windows.Controls.Border
    $frame.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $frame.Padding = New-Object System.Windows.Thickness(8)
    $frame.Margin = New-Object System.Windows.Thickness(10)
    $frame.BorderThickness = New-Object System.Windows.Thickness(1)
    $frame.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 14; ShadowDepth = 3; Opacity = 0.3 }
    $grid = New-Object System.Windows.Controls.Primitives.UniformGrid
    $grid.Columns = 3
    $frame.Child = $grid
    $pop.Child = $frame
    $script:SnapPop = $pop
    $script:SnapDot = $dot
    $script:SnapFrame = $frame

    # name, x, y, w, h (fractions of the screen work area)
    $spots = @(
        @('Fill screen', 0, 0, 1, 1), @('Left half', 0, 0, 0.5, 1), @('Right half', 0.5, 0, 0.5, 1),
        @('Top half', 0, 0, 1, 0.5), @('Bottom half', 0, 0.5, 1, 0.5), @('Top left', 0, 0, 0.5, 0.5),
        @('Top right', 0.5, 0, 0.5, 0.5), @('Bottom left', 0, 0.5, 0.5, 0.5), @('Bottom right', 0.5, 0.5, 0.5, 0.5)
    )
    $pill = $script:Win.FindResource('Pill')
    foreach ($s in $spots) {
        $cv = New-Object System.Windows.Controls.Canvas
        $cv.Width = 48; $cv.Height = 30
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = 48 * $s[3] - 3; $r.Height = 30 * $s[4] - 3
        $r.RadiusX = 3; $r.RadiusY = 3
        $r.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'AccentBrush')
        [System.Windows.Controls.Canvas]::SetLeft($r, 48 * $s[1] + 1.5)
        [System.Windows.Controls.Canvas]::SetTop($r, 30 * $s[2] + 1.5)
        [void]$cv.Children.Add($r)
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $pill
        $b.Padding = New-Object System.Windows.Thickness(3)
        $b.Margin = New-Object System.Windows.Thickness(3)
        $b.Content = $cv
        $b.ToolTip = $s[0]
        [System.Windows.Automation.AutomationProperties]::SetName($b, $s[0])
        $b.Tag = $s
        $b.Add_Click({
            try { $t = $args[0].Tag; $script:SnapPop.IsOpen = $false; Move-WinTo $t[1] $t[2] $t[3] $t[4] }
            catch { Write-Log ('Snap: ' + $_) }
        })
        [void]$grid.Children.Add($b)
    }

    $script:SnapGone = 0
    $script:SnapTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SnapTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:SnapTimer.Add_Tick({
        $over = $script:SnapDot.IsMouseOver -or ($script:SnapPop.IsOpen -and $script:SnapFrame.IsMouseOver)
        if ($over) {
            $script:SnapGone = 0
            if (-not $script:SnapPop.IsOpen) {
                $script:SnapFrame.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($script:Dark) { '#F02C2C2E' } else { '#F0F5F5F7' })))
                $script:SnapFrame.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#22000000'))
                $script:SnapPop.IsOpen = $true
            }
        } else {
            $script:SnapGone++
            if ($script:SnapGone -ge 2) { $script:SnapPop.IsOpen = $false; $script:SnapTimer.Stop() }
        }
    })
    $dot.Add_MouseEnter({ $script:SnapGone = 0; $script:SnapTimer.Start() })
}

function Set-AdvancedMode([bool]$on) {
    $vis = if ($on) { 'Visible' } else { 'Collapsed' }
    foreach ($n in @('NavSvc', 'NavStart', 'NavApps', 'NavClean', 'NavPriv', 'NavUpd')) { (Get-El $n).Visibility = $vis }
    if (-not $on) {
        foreach ($t in @('Svc', 'Start', 'Apps', 'Clean', 'Priv', 'Upd')) {
            if ((Get-El "Tab$t").Visibility -eq 'Visible') { Select-Tab 'Tune'; break }
        }
    }
}

# ============================================================
#  Activity log
# ============================================================
$script:AppVersion = '2.6'
$script:ActFile = Join-Path $script:DataDir 'activity.log'
$script:LogBox = $null
$script:SelfHash = $null

function Add-Activity([string]$area, [string]$msg) {
    try {
        $line = '{0} | {1,-9} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $area, $msg
        Add-Content -Path $script:ActFile -Value $line -Encoding UTF8
        if ((Get-Item -LiteralPath $script:ActFile).Length -gt 512KB) {
            $keep = @(Get-Content -LiteralPath $script:ActFile -Tail 1000)
            Set-Content -Path $script:ActFile -Value $keep -Encoding UTF8
        }
    } catch { }
}

function Get-SelfPath {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) { return $PSCommandPath }
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($p -and ($p -notmatch 'powershell|pwsh')) { return $p }
    } catch { }
    return $null
}

function Invoke-SafeBlock([scriptblock]$b) {
    try { & $b } catch {
        Write-Log ('action: ' + ($_ | Out-String))
        [void][System.Windows.MessageBox]::Show(("Something went wrong:`n`n" + ($_ | Out-String)), 'PC Optimizer', 'OK', 'Error')
    }
}

# A card with a title, a description and a button on the right
function New-ActionRow {
    param([string]$Title, [string]$Desc, [string]$BtnText, [scriptblock]$Action)
    $t = [Security.SecurityElement]::Escape($Title)
    $d = [Security.SecurityElement]::Escape($Desc)
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="12" Padding="16,12" Margin="0,0,0,8" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock Text="$t" FontWeight="SemiBold" FontSize="13.5" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource TextBrush}"/>
      <TextBlock Text="$d" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0" Foreground="{DynamicResource SubTextBrush}"/>
    </StackPanel>
    <Button Grid.Column="1" VerticalAlignment="Center" MinWidth="84"/>
  </Grid>
</Border>
"@
    $border = [System.Windows.Markup.XamlReader]::Parse($x)
    $btn = $border.Child.Children[1]
    $btn.Style = $script:Win.FindResource('Pill')
    $btn.Content = $BtnText
    $btn.Tag = $Action
    $btn.Add_Click({ param($s, $e) Invoke-SafeBlock ($s.Tag) })
    return [pscustomobject]@{ Root = $border; Button = $btn }
}

function Add-Action($list, [string]$title, [string]$desc, [string]$btn, [scriptblock]$act) {
    $r = New-ActionRow -Title $title -Desc $desc -BtnText $btn -Action $act
    [void]$list.Children.Add($r.Root)
}

function Load-Log {
    $list = Get-El 'ListLog'
    $list.Children.Clear()
    $self = Get-SelfPath
    $hash = 'not available'
    if ($self) {
        if (-not $script:SelfHash) { try { $script:SelfHash = (Get-FileHash -LiteralPath $self -Algorithm SHA256).Hash } catch { } }
        if ($script:SelfHash) { $hash = $script:SelfHash }
    }
    $fname = 'unknown'
    if ($self) { $fname = Split-Path $self -Leaf }
    [void]$list.Children.Add((New-Header 'About this copy'))
    [void]$list.Children.Add((New-InfoCard @(
        @('Version', $script:AppVersion),
        @('File', $fname),
        @('SHA256', $hash),
        @('Updates', $(if (Test-UpdateConfigured) { 'from github.com/' + $script:UpdateRepo + ' (only if signed by the author)' } else { 'not set up' })),
        @('Check', 'Compare the SHA256 with the one on the Releases page. If it is different, do not trust this copy.'),
        @('Data folder', $script:DataDir)
    )))
    [void]$list.Children.Add((New-Header 'Activity log: everything this tool changed on this PC, newest first'))
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="12" Padding="12" Margin="0,0,0,8" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <TextBox IsReadOnly="True" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" MinHeight="200" MaxHeight="380" FontFamily="Consolas" FontSize="12" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource TextBrush}"/>
</Border>
"@
    $b = [System.Windows.Markup.XamlReader]::Parse($x)
    $script:LogBox = $b.Child
    $lines = @()
    if (Test-Path -LiteralPath $script:ActFile) { $lines = @(Get-Content -LiteralPath $script:ActFile -Tail 300 -ErrorAction SilentlyContinue) }
    if ($lines.Count -eq 0) {
        $script:LogBox.Text = 'Nothing yet. Changes made with this tool will be listed here.'
    } else {
        [array]::Reverse($lines)
        $script:LogBox.Text = ($lines -join "`r`n")
    }
    [void]$list.Children.Add($b)
}

function Do-CopyLog {
    if ($script:LogBox) {
        if (Set-ClipboardSafe ([string]$script:LogBox.Text)) { Set-Status 'Log copied to the clipboard.' }
        else { Set-Status 'Could not copy: another app is holding the clipboard. Try again.' }
    }
}

function Do-OpenData { Start-Process explorer.exe -ArgumentList ('"' + $script:DataDir + '"') }

# ============================================================
#  Self-update from GitHub (only ever on request, and verified)
# ============================================================
$script:UpdateRepo = 'StrixEvo/PC-Optimizer'
$script:UpdateBranch = 'main'
# Public half of the author's release-signing key. An update is only offered when version.json carries a signature
# made with the matching private key, which never leaves the author's PC. Anyone who can push to the repository
# can change version.json, but cannot produce this signature.
$script:UpdateKey = '<RSAKeyValue><Modulus>65XRRXWsB1MyuoQde5Vk9n0cOE8rc+PlHQ9xlX0Wi250AjycVQUU2zJimQqurV/VVYZ2GV1LnqhwS1DQncPqtRe1WJjxdYin/snYzExo0ddlMnc56z+xGbFj1s5e0vOlMLauEyf4xqW4yzvFidsQt4kD5MRUnvwNsQFFbLgLFvWfQtYlHOFQuLxa9x27PGFtQc0q1cjntCNomS02PrpAwgyr8vhMR3YSLvNXlq5T8FLz4q74dlFJdbyPM94UGdGsdM6iOd+MQRsagKzHq+RES1VDWQ9yzDpUYFhJLANNPxZoQ6q+GZa5VrGdhJRbeZo0bJN5r5iM8OHKv5q6I+HSH7LITeqgNu/he2/w4NQbxy4MYMz4BfvxCmPRFpY7PM+KATr+/eelMJHikL1OyvJyAevSAS9Yq3zqdaSCxr1PhiqHUtz7H3iUcKqpuAbDAnf//rLrchwcIo8TyYFuXRDtpYehv9pTq52922CrZLbqvsTI99D+Lzm3zHjTyIX8M4Vh</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

function Test-UpdateConfigured { return ($script:UpdateRepo -notlike 'YOUR-GITHUB-NAME*') }

# What the signature covers: version, both file hashes and a hash of the release notes (so the notes cannot be swapped)
function Get-InfoPayload($info) {
    $sha = New-Object System.Security.Cryptography.SHA256Managed
    $nh = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$info.notes))).Replace('-', '')
    return ('{0}|{1}|{2}|{3}' -f [string]$info.version, [string]$info.sha256, [string]$info.exeSha256, $nh)
}

function Test-InfoSignature($info) {
    try {
        if (-not $info -or -not $info.sig -or -not $info.exeSha256) { return $false }
        $v = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $v.FromXmlString($script:UpdateKey)
        $data = [System.Text.Encoding]::UTF8.GetBytes((Get-InfoPayload $info))
        return [bool]$v.VerifyData($data, 'SHA256', [Convert]::FromBase64String([string]$info.sig))
    } catch { Write-Log ('Signature check failed: ' + $_); return $false }
}

function ConvertTo-Info([string]$content) { return ($content.TrimStart([char]0xFEFF) | ConvertFrom-Json) }

# Run $act once nothing else is in progress (an update prompt must not appear in the middle of an action)
function Invoke-WhenIdle([scriptblock]$act) {
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(1)
    $t.Tag = $act
    $t.Add_Tick({
        param($s, $e)
        if ($script:Depth -gt 0) { return }
        $s.Stop()
        try { & $s.Tag } catch { Write-Log ('idle action: ' + $_) }
    })
    $t.Start()
}

# Updates are only for the .exe, which is what gets published
function Do-Update($info) {
    $self = Get-SelfPath
    if (-not $self -or $self -notlike '*.exe') {
        Show-Msg 'Self-update only works for PCOptimizer.exe. Download the new PCOptimizer.exe from the Releases page of the repository.'
        return
    }
    Do-UpdateExe $self $info
}

# The running .exe cannot overwrite itself, so a tiny helper swaps the file once the app has closed
function Do-UpdateExe([string]$self, $info) {
    if (-not (Test-InfoSignature $info)) { Show-Msg 'This update is not signed by the author, so it was not installed.'; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = "https://github.com/$($script:UpdateRepo)/releases/download/v$([string]$info.version)/PCOptimizer.exe"
    $new = Join-Path $script:DataDir 'PCOptimizer.new.exe'
    Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue      # never write into a file someone else created
    Set-Status 'Downloading the update...'
    Enter-Busy
    try { Invoke-WebRequest -Uri $url -OutFile $new -UseBasicParsing -TimeoutSec 60 } finally { Exit-Busy }
    $hash = (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash
    if ($hash -ne [string]$info.exeSha256) {
        Remove-Item -LiteralPath $new -ErrorAction SilentlyContinue
        Add-Activity 'Update' 'Rejected: .exe download did not match the signed fingerprint'
        Show-Msg "The download did not match the signed fingerprint, so it was NOT installed.`n`nTry again in a few minutes. GitHub can take a moment to refresh."
        return
    }
    $cmd = Join-Path $script:DataDir 'apply-update.cmd'
    Remove-Item -LiteralPath $cmd -Force -ErrorAction SilentlyContinue
    $lines = @(
        '@echo off',
        'ping -n 3 127.0.0.1 >nul',
        ('copy /y "' + $self + '" "' + $self + '.bak" >nul 2>&1'),
        'set N=0',
        ':retry',
        ('copy /y "' + $new + '" "' + $self + '" >nul 2>&1'),
        'if not errorlevel 1 goto ok',
        'set /a N+=1',
        'if %N% GEQ 30 exit /b 1',
        'ping -n 2 127.0.0.1 >nul',
        'goto retry',
        ':ok',
        ('del "' + $new + '" >nul 2>&1'),
        ('start "" "' + $self + '"'),
        'exit /b 0'
    )
    Set-Content -LiteralPath $cmd -Value $lines -Encoding ASCII
    Add-Activity 'Update' ("Updating .exe from " + $script:AppVersion + " to " + [string]$info.version)
    Show-Msg "Version $($info.version) is ready. The app will close and reopen in a few seconds.`n`nYour previous version is kept as PCOptimizer.exe.bak. Windows may ask for permission again."
    Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $cmd + '"') -WindowStyle Hidden
    $script:Win.Close()
}

$script:UpdChecking = $false
$script:UpdSilent = $false

# The network request runs on another thread so the window never freezes while GitHub answers
function Do-CheckUpdate {
    param([bool]$Silent = $false)
    if (-not (Test-UpdateConfigured)) {
        if (-not $Silent) { Show-Msg 'Updates are not set up in this copy yet.' }
        return
    }
    if ($script:UpdChecking) { return }
    $script:UpdChecking = $true
    $script:UpdSilent = $Silent
    Set-Status 'Checking for updates...'
    $url = "https://raw.githubusercontent.com/$($script:UpdateRepo)/$($script:UpdateBranch)/version.json"
    Invoke-Background {
        param($u)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $err = ''
        for ($i = 0; $i -lt 2; $i++) {
            try {
                $req = [Net.HttpWebRequest]::Create($u)
                $req.Timeout = 15000
                $req.UserAgent = 'PCOptimizer'
                $req.Headers.Add('Cache-Control', 'no-cache')
                $resp = $req.GetResponse()
                try { $rd = New-Object IO.StreamReader($resp.GetResponseStream()); return ('OK:' + $rd.ReadToEnd()) }
                finally { $resp.Close() }
            } catch { $err = [string]$_.Exception.Message; Start-Sleep -Seconds 2 }
        }
        return ('ERR:' + $err)
    } {
        param($res)
        $script:UpdChecking = $false
        $content = $null
        if ($res -and @($res).Count -gt 0) {
            $txt = [string]@($res)[0]
            if ($txt.StartsWith('OK:')) { $content = $txt.Substring(3) } else { Write-Log ('Update fetch: ' + $txt) }
        }
        Invoke-WhenIdle { Show-UpdateResult $content $script:UpdSilent }
    } $url
}

function Show-UpdateResult([string]$content, [bool]$Silent) {
    try {
        if (-not $content) { throw 'No answer from GitHub.' }
        $info = ConvertTo-Info $content
        if (-not $info -or -not $info.version) { throw 'No version information found.' }
        if (-not (Test-InfoSignature $info)) {
            Add-Activity 'Update' 'Rejected: update information is not signed by the author'
            Set-Status 'An update was ignored because it is not signed by the author.'
            if (-not $Silent) { Show-Msg "The update information is not signed by the author, so it was ignored.`n`nOnly download PCOptimizer from the official Releases page." }
            return
        }
        if ([version][string]$info.version -le [version]$script:AppVersion) {
            Set-Status ('You are on the latest version (' + $script:AppVersion + ').')
            if (-not $Silent) { Show-Msg ("You are on the latest version (" + $script:AppVersion + ").") }
            return
        }
        $notes = ''
        if ($info.notes) { $notes = "`n`nWhat is new:`n" + [string]$info.notes }
        if (Confirm-Msg ("Version $($info.version) is available (you have $($script:AppVersion)).$notes`n`nUpdate now? The app restarts.")) { Do-Update $info }
        else { Set-Status 'Update skipped.' }
    } catch {
        Write-Log ('Update check failed: ' + $_)
        Set-Status 'Could not check for updates.'
        if (-not $Silent) { Show-Msg 'Could not check for updates. Check your internet connection and try again.' }
    }
}
function Do-CheckUpdateNow { Do-CheckUpdate -Silent $false }
function Do-CheckUpdateQuiet { Do-CheckUpdate -Silent $true }

# ============================================================
#  Registry tweaks engine (Privacy + Windows Update behaviour)
#  Every change is backed up first, so it can always be undone.
#  Note: HKCU entries apply to the account running the tool.
# ============================================================
$script:TweakFile = Join-Path $script:DataDir 'tweaks-backup.json'
$script:PrivRows = @()
$script:UpdRows = @()
$script:PrivLoaded = $false
$script:UpdLoaded = $false

$script:CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$script:WUPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

$script:PrivDefs = @(
    @{ Id='AdId'; T='Turn off the advertising ID'; D='Stops apps from tracking you across apps to show targeted ads.'; E=@(
        @{ P='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N='Enabled'; On=0; Off=1 }
    ) },
    @{ Id='Tailored'; T='No personalised tips from your diagnostic data'; D='Windows stops using your usage history to tailor ads and tips.'; E=@(
        @{ P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; N='TailoredExperiencesWithDiagnosticDataEnabled'; On=0; Off=1 }
    ) },
    @{ Id='Suggest'; T='Stop ads and app suggestions'; D='Removes suggested apps and promotions from Start, Settings and the lock screen, and stops silent installs of promoted apps.'; E=@(
        @{ P=$script:CDM; N='SubscribedContent-338388Enabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SubscribedContent-338389Enabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SubscribedContent-353694Enabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SubscribedContent-353696Enabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SubscribedContent-310093Enabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SubscribedContent-338387Enabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SystemPaneSuggestionsEnabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SilentInstalledAppsEnabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='SoftLandingEnabled'; On=0; Off=1 },
        @{ P=$script:CDM; N='RotatingLockScreenOverlayEnabled'; On=0; Off=1 }
    ) },
    @{ Id='Feedback'; T='Stop feedback pop-ups'; D='Windows stops asking you to rate it.'; E=@(
        @{ P='HKCU:\Software\Microsoft\Siuf\Rules'; N='NumberOfSIUFInPeriod'; On=0; Off=$null }
    ) },
    @{ Id='WebSearch'; T='Keep web results out of Start search'; D='Start menu search only looks at your PC, so it is faster and does not send what you type to Bing.'; E=@(
        @{ P='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; N='DisableSearchBoxSuggestions'; On=1; Off=$null }
    ) },
    @{ Id='Activity'; T='Turn off activity history'; D='Windows stops recording the apps and files you open and syncing that timeline.'; E=@(
        @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N='EnableActivityFeed'; On=0; Off=$null },
        @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N='PublishUserActivities'; On=0; Off=$null },
        @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N='UploadUserActivities'; On=0; Off=$null }
    ) },
    @{ Id='Telemetry'; T='Send the minimum diagnostic data'; D='Asks Windows to send only what it needs for security and updates. Home and Pro cannot go lower than this.'; E=@(
        @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N='AllowTelemetry'; On=0; Off=$null }
    ) },
    @{ Id='AI'; T='Turn off Recall and Copilot'; D='Stops Windows saving screen snapshots (Recall) and hides the Copilot sidebar.'; E=@(
        @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N='DisableAIDataAnalysis'; On=1; Off=$null },
        @{ P='HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; N='TurnOffWindowsCopilot'; On=1; Off=$null }
    ) }
)

$script:UpdDefs = @(
    @{ Id='NoReboot'; T='Never restart by itself while I am signed in'; D='Stops surprise restarts in the middle of work or a game. Updates still install, you restart when ready. Uses a Windows policy, so Settings may say "managed by your organization".'; E=@(
        @{ P=($script:WUPol + '\AU'); N='NoAutoRebootWithLoggedOnUsers'; On=1; Off=$null }
    ) },
    @{ Id='NoDrivers'; T='Stop Windows Update replacing my drivers'; D='Keeps Windows from swapping your graphics driver for an older one. Update drivers from AMD, NVIDIA or Intel yourself.'; E=@(
        @{ P=$script:WUPol; N='ExcludeWUDriversInQualityUpdate'; On=1; Off=$null }
    ) },
    @{ Id='NoShare'; T='Do not upload updates to other PCs'; D='Turns off peer-to-peer sharing so your upload bandwidth is not used.'; E=@(
        @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N='DODownloadMode'; On=0; Off=$null }
    ) },
    @{ Id='Defer'; T='Wait 60 days for big feature updates'; D='Lets other people find the bugs first. Monthly security updates still install normally. Windows Home ignores this one, and Settings will say "managed by your organization".'; E=@(
        @{ P=$script:WUPol; N='DeferFeatureUpdates'; On=1; Off=$null },
        @{ P=$script:WUPol; N='DeferFeatureUpdatesPeriodInDays'; On=60; Off=$null }
    ) }
)

function Get-TweakBackup {
    $h = @{}
    if (Test-Path -LiteralPath $script:TweakFile) {
        try {
            $obj = Get-Content -LiteralPath $script:TweakFile -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = @{ Existed = [bool]$p.Value.Existed; Value = [int]$p.Value.Value } }
        } catch { }
    }
    return $h
}

function Save-TweakBackup($h) {
    if ($h.Count -eq 0) { Remove-Item -LiteralPath $script:TweakFile -ErrorAction SilentlyContinue; return }
    $h | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:TweakFile -Encoding UTF8
}

function Get-TweakState($tw) {
    foreach ($e in $tw.E) {
        $v = Get-RegVal $e.P $e.N
        if ($null -eq $v) { return $false }
        $n = 0
        if (-not [int]::TryParse([string]$v, [ref]$n)) { return $false }     # a value that is not a number counts as "not set"
        if ($n -ne [int]$e.On) { return $false }
    }
    return $true
}

function Restore-Entry($e, $bk) {
    $key = $e.P + '|' + $e.N
    if ($bk.ContainsKey($key)) {
        if ($bk[$key].Existed) { Set-RegVal $e.P $e.N $bk[$key].Value }
        else { Remove-ItemProperty -LiteralPath $e.P -Name $e.N -ErrorAction SilentlyContinue }
        $bk.Remove($key)
        return $true
    }
    return $false
}

function Set-TweakState($tw, [bool]$on) {
    $bk = Get-TweakBackup
    foreach ($e in $tw.E) {
        $key = $e.P + '|' + $e.N
        if ($on) {
            if (-not $bk.ContainsKey($key)) {
                $cur = Get-RegVal $e.P $e.N
                $existed = ($null -ne $cur)
                $val = 0
                if ($existed) { $n = 0; if ([int]::TryParse([string]$cur, [ref]$n)) { $val = $n } }
                $bk[$key] = @{ Existed = $existed; Value = $val }
                Save-TweakBackup $bk
            }
            Set-RegVal $e.P $e.N $e.On
        } else {
            if (-not (Restore-Entry $e $bk)) {
                if ($null -eq $e.Off) { Remove-ItemProperty -LiteralPath $e.P -Name $e.N -ErrorAction SilentlyContinue }
                else { Set-RegVal $e.P $e.N $e.Off }
            }
        }
    }
    Save-TweakBackup $bk
}

function Build-TweakRows($list, $defs) {
    $rows = @()
    foreach ($d in $defs) {
        $state = Get-TweakState $d
        $row = New-Row -Title $d.T -Desc $d.D -Checked $state
        $rows += [pscustomobject]@{ Id = $d.Id; Def = $d; Orig = $state; Check = $row.Check }
        [void]$list.Children.Add($row.Root)
    }
    return ,$rows
}

function Do-ApplyTweaks($rows, [string]$area) {
    $n = 0
    foreach ($r in $rows) {
        $want = [bool]$r.Check.IsChecked
        if ($want -ne $r.Orig) {
            $verb = 'Undone: '
            if ($want) { $verb = 'Applied: ' }
            try {
                Set-TweakState $r.Def $want
                $r.Orig = $want
                $n++
                Add-Activity $area ($verb + $r.Def.T)
            } catch {
                Write-Log ('Tweak failed ' + $r.Id + ': ' + $_)
                Add-Activity $area ('FAILED: ' + $r.Def.T)
            }
        }
    }
    Set-Status "$n setting(s) changed. Some need a sign-out or restart. Switch them off again any time to undo."
}

function Do-UndoTweaks($defs, [string]$area) {
    $bk = Get-TweakBackup
    if ($bk.Count -eq 0) { Show-Msg 'Nothing to undo. This tool has not changed any of these settings.'; return $false }
    if (-not (Confirm-Msg 'Put every setting in this tab back to how it was before this tool changed it?')) { return $false }
    $n = 0
    foreach ($d in $defs) {
        $bk = Get-TweakBackup
        $did = $false
        foreach ($e in $d.E) { if (Restore-Entry $e $bk) { $did = $true } }
        Save-TweakBackup $bk
        if ($did) { $n++; Add-Activity $area ('Restored original: ' + $d.T) }
    }
    Set-Status "Restored $n setting(s) to their originals."
    return $true
}

# ---- Privacy tab ----
function Load-Priv {
    $list = Get-El 'ListPriv'
    $list.Children.Clear()
    [void]$list.Children.Add((New-Header 'ON means the protection is active. Every change is backed up and can be undone'))
    $script:PrivRows = Build-TweakRows $list $script:PrivDefs
    $script:PrivLoaded = $true
    Set-Status 'Privacy settings loaded.'
}
function Do-TickPriv { foreach ($r in $script:PrivRows) { $r.Check.IsChecked = $true } }
function Do-ApplyPriv { Do-ApplyTweaks $script:PrivRows 'Privacy' }
function Do-UndoPriv { if (Do-UndoTweaks $script:PrivDefs 'Privacy') { Load-Priv } }

# ---- Windows Update tab ----
$script:UxKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$script:PauseNames = @('PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime', 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime')

function Get-PauseUntil {
    try {
        $v = (Get-ItemProperty -LiteralPath $script:UxKey -Name PauseUpdatesExpiryTime -ErrorAction Stop).PauseUpdatesExpiryTime
        $d = [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        if ($d -gt (Get-Date).ToUniversalTime()) { return $d.ToLocalTime() }
    } catch { }
    return $null
}

function Do-PauseUpdates([int]$days) {
    if ($days -gt 35) { $days = 35 }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $now = (Get-Date).ToUniversalTime()
    $end = $now.AddDays($days)
    $fmt = 'yyyy-MM-dd\THH:mm:ss\Z'
    $s = $now.ToString($fmt, $inv)
    $e = $end.ToString($fmt, $inv)
    if (-not (Test-Path -LiteralPath $script:UxKey)) { New-Item -Path $script:UxKey -Force | Out-Null }
    foreach ($n in $script:PauseNames) {
        $val = $e
        if ($n -like '*Start*') { $val = $s }
        Set-ItemProperty -LiteralPath $script:UxKey -Name $n -Value $val -Type String
    }
    Add-Activity 'Updates' "Paused Windows updates for $days days"
    Load-Upd
    Set-Status "Updates paused for $days days. Security updates resume automatically after that."
}

function Do-ResumeUpdates {
    foreach ($n in $script:PauseNames) { Remove-ItemProperty -LiteralPath $script:UxKey -Name $n -ErrorAction SilentlyContinue }
    Add-Activity 'Updates' 'Resumed Windows updates'
    Load-Upd
    Set-Status 'Updates resumed.'
}

function Load-Upd {
    $list = Get-El 'ListUpd'
    $list.Children.Clear()
    $until = Get-PauseUntil
    $statusText = 'On, installing normally'
    if ($until) { $statusText = 'Paused until ' + $until.ToString('d MMM yyyy') }
    [void]$list.Children.Add((New-Header 'Pause or resume updates'))
    [void]$list.Children.Add((New-InfoCard @(
        @('Updates', $statusText),
        @('Security', 'This tool never switches security updates off. Pausing is limited to 35 days, then Windows catches up.')
    )))
    Add-Action $list 'Pause for 7 days' 'Good before a tournament, a stream or a deadline.' 'Pause' { Do-PauseUpdates 7 }
    Add-Action $list 'Pause for 14 days' 'Two weeks of peace and quiet.' 'Pause' { Do-PauseUpdates 14 }
    Add-Action $list 'Pause for 35 days' 'The longest Windows allows.' 'Pause' { Do-PauseUpdates 35 }
    Add-Action $list 'Resume updates' 'Lets Windows install updates again straight away.' 'Resume' { Do-ResumeUpdates }
    Add-Action $list 'Open Windows Update' 'Check for updates yourself in Settings.' 'Open' { Start-Process 'ms-settings:windowsupdate' }
    [void]$list.Children.Add((New-Header 'How updates behave. ON means the setting is active'))
    $script:UpdRows = Build-TweakRows $list $script:UpdDefs
    $script:UpdLoaded = $true
}
function Do-ApplyUpd { Do-ApplyTweaks $script:UpdRows 'Updates' }
function Do-UndoUpd { if (Do-UndoTweaks $script:UpdDefs 'Updates') { Load-Upd } }

# ============================================================
#  Repair tools (run in the background, output shown live)
# ============================================================
$script:ToolProc = $null
$script:ToolTimer = $null
$script:ToolBox = $null
$script:ToolTitle = ''
$script:ToolLast = ''
$script:ToolOut = Join-Path $script:DataDir 'tool-output.txt'
$script:ToolBat = Join-Path $script:DataDir 'tool.cmd'

function Read-ToolOutput {
    if (-not (Test-Path -LiteralPath $script:ToolOut)) { return '' }
    $buf = $null
    $fs = $null
    $start = [long]0
    try {
        $fs = New-Object System.IO.FileStream($script:ToolOut, 'Open', 'Read', 'ReadWrite')
        $len = [int][math]::Min($fs.Length, 200000)
        if ($fs.Length -gt $len) { [void]$fs.Seek(-$len, 'End') }
        $start = $fs.Position
        $buf = New-Object byte[] $len
        [void]$fs.Read($buf, 0, $len)
    } catch { return '' } finally { if ($fs) { $fs.Dispose() } }
    if (-not $buf -or $buf.Length -eq 0) { return '' }
    # sfc writes UTF-16 (the others write the OEM code page). Decode it properly instead of dropping bytes, so
    # non-English output survives. A UTF-16 file is recognised by its byte-order mark or by being full of zero bytes.
    $text = $null
    $zeros = 0
    foreach ($b in $buf) { if ($b -eq 0) { $zeros++ } }
    $isUtf16 = (($buf.Length -ge 2 -and $buf[0] -eq 255 -and $buf[1] -eq 254) -or ($zeros * 4 -gt $buf.Length))
    if ($isUtf16) {
        $skip = 0
        if ($buf.Length -ge 2 -and $buf[0] -eq 255 -and $buf[1] -eq 254) { $skip = 2 }
        elseif (($start % 2) -eq 1) { $skip = 1 }          # we started in the middle of a 2-byte character
        $n = $buf.Length - $skip
        if (($n % 2) -eq 1) { $n-- }
        $text = [System.Text.Encoding]::Unicode.GetString($buf, $skip, $n)
    } else {
        $enc = [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $text = $enc.GetString($buf)
    }
    $out = New-Object System.Collections.Generic.List[string]
    $lastProg = $false
    foreach ($l in ($text -split '[\r\n]+')) {
        if (-not $l.Trim()) { continue }
        $isProg = ($l -match '\d+(\.\d+)?\s*%')
        if ($isProg -and $lastProg -and $out.Count -gt 0) { $out[$out.Count - 1] = $l } else { $out.Add($l) }
        $lastProg = $isProg
    }
    return ($out -join "`r`n")
}

function Update-Tool {
    try {
        if (-not $script:ToolBox) { return }
        $t = Read-ToolOutput
        if ($t -ne $script:ToolLast) {
            $script:ToolLast = $t
            $script:ToolBox.Text = ('Running: ' + $script:ToolTitle + "`r`n`r`n" + $t)
            $script:ToolBox.ScrollToEnd()
        }
        if ($script:ToolProc -and $script:ToolProc.HasExited) {
            $script:ToolTimer.Stop()
            $script:ToolBox.AppendText("`r`n`r`n--- Finished ---")
            $script:ToolBox.ScrollToEnd()
            Add-Activity 'Repair' ('Finished: ' + $script:ToolTitle)
            Set-Status ($script:ToolTitle + ' finished. Read the result above.')
            $script:ToolProc = $null
        }
    } catch { Write-Log ('Update-Tool: ' + $_) }
}

function Test-ToolBusy {
    if ($script:ToolProc -and -not $script:ToolProc.HasExited) {
        Show-Msg ("Another tool is still running (" + $script:ToolTitle + "). Wait for it to finish, or press Stop.")
        return $true
    }
    return $false
}

function Start-Tool([string]$title, [string[]]$lines) {
    if (Test-ToolBusy) { return }
    Remove-Item -LiteralPath $script:ToolOut -ErrorAction SilentlyContinue
    # Delete first: if someone else created tool.cmd before us they would still own it and could edit it while it runs as admin
    Remove-Item -LiteralPath $script:ToolBat -Force -ErrorAction SilentlyContinue
    $bat = @('@echo off', ('call :run > "' + $script:ToolOut + '" 2>&1'), 'exit /b', '', ':run') + $lines + @('exit /b')
    Set-Content -LiteralPath $script:ToolBat -Value $bat -Encoding ASCII
    $script:ToolTitle = $title
    $script:ToolLast = ''
    $script:ToolBox.Text = ('Running: ' + $title + "`r`n`r`nStarting...")
    $script:ToolProc = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $script:ToolBat + '"') -WindowStyle Hidden -PassThru
    try { [void]$script:ToolProc.Handle } catch { }
    Add-Activity 'Repair' ('Started: ' + $title)
    Set-Status ('Running ' + $title + '... you can keep using the app')
    if (-not $script:ToolTimer) {
        $script:ToolTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ToolTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:ToolTimer.Add_Tick({ Update-Tool })
    }
    $script:ToolTimer.Start()
}

function Do-StopTool {
    if ($script:ToolProc -and -not $script:ToolProc.HasExited) {
        try { & taskkill.exe /T /F /PID $script:ToolProc.Id | Out-Null } catch { }
        Add-Activity 'Repair' ('Stopped: ' + $script:ToolTitle)
        if ($script:ToolBox) { $script:ToolBox.AppendText("`r`n`r`n--- Stopped ---") }
    } else {
        Set-Status 'Nothing is running.'
    }
}

function Do-CopyTool {
    if ($script:ToolBox) {
        if (Set-ClipboardSafe ([string]$script:ToolBox.Text)) { Set-Status 'Output copied to the clipboard.' }
        else { Set-Status 'Could not copy: another app is holding the clipboard. Try again.' }
    }
}

# ---- DNS (dropdown of resolvers) ----
$script:DnsFile = Join-Path $script:DataDir 'dns-backup.json'
$script:DohFile = Join-Path $script:DataDir 'doh-added.json'
$script:DnsOptions = @(
    @{ Name='Cloudflare 1.1.1.1 - fast, unfiltered'; V4=@('1.1.1.1', '1.0.0.1'); V6=@('2606:4700:4700::1111', '2606:4700:4700::1001'); Doh='https://cloudflare-dns.com/dns-query' },
    @{ Name='Cloudflare 1.1.1.2 - blocks malware'; V4=@('1.1.1.2', '1.0.0.2'); V6=@('2606:4700:4700::1112', '2606:4700:4700::1002'); Doh='https://security.cloudflare-dns.com/dns-query' },
    @{ Name='Cloudflare 1.1.1.3 - blocks malware and adult content'; V4=@('1.1.1.3', '1.0.0.3'); V6=@('2606:4700:4700::1113', '2606:4700:4700::1003'); Doh='https://family.cloudflare-dns.com/dns-query' },
    @{ Name='Google 8.8.8.8'; V4=@('8.8.8.8', '8.8.4.4'); V6=@('2001:4860:4860::8888', '2001:4860:4860::8844'); Doh='https://dns.google/dns-query' }
)
$script:DnsCombo = $null

function Get-UpAdapters { return @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }

function Get-StaticDns($a, [string]$family) {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $a.InterfaceGuid
    if ($family -eq 'V6') { $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\' + $a.InterfaceGuid }
    try {
        $v = (Get-ItemProperty -LiteralPath $path -Name NameServer -ErrorAction Stop).NameServer
        if ($v) { return @(([string]$v) -split '[,\s]+' | Where-Object { $_ }) }
    } catch { }
    return @()
}

function Get-DnsBackup {
    $bk = @{}
    if (Test-Path -LiteralPath $script:DnsFile) {
        try {
            $o = Get-Content -LiteralPath $script:DnsFile -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $bk[$p.Name] = @{ V4 = @($p.Value.V4 | Where-Object { $_ }); V6 = @($p.Value.V6 | Where-Object { $_ }) } }
        } catch { }
    }
    return $bk
}

function Do-DnsApply {
    $idx = 0
    if ($script:DnsCombo) { $idx = [int]$script:DnsCombo.SelectedIndex }
    if ($idx -lt 0) { $idx = 0 }
    $opt = $script:DnsOptions[$idx]
    $ads = Get-UpAdapters
    if ($ads.Count -eq 0) { Show-Msg 'No active network connection was found.'; return }
    $bk = Get-DnsBackup
    foreach ($a in $ads) {
        if (-not $bk.ContainsKey($a.InterfaceGuid)) {
            $bk[$a.InterfaceGuid] = @{ V4 = @(Get-StaticDns $a 'V4'); V6 = @(Get-StaticDns $a 'V6') }
        }
    }
    $bk | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:DnsFile -Encoding UTF8
    foreach ($a in $ads) {
        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses (@($opt.V4) + @($opt.V6))
    }
    # Windows 11 can encrypt DNS (DoH). Best effort, skipped on Windows 10. Remember which templates WE added
    # so Restore can remove exactly those and leave ones that were already there alone.
    try {
        $added = @()
        if (Test-Path -LiteralPath $script:DohFile) { try { $added = @(Get-Content -LiteralPath $script:DohFile -Raw | ConvertFrom-Json) } catch { } }
        foreach ($ip in (@($opt.V4) + @($opt.V6))) {
            if (-not (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue)) {
                Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $opt.Doh -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null
                $added += $ip
            }
        }
        ConvertTo-Json -InputObject @($added | Select-Object -Unique) | Set-Content -LiteralPath $script:DohFile -Encoding UTF8
    } catch { }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Add-Activity 'DNS' ('Switched DNS to ' + $opt.Name)
    Set-Status ('DNS is now ' + $opt.Name + '. Use Restore to go back.')
}

function Do-DnsRestore {
    $bk = Get-DnsBackup
    if ($bk.Count -eq 0) { Show-Msg 'Nothing saved. This tool has not changed your DNS.'; return }
    # Every physical adapter, not just the ones that are up right now: an adapter that was off when DNS was changed
    # (Wi-Fi off, cable unplugged) still holds the changed servers. Only adapters actually restored leave the backup.
    $restored = 0
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        $g = [string]$a.InterfaceGuid
        if (-not $bk.ContainsKey($g)) { continue }
        try {
            $v4 = @($bk[$g].V4)
            $v6 = @($bk[$g].V6)
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
            if (($v4.Count + $v6.Count) -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses ($v4 + $v6) -ErrorAction Stop }
            [void]$bk.Remove($g)
            $restored++
        } catch { Write-Log ('DNS restore failed on ' + $a.Name + ': ' + $_) }
    }
    # Adapters that no longer exist cannot be restored: drop them so they do not keep the backup alive forever
    $present = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.InterfaceGuid })
    foreach ($g in @($bk.Keys)) { if ($present -notcontains $g) { [void]$bk.Remove($g) } }
    if ($bk.Count -gt 0) { $bk | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:DnsFile -Encoding UTF8 }
    else {
        Remove-Item -LiteralPath $script:DnsFile -ErrorAction SilentlyContinue
        # Remove the encrypted-DNS entries this tool added
        if (Test-Path -LiteralPath $script:DohFile) {
            try {
                foreach ($ip in @(Get-Content -LiteralPath $script:DohFile -Raw | ConvertFrom-Json)) {
                    Remove-DnsClientDohServerAddress -ServerAddress ([string]$ip) -ErrorAction SilentlyContinue
                }
            } catch { }
            Remove-Item -LiteralPath $script:DohFile -ErrorAction SilentlyContinue
        }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Add-Activity 'DNS' "Restored the original DNS settings on $restored adapter(s)"
    if ($bk.Count -gt 0) { Set-Status "Restored $restored adapter(s). $($bk.Count) could not be restored yet, press Restore again." }
    else { Set-Status 'Your original DNS settings are back.' }
}

function New-DnsRow {
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="12" Padding="16,12" Margin="0,0,0,8" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <StackPanel>
    <TextBlock Text="Change DNS server" FontWeight="SemiBold" FontSize="13.5" Foreground="{DynamicResource TextBrush}"/>
    <TextBlock Text="Pick a resolver, then press Apply. Often faster and more private than your ISP's. Works for IPv4 and IPv6. On Windows 11 it also asks Windows to use encrypted DNS (DoH) for that server." FontSize="12" TextWrapping="Wrap" Margin="0,2,0,10" Foreground="{DynamicResource SubTextBrush}"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <ComboBox Grid.Column="0" Height="32" VerticalContentAlignment="Center" Margin="0,0,10,0"/>
      <Button Grid.Column="1" MinWidth="84" Margin="0,0,8,0"/>
      <Button Grid.Column="2" MinWidth="84"/>
    </Grid>
  </StackPanel>
</Border>
"@
    $border = [System.Windows.Markup.XamlReader]::Parse($x)
    $grid = $border.Child.Children[2]
    $combo = $grid.Children[0]
    foreach ($o in $script:DnsOptions) { [void]$combo.Items.Add([string]$o.Name) }
    $combo.SelectedIndex = 0
    $script:DnsCombo = $combo
    $b1 = $grid.Children[1]
    $b1.Style = $script:Win.FindResource('Primary')
    $b1.Content = 'Apply'
    $b1.Tag = { Do-DnsApply }
    $b1.Add_Click({ param($s, $e) Invoke-SafeBlock ($s.Tag) })
    $b2 = $grid.Children[2]
    $b2.Style = $script:Win.FindResource('Pill')
    $b2.Content = 'Restore'
    $b2.Tag = { Do-DnsRestore }
    $b2.Add_Click({ param($s, $e) Invoke-SafeBlock ($s.Tag) })
    return $border
}

function Load-Fix {
    $list = Get-El 'ListFix'
    $list.Children.Clear()
    [void]$list.Children.Add((New-Header 'Output'))
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="12" Padding="12" Margin="0,0,0,8" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
  <TextBox IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="170" FontFamily="Consolas" FontSize="12" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource TextBrush}"/>
</Border>
"@
    $b = [System.Windows.Markup.XamlReader]::Parse($x)
    $script:ToolBox = $b.Child
    $script:ToolBox.Text = 'Pick a tool below. Progress shows up here while it runs.'
    [void]$list.Children.Add($b)

    [void]$list.Children.Add((New-Header 'Check and repair Windows'))
    Add-Action $list 'System file check' 'Scans protected Windows files and repairs damaged ones. Takes 5 to 15 minutes.' 'Run' { Start-Tool 'System file check' @('sfc /scannow') }
    Add-Action $list 'Repair Windows image (DISM)' 'Fixes the Windows component store. Needs internet and takes 10 to 30 minutes. Run this first if the file check cannot repair everything.' 'Run' { Start-Tool 'Repair Windows image' @('DISM /Online /Cleanup-Image /RestoreHealth') }
    Add-Action $list 'Check drive for errors' 'Read-only scan of your Windows drive. Nothing is changed.' 'Run' { Start-Tool 'Drive check' @('chkdsk %SystemDrive% /scan') }
    Add-Action $list 'Repair Windows Update' 'Fixes updates that are stuck or failing by resetting the update cache. Your update history list is cleared, nothing else.' 'Repair' {
        if (Confirm-Msg "Reset the Windows Update cache?`n`nUpdate services are stopped and restarted. Nothing personal is touched.") {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Start-Tool 'Repair Windows Update' @(
                'echo Stopping update services...',
                'net stop wuauserv', 'net stop bits', 'net stop cryptsvc',
                'echo Clearing the update cache...',
                ('ren "%windir%\SoftwareDistribution" SoftwareDistribution.old' + $stamp),
                ('ren "%windir%\System32\catroot2" catroot2.old' + $stamp),
                'for /d %%d in ("%windir%\SoftwareDistribution.old*") do rd /s /q "%%d"',
                'for /d %%d in ("%windir%\System32\catroot2.old*") do rd /s /q "%%d"',
                'echo Starting update services...',
                'net start cryptsvc', 'net start bits', 'net start wuauserv',
                'echo.', 'echo Done. Restart your PC, then check for updates again.'
            )
        }
    }

    [void]$list.Children.Add((New-Header 'Network'))
    Add-Action $list 'Ping test' 'Checks the speed and stability of your connection to Cloudflare, Google and google.com.' 'Run' {
        Start-Tool 'Ping test' @('echo Cloudflare 1.1.1.1', 'ping -n 5 1.1.1.1', 'echo.', 'echo Google DNS 8.8.8.8', 'ping -n 5 8.8.8.8', 'echo.', 'echo google.com', 'ping -n 5 google.com')
    }
    Add-Action $list 'Flush DNS cache' 'Clears stored website addresses. Fixes pages that will not load while others do.' 'Run' { Start-Tool 'Flush DNS' @('ipconfig /flushdns') }
    Add-Action $list 'Reset network stack' 'Resets Winsock and TCP/IP to fix stubborn connection problems. Needs a restart. If you use a fixed IP address, write it down first.' 'Reset' {
        if (Confirm-Msg "Reset the network stack?`n`nYou need to restart afterwards. A fixed (static) IP address would have to be set again.") {
            Start-Tool 'Network reset' @('ipconfig /flushdns', 'netsh winsock reset', 'netsh int ip reset', 'echo.', 'echo Restart your PC to finish.')
        }
    }
    [void]$list.Children.Add((New-DnsRow))

    [void]$list.Children.Add((New-Header 'Safety net'))
    Add-Action $list 'Create a restore point' 'Saves a snapshot you can roll back to from Windows System Restore.' 'Create' { Do-RestorePoint }
    Add-Action $list 'Restart PC now' 'Restarts in 15 seconds. Save your work first.' 'Restart' {
        if (Confirm-Msg 'Restart the PC in 15 seconds? Save your work first.') {
            Add-Activity 'System' 'Restart requested'
            Start-Process shutdown.exe -ArgumentList '/r /t 15' -WindowStyle Hidden
        }
    }
    Set-Status 'Repair tools ready.'
}

# ============================================================
#  Presets (share your choices with friends)
# ============================================================
function Get-PkgBase([string]$full) { return (($full -split '_')[0]) }

function As-List($v) {
    $o = @()
    if ($null -ne $v) { foreach ($i in @($v)) { if ($null -ne $i) { $o += [string]$i } } }
    return ,$o
}

function Ensure-TweakTabs {
    if (-not $script:PrivLoaded) { Load-Priv }
    if (-not $script:UpdLoaded) { Load-Upd }
}

function Do-ExportPreset {
    Ensure-AllData
    Ensure-TweakTabs
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Save preset'
    $dlg.Filter = 'PC Optimizer preset (*.json)|*.json'
    $dlg.FileName = 'PCOptimizer-preset.json'
    if ($dlg.ShowDialog() -ne $true) { return }
    $p = [ordered]@{
        Format     = 'PCOptimizerPreset'
        Version    = 1
        App        = $script:AppVersion
        Created    = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Strict     = [bool](Get-El 'StrictSwitch').IsChecked
        Services   = @($script:SvcRows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Name })
        StartupOff = @($script:StartRows | Where-Object { -not $_.Check.IsChecked } | ForEach-Object { $_.Name })
        Apps       = @($script:PkgRows | Where-Object { $_.Check.IsChecked } | ForEach-Object { Get-PkgBase $_.Full })
        Clean      = @($script:CleanRows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Target.Name })
        Gaming     = @($script:GameRows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Id })
        Privacy    = @($script:PrivRows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Id })
        Updates    = @($script:UpdRows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Id })
    }
    $p | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8
    Add-Activity 'Preset' ('Saved preset ' + (Split-Path $dlg.FileName -Leaf))
    Set-Status ('Preset saved: ' + $dlg.FileName)
    Show-Msg "Preset saved.`n`nSend that file to a friend. They press Import preset, review the ticked items and press Apply on each tab. Nothing runs until they do."
}

function Do-ImportPreset {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Open preset'
    $dlg.Filter = 'PC Optimizer preset (*.json)|*.json'
    if ($dlg.ShowDialog() -ne $true) { return }
    $p = $null
    try { $p = Get-Content -LiteralPath $dlg.FileName -Raw | ConvertFrom-Json } catch { }
    if (-not $p -or $p.Format -ne 'PCOptimizerPreset') { Show-Msg 'That file is not a PC Optimizer preset.'; return }

    Set-Status 'Loading preset...'
    (Get-El 'AdvSwitch').IsChecked = $true
    Ensure-AllData
    Ensure-TweakTabs
    if (-not $script:AppsLoaded) { $script:AppsLoaded = $true; Load-Apps }

    $svc = As-List $p.Services
    $off = As-List $p.StartupOff
    $apps = As-List $p.Apps
    $cln = As-List $p.Clean
    $gam = As-List $p.Gaming
    $prv = As-List $p.Privacy
    $upd = As-List $p.Updates
    $n = @{ Svc = 0; Start = 0; Apps = 0; Clean = 0; Game = 0; Priv = 0; Upd = 0 }

    (Get-El 'StrictSwitch').IsChecked = [bool]$p.Strict
    foreach ($r in $script:SvcRows) {
        $want = (($svc -contains $r.Name) -and ($r.Start -ne 'Disabled'))
        $r.Check.IsChecked = $want
        if ($want) { $n.Svc++ }
    }
    foreach ($r in $script:StartRows) {
        if (($off -contains $r.Name) -and ($r.Name -notmatch $script:KeepPattern) -and $r.Check.IsChecked) { $r.Check.IsChecked = $false; $n.Start++ }
    }
    foreach ($r in $script:PkgRows) {
        $want = ($apps -contains (Get-PkgBase $r.Full))
        $r.Check.IsChecked = $want
        if ($want) { $n.Apps++ }
    }
    foreach ($r in $script:CleanRows) {
        $want = ($cln -contains $r.Target.Name)
        $r.Check.IsChecked = $want
        if ($want) { $n.Clean++ }
    }
    foreach ($r in $script:GameRows) {
        $want = ($gam -contains $r.Id)
        $r.Check.IsChecked = $want
        if ($want) { $n.Game++ }
    }
    foreach ($r in $script:PrivRows) { if (($prv -contains $r.Id) -and -not $r.Check.IsChecked) { $r.Check.IsChecked = $true; $n.Priv++ } }
    foreach ($r in $script:UpdRows) { if (($upd -contains $r.Id) -and -not $r.Check.IsChecked) { $r.Check.IsChecked = $true; $n.Upd++ } }

    Add-Activity 'Preset' ('Loaded preset ' + (Split-Path $dlg.FileName -Leaf))
    Set-Status 'Preset loaded. Nothing has been changed yet.'
    Show-Msg ("Preset loaded. Nothing has been changed yet.`n`nTicked for you:`n  Services: $($n.Svc)`n  Startup to switch off: $($n.Start)`n  Apps to remove: $($n.Apps)`n  Cleaner items: $($n.Clean)`n  Gaming tweaks: $($n.Game)`n  Privacy settings: $($n.Priv)`n  Update settings: $($n.Upd)`n`nAdvanced mode is now on. Open each tab, check the list and press Apply (or Clean / Remove).")
    Select-Tab 'Svc'
}

# ============================================================
#  Tabs
# ============================================================
$script:TabIds = @('Tune', 'Dash', 'Svc', 'Start', 'Apps', 'Clean', 'Game', 'Priv', 'Upd', 'Fix', 'Log')

$script:LoadedTabs = @{}
function Ensure-Loaded([string]$name, [string]$fn) {
    if ($script:LoadedTabs.ContainsKey($name)) { return }
    $script:LoadedTabs[$name] = $true
    Set-Status 'Loading...'
    Pump
    Invoke-Safe $fn
}

function Start-Dashboard {
    Invoke-Safe 'Load-Dash'
    Invoke-Safe 'Start-Sampler'
    $script:DashTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DashTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:DashTimer.Add_Tick({ Update-Dashboard })
    $script:DashTimer.Start()
}

function Ensure-AllData {
    Ensure-Loaded 'Svc' 'Load-Services'
    Ensure-Loaded 'Start' 'Load-Startup'
    Ensure-Loaded 'Clean' 'Load-Clean'
    Ensure-Loaded 'Game' 'Load-Game'
}

# When someone else types their admin password into the prompt, this process runs as THAT account. The per-user
# changes (startup apps, privacy and gaming settings, temp files, Store apps) then land on the admin's profile,
# not on the person sitting at the PC. Say so once instead of letting it look like it worked.
function Test-ElevatedAccount {
    try {
        $console = [string](Get-CimInstance Win32_ComputerSystem).UserName
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($console -and $console -ne $me) {
            Show-Msg ("You approved the admin prompt with a different account ($me).`n`nStartup, privacy, gaming, temp-file and app changes apply to $me, not to $console. System-wide things (services, Windows Update, repair tools) are not affected.`n`nTo change $console's own settings, sign in as that account and run this app with its own admin approval.")
        }
    } catch { Write-Log ('Account check: ' + $_) }
}

function Set-Splash([string]$t) {
    try { (Get-El 'SplashText').Text = $t } catch { }
    Pump
}

function Start-Boot {
    Set-Splash 'Reading system info...'
    Invoke-Safe 'Update-SysInfo'
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromSeconds(10)
    $script:Timer.Add_Tick({ Update-SysInfo })
    $script:Timer.Start()
    Set-Splash 'Scanning your PC...'
    Invoke-Safe 'Load-Tune'
    (Get-El 'Splash').Visibility = 'Collapsed'
    Set-Status 'Ready.'
    Test-ElevatedAccount
    # slower extras after the window is already usable
    $script:LateTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:LateTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:LateTimer.Add_Tick({
        $script:LateTimer.Stop()
        try { $script:BootSecs = Get-BootSecs } catch { }
        Invoke-Safe 'Update-SysInfo'
    })
    $script:LateTimer.Start()
}

# The dashboard samplers (WMI + performance counters) only run while the Dashboard tab is on screen
function Suspend-Dashboard {
    if ($script:DashTimer) { $script:DashTimer.Stop() }
    Stop-Sampler
}
function Resume-Dashboard {
    if (-not $script:DashTimer) { return }
    if ($script:BgPs.Count -eq 0) { Invoke-Safe 'Start-Sampler' }
    $script:DashTimer.Start()
}

function Select-Tab([string]$id) {
    if ($id -ne 'Dash' -and $script:LoadedTabs.ContainsKey('Dash')) { Suspend-Dashboard }
    foreach ($t in $script:TabIds) {
        $tab = Get-El "Tab$t"
        $nav = Get-El "Nav$t"
        if ($t -eq $id) {
            $tab.Visibility = 'Visible'
            $nav.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'NavSelBrush')
        } else {
            $tab.Visibility = 'Collapsed'
            $nav.Background = [System.Windows.Media.Brushes]::Transparent
        }
    }
    if ($id -eq 'Dash') {
        if (-not $script:LoadedTabs.ContainsKey('Dash')) { $script:LoadedTabs['Dash'] = $true; Set-Status 'Reading hardware info...'; Pump; Start-Dashboard }
        else { Resume-Dashboard }
    }
    if ($id -eq 'Svc') { Ensure-Loaded 'Svc' 'Load-Services' }
    if ($id -eq 'Start') { Ensure-Loaded 'Start' 'Load-Startup' }
    if ($id -eq 'Clean') { Ensure-Loaded 'Clean' 'Load-Clean' }
    if ($id -eq 'Game') { Ensure-Loaded 'Game' 'Load-Game' }
    if ($id -eq 'Apps' -and -not $script:AppsLoaded) {
        $script:AppsLoaded = $true
        Invoke-Safe 'Load-Apps'
    }
    if ($id -eq 'Priv' -and -not $script:PrivLoaded) { Invoke-Safe 'Load-Priv' }
    if ($id -eq 'Upd' -and -not $script:UpdLoaded) { Invoke-Safe 'Load-Upd' }
    if ($id -eq 'Fix' -and -not $script:FixLoaded) { $script:FixLoaded = $true; Invoke-Safe 'Load-Fix' }
    if ($id -eq 'Log') { Invoke-Safe 'Load-Log' }
}

# ============================================================
#  XAML
# ============================================================
$tabTemplate = @'
<Grid x:Name="Tab@@ID@@" Visibility="Collapsed">
  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
    <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <Grid x:Name="Hdr@@ID@@" Background="Transparent" Margin="30,28,30,10">
    <StackPanel>
      <TextBlock Text="@@TITLE@@" FontSize="26" FontWeight="Bold" Foreground="{DynamicResource TextBrush}"/>
      <TextBlock Text="@@SUB@@" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="{DynamicResource SubTextBrush}"/>
    </StackPanel>
@@HDREXTRA@@
  </Grid>
  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
    <StackPanel x:Name="List@@ID@@" Margin="30,2,30,12"/>
  </ScrollViewer>
  <Border Grid.Row="2" Padding="30,12" Background="{DynamicResource SidebarBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="0,1,0,0">
    <DockPanel LastChildFill="False">@@BUTTONS@@</DockPanel>
  </Border>
</Grid>
'@

$tabDefs = @(
    @{ Id='Tune'; Title='Tune-Up'; Sub='A quick, safe clean and speed-up. Review what it will do, then press Run.';
       Buttons='<Button x:Name="BtnTuneRun" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Run tune-up" Margin="8,0,0,0"/><Button x:Name="BtnTuneScan" Style="{StaticResource Pill}" Content="Scan again"/>' },
    @{ Id='Dash'; Title='Dashboard'; Sub='Live view of your PC. Gauges turn amber above 60 percent and red above 85 percent.';
       Buttons='<Button x:Name="BtnRefreshDash" Style="{StaticResource Pill}" Content="Refresh hardware info"/>' },
    @{ Id='Svc'; Title='Services'; Sub='Background Windows services most people never use. Manual is gentle, Strict fully disables.';
       Buttons='<Button x:Name="BtnApplySvc" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Apply" Margin="8,0,0,0"/><Button x:Name="BtnRestoreSvc" DockPanel.Dock="Right" Style="{StaticResource Pill}" Content="Restore originals" Margin="8,0,0,0"/><Button x:Name="BtnRestorePoint" DockPanel.Dock="Right" Style="{StaticResource Pill}" Content="Restore point" Margin="8,0,0,0"/><Button x:Name="BtnSafe" Style="{StaticResource Pill}" Content="Tick safe" Margin="0,0,8,0"/><Button x:Name="BtnNone" Style="{StaticResource Pill}" Content="Untick all" Margin="0,0,16,0"/>';
       HdrExtra='<StackPanel HorizontalAlignment="Right" VerticalAlignment="Top" Orientation="Horizontal" Margin="12,6,0,0"><TextBlock Text="Strict (fully disable)" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="{DynamicResource SubTextBrush}"/><CheckBox x:Name="StrictSwitch" AutomationProperties.Name="Strict, fully disable services" Style="{StaticResource Switch}" VerticalAlignment="Center"/></StackPanel>' },
    @{ Id='Start'; Title='Startup'; Sub='Apps and scheduled tasks that launch at sign-in. Fully reversible: switch them back on any time.';
       Buttons='<Button x:Name="BtnApplyStart" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Apply" Margin="8,0,0,0"/><Button x:Name="BtnRefreshStart" Style="{StaticResource Pill}" Content="Refresh"/>' },
    @{ Id='Apps'; Title='Apps'; Sub='Preinstalled Store apps you may never use. Removed apps can be reinstalled from the Microsoft Store.';
       Buttons='<Button x:Name="BtnRemoveApps" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Remove ticked" Margin="8,0,0,0"/><Button x:Name="BtnTickBloat" Style="{StaticResource Pill}" Content="Tick bloat" Margin="0,0,8,0"/><Button x:Name="BtnRefreshApps" Style="{StaticResource Pill}" Content="Refresh"/>' },
    @{ Id='Clean'; Title='Cleaner'; Sub='Temp files and caches. Scan first to see sizes, nothing is deleted until you press Clean.';
       Buttons='<Button x:Name="BtnClean" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Clean" Margin="8,0,0,0"/><Button x:Name="BtnScan" Style="{StaticResource Pill}" Content="Scan"/>' },
    @{ Id='Game'; Title='Gaming'; Sub='One-click performance mode for playing. Restore normal puts everything back.';
       Buttons='<Button x:Name="BtnGameOn" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Gaming mode on" Margin="8,0,0,0"/><Button x:Name="BtnGameOff" DockPanel.Dock="Right" Style="{StaticResource Pill}" Content="Restore normal" Margin="8,0,0,0"/><Button x:Name="BtnRefreshGame" Style="{StaticResource Pill}" Content="Refresh apps"/>' },
    @{ Id='Priv'; Title='Privacy'; Sub='Cut tracking, ads and nagging. Every switch is backed up first and can be undone.';
       Buttons='<Button x:Name="BtnApplyPriv" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Apply" Margin="8,0,0,0"/><Button x:Name="BtnUndoPriv" DockPanel.Dock="Right" Style="{StaticResource Pill}" Content="Undo all my changes" Margin="8,0,0,0"/><Button x:Name="BtnTickPriv" Style="{StaticResource Pill}" Content="Switch all on"/>' },
    @{ Id='Upd'; Title='Windows Update'; Sub='Take control of when updates happen. Security updates are never switched off.';
       Buttons='<Button x:Name="BtnApplyUpd" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Apply" Margin="8,0,0,0"/><Button x:Name="BtnUndoUpd" Style="{StaticResource Pill}" Content="Undo all my changes"/>' },
    @{ Id='Fix'; Title='Repair'; Sub='Fix common Windows and network problems. Tools run in the background and show their output live.';
       Buttons='<Button x:Name="BtnStopTool" DockPanel.Dock="Right" Style="{StaticResource Pill}" Content="Stop" Margin="8,0,0,0"/><Button x:Name="BtnCopyTool" Style="{StaticResource Pill}" Content="Copy output"/>' },
    @{ Id='Log'; Title='Presets and Log'; Sub='Share your setup with friends, and see exactly what this tool has changed.';
       Buttons='<Button x:Name="BtnPresetExp" Style="{StaticResource Primary}" Content="Export preset" Margin="0,0,8,0"/><Button x:Name="BtnPresetImp" Style="{StaticResource Pill}" Content="Import preset" Margin="0,0,16,0"/><Button x:Name="BtnLogCopy" Style="{StaticResource Pill}" Content="Copy log" Margin="0,0,8,0"/><Button x:Name="BtnLogFolder" Style="{StaticResource Pill}" Content="Open data folder" Margin="0,0,8,0"/><Button x:Name="BtnCheckUpd" Style="{StaticResource Pill}" Content="Check for updates" Margin="0,0,8,0"/><Button x:Name="BtnLogRefresh" Style="{StaticResource Pill}" Content="Refresh"/>' }
)
$tabXaml = ''
foreach ($t in $tabDefs) {
    $hx = ''
    if ($t.HdrExtra) { $hx = $t.HdrExtra }
    $tabXaml += $tabTemplate.Replace('@@ID@@', $t.Id).Replace('@@TITLE@@', $t.Title).Replace('@@SUB@@', $t.Sub).Replace('@@BUTTONS@@', $t.Buttons).Replace('@@HDREXTRA@@', $hx)
}

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Optimizer" Width="1080" Height="740" MinWidth="640" MinHeight="480"
        WindowStyle="None" ResizeMode="CanResize" Background="Transparent"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="TextBrush" Color="#1D1D1F"/>
    <SolidColorBrush x:Key="SubTextBrush" Color="#6E6E73"/>
    <SolidColorBrush x:Key="CardBrush" Color="#A6FFFFFF"/>
    <SolidColorBrush x:Key="CardBorderBrush" Color="#1A000000"/>
    <SolidColorBrush x:Key="SidebarBrush" Color="#40FFFFFF"/>
    <SolidColorBrush x:Key="TintBrush" Color="#40F2F2F7"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#12000000"/>
    <SolidColorBrush x:Key="HoverBrush" Color="#14000000"/>
    <SolidColorBrush x:Key="NavSelBrush" Color="#1F000000"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#007AFF"/>

    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Background" Value="{DynamicResource ButtonBrush}"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.6"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>

    <Style x:Key="Nav" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="8" Padding="10,8">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource HoverBrush}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Dot" TargetType="Button">
      <Setter Property="Width" Value="14"/>
      <Setter Property="Height" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Ellipse x:Name="E" Fill="{TemplateBinding Background}" Stroke="#33000000" StrokeThickness="0.5"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="E" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="E" Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="42" Height="26" Background="Transparent">
              <Border x:Name="Track" CornerRadius="13" Background="#59808080"/>
              <Ellipse x:Name="Knob" Width="22" Height="22" Fill="White" HorizontalAlignment="Left" Margin="2,0,0,0">
                <Ellipse.Effect><DropShadowEffect BlurRadius="3" ShadowDepth="1" Opacity="0.3"/></Ellipse.Effect>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#34C759"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Tint" Background="{DynamicResource TintBrush}">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="220"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{DynamicResource SidebarBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="0,0,1,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid x:Name="SideDrag" Background="Transparent" Height="56">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
              <Button x:Name="DotClose" Style="{StaticResource Dot}" Background="#FF5F57" ToolTip="Close" AutomationProperties.Name="Close" Margin="0,0,8,0"/>
              <Button x:Name="DotMin" Style="{StaticResource Dot}" Background="#FEBC2E" ToolTip="Minimise" AutomationProperties.Name="Minimise" Margin="0,0,8,0"/>
              <Button x:Name="DotMax" Style="{StaticResource Dot}" Background="#28C840" ToolTip="Maximise" AutomationProperties.Name="Maximise"/>
            </StackPanel>
          </Grid>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel Margin="10,4,10,0">
            <TextBlock Text="OPTIMIZE" FontSize="11" FontWeight="SemiBold" Margin="10,4,0,6" Foreground="{DynamicResource SubTextBrush}"/>
            <Button x:Name="NavTune" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE945;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Tune-Up"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavDash" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE9D9;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Dashboard"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavSvc" Visibility="Collapsed" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE713;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Services"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavStart" Visibility="Collapsed" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE7E8;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Startup"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavApps" Visibility="Collapsed" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE71D;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Apps"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavClean" Visibility="Collapsed" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE74D;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Cleaner"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavGame" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE7FC;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Gaming"/>
              </StackPanel>
            </Button>
            <TextBlock Text="SYSTEM" FontSize="11" FontWeight="SemiBold" Margin="10,14,0,6" Foreground="{DynamicResource SubTextBrush}"/>
            <Button x:Name="NavPriv" Visibility="Collapsed" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE72E;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Privacy"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavUpd" Visibility="Collapsed" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE777;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Windows Update"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavFix" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE115;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Repair"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavLog" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE81C;" Width="26" VerticalAlignment="Center"/>
                <TextBlock Text="Presets and Log"/>
              </StackPanel>
            </Button>
          </StackPanel></ScrollViewer>
          <StackPanel Grid.Row="2" Margin="14,0,14,16">
            <Border CornerRadius="10" Padding="12,10" Margin="0,0,0,12" Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="1">
              <TextBlock x:Name="SysInfo" FontSize="11.5" LineHeight="17" TextWrapping="Wrap" Foreground="{DynamicResource SubTextBrush}" Text="Loading system info..."/>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="6,0,0,0">
              <TextBlock Text="Dark mode" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="{DynamicResource SubTextBrush}"/>
              <CheckBox x:Name="ThemeSwitch" AutomationProperties.Name="Dark mode" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="6,10,0,0">
              <TextBlock Text="Advanced mode" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="{DynamicResource SubTextBrush}"/>
              <CheckBox x:Name="AdvSwitch" AutomationProperties.Name="Advanced mode" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </Border>

      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0">
          <!--TABS-->
        </Grid>
        <Border Grid.Row="1" Padding="30,8" BorderBrush="{DynamicResource CardBorderBrush}" BorderThickness="0,1,0,0">
          <TextBlock x:Name="StatusText" Text="Ready" FontSize="12" Foreground="{DynamicResource SubTextBrush}" TextTrimming="CharacterEllipsis"/>
        </Border>
      </Grid>
      <Border x:Name="Splash" Grid.ColumnSpan="2" Panel.ZIndex="100" Background="#F0F2F2F7">
        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
          <TextBlock Text="PC Optimizer" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center" Foreground="#1D1D1F"/>
          <TextBlock x:Name="SplashText" Text="Getting things ready..." Margin="0,8,0,0" HorizontalAlignment="Center" Foreground="#6E6E73"/>
          <ProgressBar IsIndeterminate="True" Width="220" Height="4" Margin="0,18,0,0"/>
        </StackPanel>
      </Border>
    </Grid>
  </Border>
</Window>
'@

# ============================================================
#  Build window and wire up events
# ============================================================
Say 'Building window...'
try {
    $xaml = $mainXaml.Replace('<!--TABS-->', $tabXaml)
    $script:Win = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $script:Win.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height
    $script:Win.MaxWidth = [System.Windows.SystemParameters]::WorkArea.Width

    $script:Win.Add_SourceInitialized({
        $script:Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:Win)).Handle
        try { Initialize-Glass } catch { $script:GlassOk = $false }
        try {
            $sc = [System.Windows.Interop.HwndSource]::FromHwnd($script:Hwnd).CompositionTarget.TransformToDevice.M11
            [CaptionHook]::Install($script:Hwnd, [double]$sc)
            [CaptionHook]::EnableSnap($script:Hwnd)
        } catch { Write-Log ('Caption hook: ' + $_) }
        Set-Theme $false
    })

    $script:Win.Add_Loaded({
        Select-Tab 'Tune'
        Restore-UiSettings
        # check for an update straight away (on another thread); the answer waits until the app is idle
        Invoke-Safe 'Do-CheckUpdateQuiet'
        # let the window paint first, then load in the background of the splash screen
        $script:BootTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:BootTimer.Interval = [TimeSpan]::FromMilliseconds(80)
        $script:BootTimer.Add_Tick({ $script:BootTimer.Stop(); Invoke-Safe 'Start-Boot' })
        $script:BootTimer.Start()
    })

    $script:Win.Add_Closed({ Stop-Sampler })

    # Dragging (header areas)
    foreach ($n in @('SideDrag', 'HdrTune', 'HdrDash', 'HdrSvc', 'HdrStart', 'HdrApps', 'HdrClean', 'HdrGame', 'HdrPriv', 'HdrUpd', 'HdrFix', 'HdrLog')) {
        (Get-El $n).Add_MouseLeftButtonDown({ Do-WinDrag })
    }

    # Traffic lights
    (Get-El 'DotClose').Add_Click({ Invoke-Safe 'Do-WinClose' })
    (Get-El 'DotMin').Add_Click({ Invoke-Safe 'Do-WinMin' })
    (Get-El 'DotMax').Add_Click({ Invoke-Safe 'Do-WinMax' })
    try { Initialize-SnapMenu } catch { Write-Log ('Snap menu: ' + $_) }

    # Navigation
    (Get-El 'NavTune').Add_Click({ Select-Tab 'Tune' })
    (Get-El 'NavDash').Add_Click({ Select-Tab 'Dash' })
    (Get-El 'NavSvc').Add_Click({ Select-Tab 'Svc' })
    (Get-El 'NavStart').Add_Click({ Select-Tab 'Start' })
    (Get-El 'NavApps').Add_Click({ Select-Tab 'Apps' })
    (Get-El 'NavClean').Add_Click({ Select-Tab 'Clean' })
    (Get-El 'NavGame').Add_Click({ Select-Tab 'Game' })
    (Get-El 'NavPriv').Add_Click({ Select-Tab 'Priv' })
    (Get-El 'NavUpd').Add_Click({ Select-Tab 'Upd' })
    (Get-El 'NavFix').Add_Click({ Select-Tab 'Fix' })
    (Get-El 'NavLog').Add_Click({ Select-Tab 'Log' })

    # Theme
    (Get-El 'ThemeSwitch').Add_Checked({ Set-Theme $true; Save-UiSettings })
    (Get-El 'ThemeSwitch').Add_Unchecked({ Set-Theme $false; Save-UiSettings })

    # Services
    (Get-El 'BtnSafe').Add_Click({ Invoke-Safe 'Do-TickSafe' })
    (Get-El 'BtnNone').Add_Click({ Invoke-Safe 'Do-UntickAll' })
    (Get-El 'BtnApplySvc').Add_Click({ Invoke-Safe 'Do-ApplyServices' })
    (Get-El 'BtnRestoreSvc').Add_Click({ Invoke-Safe 'Do-RestoreServices' })
    (Get-El 'BtnRestorePoint').Add_Click({ Invoke-Safe 'Do-RestorePoint' })

    # Startup
    (Get-El 'BtnApplyStart').Add_Click({ Invoke-Safe 'Do-ApplyStartup' })
    (Get-El 'BtnRefreshStart').Add_Click({ Invoke-Safe 'Load-Startup' })

    # Cleaner
    (Get-El 'BtnScan').Add_Click({ Invoke-Safe 'Do-Scan' })
    (Get-El 'BtnClean').Add_Click({ Invoke-Safe 'Do-Clean' })

    # Tune-Up and mode
    (Get-El 'BtnTuneRun').Add_Click({ Invoke-Safe 'Do-TuneUp' })
    (Get-El 'BtnTuneScan').Add_Click({ Invoke-Safe 'Load-Tune' })
    (Get-El 'AdvSwitch').Add_Checked({ Set-AdvancedMode $true; Save-UiSettings })
    (Get-El 'AdvSwitch').Add_Unchecked({ Set-AdvancedMode $false; Save-UiSettings })

    # Dashboard
    (Get-El 'BtnRefreshDash').Add_Click({ Invoke-Safe 'Load-Dash' })

    # Gaming
    (Get-El 'BtnGameOn').Add_Click({ Invoke-Safe 'Do-GameOn' })
    (Get-El 'BtnGameOff').Add_Click({ Invoke-Safe 'Do-GameOff' })
    (Get-El 'BtnRefreshGame').Add_Click({ Invoke-Safe 'Load-Game' })

    # Privacy, Updates, Repair, Presets
    (Get-El 'BtnApplyPriv').Add_Click({ Invoke-Safe 'Do-ApplyPriv' })
    (Get-El 'BtnUndoPriv').Add_Click({ Invoke-Safe 'Do-UndoPriv' })
    (Get-El 'BtnTickPriv').Add_Click({ Invoke-Safe 'Do-TickPriv' })
    (Get-El 'BtnApplyUpd').Add_Click({ Invoke-Safe 'Do-ApplyUpd' })
    (Get-El 'BtnUndoUpd').Add_Click({ Invoke-Safe 'Do-UndoUpd' })
    (Get-El 'BtnStopTool').Add_Click({ Invoke-Safe 'Do-StopTool' })
    (Get-El 'BtnCopyTool').Add_Click({ Invoke-Safe 'Do-CopyTool' })
    (Get-El 'BtnPresetExp').Add_Click({ Invoke-Safe 'Do-ExportPreset' })
    (Get-El 'BtnPresetImp').Add_Click({ Invoke-Safe 'Do-ImportPreset' })
    (Get-El 'BtnLogCopy').Add_Click({ Invoke-Safe 'Do-CopyLog' })
    (Get-El 'BtnLogFolder').Add_Click({ Invoke-Safe 'Do-OpenData' })
    (Get-El 'BtnLogRefresh').Add_Click({ Invoke-Safe 'Load-Log' })
    (Get-El 'BtnCheckUpd').Add_Click({ Invoke-Safe 'Do-CheckUpdateNow' })

    # Apps
    (Get-El 'BtnTickBloat').Add_Click({ Invoke-Safe 'Do-TickBloat' })
    (Get-El 'BtnRefreshApps').Add_Click({ Invoke-Safe 'Load-Apps' })
    (Get-El 'BtnRemoveApps').Add_Click({ Invoke-Safe 'Do-RemoveApps' })

    [void]$script:Win.ShowDialog()
}
catch {
    Say ($_ | Out-String) 'Red'
    Write-Log ('startup: ' + ($_ | Out-String))
    try { [void][System.Windows.MessageBox]::Show(("PC Optimizer could not start:`n`n" + ($_ | Out-String)), 'PC Optimizer', 'OK', 'Error') } catch { }
}
