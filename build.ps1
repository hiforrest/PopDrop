<#
.SYNOPSIS
    PopDrop build script - Compile PopDrop.ahk with Ahk2Exe (AutoHotkey v2).

.DESCRIPTION
    Stable, reproducible build pipeline. Checks all prerequisites,
    passes all arguments explicitly, writes detailed logs.
    Does NOT rely on Ahk2Exe GUI saved settings.

.NOTES
    Compiler: Ahk2Exe.exe (C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe)
    Ahk2Exe 1.1.x is a GUI app -- use Start-Process (not &) to capture exit code.
    Language: PowerShell 5.1+
#>

#Requires -Version 5.1

# ============================================================
# Paths
# ============================================================
$script:ProjectRoot = "D:\GProgram\PopDrop"
$script:AhkScriptPath = Join-Path $ProjectRoot "PopDrop.ahk"
$script:OutputPath = Join-Path $ProjectRoot "PopDrop.exe"
$script:AppIcoPath = Join-Path $ProjectRoot "assets\app.ico"
$script:TrayIcoPath = Join-Path $ProjectRoot "assets\tray.ico"
$script:LogDir = Join-Path $ProjectRoot "build_logs"
$script:CompilerPath = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
$script:BasePath64 = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$script:BasePath32 = "C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe"

# ============================================================
# Helpers
# ============================================================
function Write-Step {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$timestamp] $Message" -ForegroundColor Cyan
}

function Write-Err {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$timestamp] ERROR: $Message" -ForegroundColor Red
}

function Write-OK {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$timestamp] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$timestamp] WARN: $Message" -ForegroundColor Yellow
}

# ============================================================
# Pre-flight checks
# ============================================================
Write-Step "===== PopDrop Build Start ====="
$startTime = Get-Date

# 1. Check Ahk2Exe.exe
Write-Step "Checking compiler: $CompilerPath"
if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
    Write-Err "Ahk2Exe.exe not found: $CompilerPath"
    exit 1
}
Write-OK "Compiler found: $CompilerPath"

# 2. Check AHK main script
Write-Step "Checking script: $AhkScriptPath"
if (-not (Test-Path -LiteralPath $AhkScriptPath -PathType Leaf)) {
    Write-Err "Script not found: $AhkScriptPath"
    exit 2
}
Write-OK "Script found: $AhkScriptPath"

# 3. Check first line is #Requires AutoHotkey v2.0
Write-Step "Checking #Requires directive"
$firstLine = Get-Content -LiteralPath $AhkScriptPath -First 1
if ($firstLine -notmatch '#Requires\s+AutoHotkey\s+v2\.') {
    Write-Err "First line is not #Requires AutoHotkey v2.x (current: $firstLine)"
    exit 3
}
Write-OK "#Requires check passed: $firstLine"

# 4. Check Ahk2Exe directives
Write-Step "Checking Ahk2Exe directives"
$ahkContent = Get-Content -LiteralPath $AhkScriptPath -Raw
if ($ahkContent -notmatch ';@Ahk2Exe-SetMainIcon') {
    Write-Warn "No ;@Ahk2Exe-SetMainIcon directive found"
}
if ($ahkContent -notmatch ';@Ahk2Exe-AddResource') {
    Write-Warn "No ;@Ahk2Exe-AddResource directive found"
}

# 5. Check Base file
Write-Step "Checking AutoHotkey v2 Base file"
$basePath = $null
$baseDescription = ""

