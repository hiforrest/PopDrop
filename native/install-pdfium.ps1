param(
    [ValidateSet("x64", "x86", "All")]
    [string]$Architecture = $(if ([Environment]::Is64BitOperatingSystem) {
        "x64"
    } else {
        "x86"
    }),
    [string]$ManifestPath = (Join-Path $PSScriptRoot "pdfium-component.ini"),
    [string]$DestinationDirectory = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.SecurityProtocolType]::Tls12

function Read-IniFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "PDFium component manifest was not found: $Path"
    }
    $result = @{}
    $section = ""
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith(";")) {
            continue
        }
        if ($trimmed -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $result.ContainsKey($section)) {
                $result[$section] = @{}
            }
            continue
        }
        if ($section -and $trimmed -match '^([^=]+)=(.*)$') {
            $result[$section][$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $result
}

function Assert-DllArchitecture(
        [string]$Path, [ValidateSet("x64", "x86")][string]$Expected) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "Downloaded component is not a Windows DLL."
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 6) {
            throw "Downloaded component has an invalid PE header."
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Downloaded component has an invalid PE signature."
        }
        $machine = $reader.ReadUInt16()
        $expectedMachine = if ($Expected -eq "x64") { 0x8664 } else { 0x014C }
        if ($machine -ne $expectedMachine) {
            throw "Downloaded component architecture does not match $Expected."
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-SafeArchiveEntry([string]$Entry) {
    $normalized = $Entry.Replace("\", "/")
    if (-not $normalized -or $normalized.StartsWith("/") -or
        $normalized -match '^[A-Za-z]:' -or
        $normalized.Split("/") -contains "..") {
        throw "Component archive contains an unsafe path: $Entry"
    }
}

function Expand-ZipPackage([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 512) {
            throw "Component ZIP contains too many entries."
        }
        $expandedBytes = 0L
        foreach ($entry in $zip.Entries) {
            Assert-SafeArchiveEntry $entry.FullName
            $expandedBytes += $entry.Length
            if ($expandedBytes -gt 128MB) {
                throw "Component ZIP expands beyond the safety limit."
            }
        }
    } finally {
        $zip.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

function Expand-TgzPackage([string]$Archive, [string]$Destination) {
    $tar = "C:\Windows\System32\tar.exe"
    $entries = @(& $tar -tzf $Archive)
    if ($LASTEXITCODE -ne 0 -or $entries.Count -gt 512) {
        throw "Component TGZ listing failed or contains too many entries."
    }
    foreach ($entry in $entries) {
        Assert-SafeArchiveEntry $entry
    }
    & $tar -xzf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "Component TGZ extraction failed."
    }
}

$manifest = Read-IniFile $ManifestPath
$releaseTag = $manifest.Upstream.ReleaseTag
$releaseVersion = $manifest.Component.Version
$repository = $manifest.Upstream.Repository
if (-not $releaseTag -or -not $releaseVersion -or -not $repository) {
    throw "PDFium component manifest is incomplete."
}
$headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "PopDrop-PDFium-Installer"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$release = $null
function Get-PinnedReleaseAsset([string]$AssetName) {
    if (-not $script:release) {
        $apiTag = [Uri]::EscapeDataString($releaseTag)
        $releaseUrl = "https://api.github.com/repos/$repository/releases/tags/$apiTag"
        $script:release = Invoke-RestMethod `
            -Uri $releaseUrl -Headers $headers
    }
    return $script:release.assets |
        Where-Object { $_.name -eq $AssetName } |
        Select-Object -First 1
}
$architectures = if ($Architecture -eq "All") {
    @("x64", "x86")
} else {
    @($Architecture)
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "PopDrop-PDFium-" + [Guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    foreach ($targetArchitecture in $architectures) {
        $component = $manifest[$targetArchitecture]
        $downloadUrl = $component.Url
        $configuredHash = $component.Sha256
        $packageType = $component.PackageType
        if ($packageType -notin @("Dll", "Zip", "Tgz")) {
            throw "PackageType must be Dll, Zip, or Tgz."
        }
        if (-not $downloadUrl.StartsWith(
                "https://", [StringComparison]::OrdinalIgnoreCase)) {
            throw "The configured PDFium URL must use HTTPS."
        }
        $assetName = [IO.Path]::GetFileName(([Uri]$downloadUrl).AbsolutePath)
        if ($configuredHash -eq "FromGitHubRelease") {
            $asset = Get-PinnedReleaseAsset $assetName
            if (-not $asset -or -not $asset.digest -or
                -not $asset.digest.StartsWith("sha256:")) {
                throw "$assetName has no verifiable GitHub SHA-256 digest."
            }
            $expectedHash = $asset.digest.Substring(7).ToUpperInvariant()
        } elseif ($configuredHash -match '^[0-9a-fA-F]{64}$') {
            $expectedHash = $configuredHash.ToUpperInvariant()
        } else {
            throw "The configured PDFium SHA-256 is missing or invalid."
        }

        $packageExtension = switch ($packageType) {
            "Dll" { ".dll" }
            "Zip" { ".zip" }
            "Tgz" { ".tgz" }
        }
        $packagePath = Join-Path $temporaryRoot (
            "pdfium-$targetArchitecture$packageExtension")
        Invoke-WebRequest -Uri $downloadUrl -Headers $headers `
            -OutFile $packagePath
        $package = Get-Item -LiteralPath $packagePath
        if ($package.Length -le 0 -or $package.Length -gt 128MB) {
            throw "Downloaded PDFium package has an unexpected size."
        }
        $actualHash = (Get-FileHash -LiteralPath $packagePath `
            -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Downloaded PDFium package SHA-256 verification failed."
        }

        $license = $null
        if ($packageType -eq "Dll") {
            $dll = $package
        } else {
            $extractRoot = Join-Path $temporaryRoot $targetArchitecture
            New-Item -ItemType Directory -Path $extractRoot | Out-Null
            if ($packageType -eq "Zip") {
                Expand-ZipPackage $packagePath $extractRoot
            } else {
                Expand-TgzPackage $packagePath $extractRoot
            }
            $dlls = @(Get-ChildItem -LiteralPath $extractRoot `
                -Filter "pdfium.dll" -File -Recurse)
            if ($dlls.Count -ne 1) {
                throw "Component archive must contain exactly one pdfium.dll."
            }
            $dll = $dlls[0]
            $license = Get-ChildItem -LiteralPath $extractRoot `
                -Filter "LICENSE" -File -Recurse |
                Select-Object -First 1
        }

        $destination = if ($DestinationDirectory) {
            $DestinationDirectory
        } else {
            Join-Path $PSScriptRoot "bin\$targetArchitecture"
        }
        if ($dll.Length -lt 1MB -or $dll.Length -gt 32MB) {
            throw "Downloaded pdfium.dll has an unexpected size."
        }
        Assert-DllArchitecture $dll.FullName $targetArchitecture
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        $stagingDll = Join-Path $destination "pdfium.dll.installing"
        Remove-Item -LiteralPath $stagingDll -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $dll.FullName `
            -Destination $stagingDll -Force
        Move-Item -LiteralPath $stagingDll `
            -Destination (Join-Path $destination "pdfium.dll") -Force
        if ($license) {
            $licenseRoot = Join-Path $PSScriptRoot "third_party\pdfium"
            New-Item -ItemType Directory -Force -Path $licenseRoot |
                Out-Null
            Copy-Item -LiteralPath $license.FullName `
                -Destination (Join-Path $licenseRoot "LICENSE") -Force
            Set-Content -LiteralPath (Join-Path $licenseRoot "VERSION") `
                -Value $releaseVersion -Encoding ASCII
        }
        Write-Host ("Installed PDFium {0} ({1}, {2:N1} MB)" -f `
            $releaseVersion, $targetArchitecture, ($dll.Length / 1MB))
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host "PDFium installation complete. Restart PopDrop to use it."
