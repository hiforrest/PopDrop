$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot "PopDropTransfer\PopDropTransfer.cpp"
$previewSource = Join-Path $PSScriptRoot "PopDropPreview\PopDropPreview.cpp"
$outRoot = Join-Path $PSScriptRoot "bin"

$transferText = Get-Content -LiteralPath $source -Raw
if ($transferText -notmatch 'kHelperVersion\[\]\s*=\s*L"1\.1\.2"') {
    throw "PopDropTransfer source version is not 1.1.2."
}

function Build-Architecture([string]$Architecture, [string]$HostArchitecture) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "No Visual Studio Build Tools found. Please install the 'Desktop development with C++' workload."
    }
    $installation = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $installation) {
        throw "Visual Studio is missing MSVC x86/x64 build tools."
    }
    $devShell = Join-Path $installation "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
    Import-Module $devShell
    Enter-VsDevShell -VsInstallPath $installation -SkipAutomaticLocation `
        -DevCmdArguments "-arch=$Architecture -host_arch=$HostArchitecture"

    $out = Join-Path $outRoot $Architecture
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $exe = Join-Path $out "PopDropTransfer.exe"
    & cl.exe /nologo /std:c++17 /utf-8 /O2 /GL /EHsc `
        /DUNICODE /D_UNICODE /DWINVER=0x0A00 /D_WIN32_WINNT=0x0A00 `
        /W4 /permissive- /guard:cf /DYNAMICBASE /NXCOMPAT `
        $source /link /SUBSYSTEM:WINDOWS /LTCG /OPT:REF /OPT:ICF `
        /OUT:$exe
    if ($LASTEXITCODE -ne 0) {
        throw "PopDropTransfer $Architecture build failed."
    }
    Write-Host "Built $exe"

    $previewExe = Join-Path $out "PopDropPreview.exe"
    & cl.exe /nologo /std:c++17 /utf-8 /O2 /GL /EHsc `
        /DUNICODE /D_UNICODE /DWINVER=0x0A00 /D_WIN32_WINNT=0x0A00 `
        /W4 /permissive- /guard:cf /DYNAMICBASE /NXCOMPAT `
        $previewSource /link /SUBSYSTEM:WINDOWS /LTCG /OPT:REF /OPT:ICF `
        windowscodecs.lib ole32.lib shell32.lib bcrypt.lib query.lib `
        shcore.lib `
        /OUT:$previewExe
    if ($LASTEXITCODE -ne 0) {
        throw "PopDropPreview $Architecture build failed."
    }
    Write-Host "Built $previewExe"
    if ($Architecture -eq "x64") {
        $testSource = Join-Path $PSScriptRoot "tests\SyntheticDataObjectTest.cpp"
        $testOut = Join-Path $out "SyntheticDataObjectTest.exe"
        & cl.exe /nologo /std:c++17 /utf-8 /O2 /EHsc /W4 $testSource `
            /link /SUBSYSTEM:CONSOLE ole32.lib shell32.lib user32.lib `
            /OUT:$testOut
        if ($LASTEXITCODE -ne 0) {
            throw "SyntheticDataObjectTest build failed."
        }
        Write-Host "Built $testOut"
    }
}

Build-Architecture "x64" "x64"
Build-Architecture "x86" "x64"

Write-Host ""
Write-Host "Build complete. Source version automatically selects helpers from native\bin\<arch>."
Write-Host "For release packages, keep the freshly built helpers under native\bin\<arch>\."
Write-Host "Do not mix helpers from another release; PopDropTransfer embeds the application version."
Write-Host "For reliable PDF preview, also run native\install-pdfium.ps1 to download pdfium.dll."