if (Test-Path -LiteralPath $BasePath64 -PathType Leaf) {
    $basePath = $BasePath64
    $baseDescription = "AutoHotkey64.exe (x64)"
    $fileVersion = (Get-Item -LiteralPath $basePath).VersionInfo.FileVersion
    Write-OK "Found x64 Base: $basePath (v$fileVersion)"
} elseif (Test-Path -LiteralPath $BasePath32 -PathType Leaf) {
    $basePath = $BasePath32
    $baseDescription = "AutoHotkey32.exe (x86)"
    $fileVersion = (Get-Item -LiteralPath $basePath).VersionInfo.FileVersion
    Write-OK "Found x86 Base: $basePath (v$fileVersion)"
} else {
    Write-Warn "Standard Base path not found, searching AutoHotkey dir..."
    $ahkInstallDir = "C:\Program Files\AutoHotkey"
    if (Test-Path -LiteralPath $ahkInstallDir -PathType Container) {
        $exeCandidates = Get-ChildItem -LiteralPath $ahkInstallDir -Recurse -Filter "AutoHotkey*.exe" -Depth 2
        foreach ($candidate in $exeCandidates) {
            try {
                $version = $candidate.VersionInfo.FileVersion
                if ($version -and $version.StartsWith("2")) {
                    $basePath = $candidate.FullName
                    $baseDescription = "$($candidate.Name) (v$version)"
                    Write-OK "Found v2 Base: $basePath"
                    break
                }
            } catch {
                continue
            }
        }
    }
}

if (-not $basePath) {
    Write-Err "AutoHotkey v2 Base file not found. Please install AutoHotkey v2."
    exit 4
}

# 6. Check app icon
Write-Step "Checking app icon: $AppIcoPath"
if (-not (Test-Path -LiteralPath $AppIcoPath -PathType Leaf)) {
    Write-Err "App icon not found: $AppIcoPath"
    exit 5
}
Write-OK "App icon found: $AppIcoPath"

# 7. Check tray icon
Write-Step "Checking tray icon: $TrayIcoPath"
if (-not (Test-Path -LiteralPath $TrayIcoPath -PathType Leaf)) {
    Write-Err "Tray icon not found: $TrayIcoPath"
    exit 6
}
Write-OK "Tray icon found: $TrayIcoPath"

# 8. Check output directory writable
Write-Step "Checking output directory writable: $ProjectRoot"
$testFile = Join-Path $ProjectRoot ".write_test_$(Get-Random).tmp"
try {
    [System.IO.File]::WriteAllText($testFile, "test")
    [System.IO.File]::Delete($testFile)
    Write-OK "Output directory is writable"
} catch {
    Write-Err "Output directory not writable: $ProjectRoot"
    exit 7
}

# 9. Check if old EXE is running
Write-Step "Checking if old EXE is running"
$oldProcess = Get-Process -Name "PopDrop" -ErrorAction SilentlyContinue
if ($oldProcess) {
    Write-Err "PopDrop.exe is running (PID: $($oldProcess.Id)). Please close it first."
    exit 8
}
Write-OK "Old EXE is not running"

# 10. Check all #Include files
Write-Step "Checking #Include files"
$includeMatches = [regex]::Matches($ahkContent, '#Include\s+(.+\.ahk)')
foreach ($match in $includeMatches) {
    $includePath = $match.Groups[1].Value.Trim()
    $resolvedPath = Join-Path $ProjectRoot $includePath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        Write-Err "Include file not found: $resolvedPath (from $includePath)"
        exit 9
    }
    Write-OK "Include file found: $resolvedPath"
}

# 11. Check script encoding
Write-Step "Checking script encoding"
$bytes = [System.IO.File]::ReadAllBytes($AhkScriptPath)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-OK "Script encoding: UTF-8 with BOM"
} else {
    Write-Warn "Script encoding: UTF-8 without BOM (adding BOM for Chinese compatibility)"
    $bom = [byte[]]@(0xEF, 0xBB, 0xBF)
    $newContent = $bom + $bytes
    [System.IO.File]::WriteAllBytes($AhkScriptPath, $newContent)
    Write-OK "UTF-8 BOM header added"
}

# ============================================================
# Create log directory
# ============================================================
if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $LogDir "build_$logTimestamp.log"

# ============================================================
# Execute build
# ============================================================
Write-Step "===== Starting Build ====="
Write-Host "  Compiler: $CompilerPath"
Write-Host "  Input: $AhkScriptPath"
Write-Host "  Output: $OutputPath"
Write-Host "  Base: $basePath ($baseDescription)"
Write-Host "  Log: $logFile"

