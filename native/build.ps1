$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot "PopDropTransfer\PopDropTransfer.cpp"
$outRoot = Join-Path $PSScriptRoot "bin"

function Build-Architecture([string]$Architecture, [string]$HostArchitecture) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "未找到 Visual Studio Build Tools。请安装“使用 C++ 的桌面开发”工作负载。"
    }
    $installation = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $installation) {
        throw "Visual Studio 缺少 MSVC x86/x64 编译工具。"
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
        throw "PopDropTransfer $Architecture 构建失败。"
    }
    Write-Host "Built $exe"
    if ($Architecture -eq "x64") {
        $testSource = Join-Path $PSScriptRoot "tests\SyntheticDataObjectTest.cpp"
        $testOut = Join-Path $out "SyntheticDataObjectTest.exe"
        & cl.exe /nologo /std:c++17 /utf-8 /O2 /EHsc /W4 $testSource `
            /link /SUBSYSTEM:CONSOLE ole32.lib shell32.lib user32.lib `
            /OUT:$testOut
        if ($LASTEXITCODE -ne 0) {
            throw "SyntheticDataObjectTest 构建失败。"
        }
        Write-Host "Built $testOut"
    }
}

Build-Architecture "x64" "x64"
Build-Architecture "x86" "x64"

Write-Host ""
Write-Host "构建完成。源码版会自动从 native\bin\<架构> 选择 helper。"
Write-Host "发布 EXE 时，请将对应架构的 PopDropTransfer.exe 放到 PopDrop.exe 同目录。"