# Build argument string for Ahk2Exe (GUI app, use Start-Process)
$argumentList = @(
    "/in", "`"$AhkScriptPath`"",
    "/out", "`"$OutputPath`"",
    "/base", "`"$basePath`""
)

# Ahk2Exe 1.1.x expects a single command-line string, not an array
$argumentString = "/in `"$AhkScriptPath`" /out `"$OutputPath`" /base `"$basePath`" /compress 0"

Write-Host "  Arguments: $argumentString"

$process = Start-Process -FilePath $CompilerPath -ArgumentList $argumentString -NoNewWindow -Wait -PassThru
$exitCode = $process.ExitCode

# Ahk2Exe 1.1.x prints success message to its own console window. Capture what we can.
$output = "Ahk2Exe exit code: $exitCode"

# ============================================================
# Post-processing & validation
# ============================================================
$endTime = Get-Date
$duration = $endTime - $startTime

$outputExists = Test-Path -LiteralPath $OutputPath -PathType Leaf
$outputSize = if ($outputExists) { (Get-Item -LiteralPath $OutputPath).Length } else { 0 }

$logContent = @"
========================================
PopDrop Build Log
========================================
Build time: $($startTime.ToString("yyyy-MM-dd HH:mm:ss.fff"))
Finish time: $($endTime.ToString("yyyy-MM-dd HH:mm:ss.fff"))
Duration: $($duration.TotalSeconds.ToString("F3")) sec

---------- Environment ----------
Computer: $env:COMPUTERNAME
User: $env:USERNAME
PowerShell: $($PSVersionTable.PSVersion)

---------- Paths ----------
Compiler: $CompilerPath
Script: $AhkScriptPath
Base: $basePath ($baseDescription)
Output: $OutputPath
App icon: $AppIcoPath
Tray icon: $TrayIcoPath

---------- Arguments ----------
$argumentString

---------- Result ----------
Exit code: $exitCode
Exit code (hex): 0x$("{0:X2}" -f $exitCode)

---------- Validation ----------
File exists: $outputExists
File size: $outputSize bytes
"@

$logContent | Out-File -FilePath $logFile -Encoding utf8

Write-Host ""
Write-Host "---------- Build Result ----------" -ForegroundColor Cyan
Write-Host "Exit code (decimal): $exitCode"
Write-Host "Exit code (hex): 0x$("{0:X2}" -f $exitCode)"
Write-Host "Output exists: $outputExists"
Write-Host "Output size: $outputSize bytes"
Write-Host "Duration: $($duration.TotalSeconds.ToString("F3")) sec"
Write-Host ""

# Exit code analysis
if ($exitCode -ne 0) {
    Write-Host "---------- Exit Code Analysis ----------" -ForegroundColor Red
    switch ($exitCode) {
        0x03 { Write-Host "  0x03: Invalid arguments - check /in /out /base" }
        0x11 { Write-Host "  0x11: AHK syntax error - test script in AutoHotkey v2" }
        0x32 { Write-Host "  0x32: Cannot open script or include file" }
        0x34 { Write-Host "  0x34: Base file not found" }
        0x35 { Write-Host "  0x35: Icon file not found" }
        0x42 { Write-Host "  0x42: ICO unreadable or invalid format" }
        0x45 { Write-Host "  0x45: Target EXE is running or cannot be overwritten" }
        0x63 { Write-Host "  0x63: Invalid Ahk2Exe directive" }
        0x64 { Write-Host "  0x64: Ahk2Exe directive malformed" }
        default { Write-Host "  0x$("{0:X2}" -f $exitCode): Unknown error - check Ahk2Exe docs" }
    }
}

# Final verdict
if ($exitCode -eq 0 -and $outputExists -and $outputSize -gt 0) {
    Write-OK "===== BUILD SUCCESS ====="
    Write-Host "Output: $OutputPath" -ForegroundColor Green
    Write-Host "Log: $logFile" -ForegroundColor Green
    exit 0
} else {
    Write-Err "===== BUILD FAILED ====="
    Write-Host "Log: $logFile" -ForegroundColor Yellow
    exit 1
}