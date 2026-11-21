[CmdletBinding()]
param(
    [string]$CertPath,
    [string]$CertPassword = 'password',
    [string]$TimestampUrl,
    [switch]$UnsignedRelease,
    [string]$Publisher,
    [switch]$SkipBuild,
    [switch]$SkipRestore,
    [switch]$RunNativeTests,
    [string]$VisualStudioPath,
    [string]$VcpkgRoot = $env:VCPKG_ROOT,
    [string]$VCLibsPackage
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repoRoot = Split-Path $PSScriptRoot -Parent
$installerDir = Join-Path $repoRoot 'IntelPresentMon\PMInstaller'

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
}

function Read-AppxManifest([string]$Path) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw "Missing AppxManifest.xml: $Path" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Get-PackagePayloadBytes([string]$Path) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return [long]($archive.Entries | Where-Object {
            $_.FullName -notmatch '^(AppxMetadata/|AppxBlockMap.xml$|AppxSignature.p7x$|\[Content_Types\].xml$)'
        } | Measure-Object Length -Sum).Sum
    }
    finally { $archive.Dispose() }
}

function Resolve-VisualStudioPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $null }
    $candidates = @(& $vswhere -all -products * -version '[18.7,)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    $withWinStore = @($candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'MSBuild\Microsoft\VC\v180\Application Type\Windows Store') })
    if ($withWinStore.Count -gt 0) { return $withWinStore[0] }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

function Resolve-VcpkgRoot([string]$ExplicitVcpkgRoot, [string]$SelectedVisualStudioPath) {
    if ($ExplicitVcpkgRoot) { return $ExplicitVcpkgRoot }
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($SelectedVisualStudioPath) {
        $candidates.Add((Join-Path $SelectedVisualStudioPath 'VC\vcpkg'))
    }
    $vcpkgCmd = Get-Command vcpkg.exe -ErrorAction SilentlyContinue
    if ($vcpkgCmd -and $vcpkgCmd.Source) {
        $candidates.Add((Split-Path -LiteralPath $vcpkgCmd.Source -Parent))
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        foreach ($vsInstall in @(& $vswhere -all -products * -property installationPath)) {
            if ($vsInstall) {
                $candidates.Add((Join-Path $vsInstall 'VC\vcpkg'))
            }
        }
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'vcpkg.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'scripts\buildsystems\msbuild\vcpkg.targets') -PathType Leaf)) {
            return $candidate
        }
    }
    if ($SelectedVisualStudioPath) { return (Join-Path $SelectedVisualStudioPath 'VC\vcpkg') }
    return $null
}

if (-not (Get-Command winapp -ErrorAction SilentlyContinue)) {
    throw 'winapp CLI is required. Install it with: winget install Microsoft.winappcli --source winget'
}
if (-not $UnsignedRelease -and -not $CertPath) {
    throw 'Pass -CertPath <pfx> to build a signed MSIX (generate one with: winapp cert generate --manifest IntelPresentMon\PMInstaller\Package.appxmanifest --output devcert.pfx), or pass -UnsignedRelease.'
}
if ($UnsignedRelease -and $CertPath) {
    throw '-UnsignedRelease and -CertPath are mutually exclusive.'
}

$resolvedCert = $null
if ($CertPath) {
    $resolvedCert = (Resolve-Path -LiteralPath $CertPath).Path
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($resolvedCert, $CertPassword)
    try {
        if (-not $Publisher) { $Publisher = $cert.Subject }
        elseif ($cert.Subject -cne $Publisher) {
            throw "Certificate subject '$($cert.Subject)' does not match -Publisher '$Publisher'."
        }
    }
    finally { $cert.Dispose() }
}

if (-not $VCLibsPackage) {
    $VCLibsPackage = Join-Path ${env:ProgramFiles(x86)} 'Microsoft SDKs\Windows Kits\10\ExtensionSDKs\Microsoft.VCLibs.Desktop\14.0\Appx\Retail\x64\Microsoft.VCLibs.x64.14.00.Desktop.appx'
}
if (-not (Test-Path -LiteralPath $VCLibsPackage -PathType Leaf)) {
    throw "Required VCLibs Desktop framework package not found: $VCLibsPackage"
}

$originalLocation = Get-Location
$originalModulePath = $env:PSModulePath
$originalExecutablePath = $env:PATH
$originalVisualStudioPath = $env:VCPKG_VISUAL_STUDIO_PATH
try {
    Set-Location $repoRoot
    if (-not $SkipBuild) {
        if (-not $VisualStudioPath) { $VisualStudioPath = Resolve-VisualStudioPath }
        if (-not $VisualStudioPath) { throw 'Install Visual Studio 2026 18.7 or newer with Desktop development with C++ and Windows SDK.' }
        $VcpkgRoot = Resolve-VcpkgRoot -ExplicitVcpkgRoot $VcpkgRoot -SelectedVisualStudioPath $VisualStudioPath
        $msbuild = Join-Path $VisualStudioPath 'MSBuild\Current\Bin\MSBuild.exe'

        $global:LASTEXITCODE = 0
        & (Join-Path $PSScriptRoot 'build-capture-app.ps1') -Configuration Release -UnsignedRelease `
            -SkipRestore:$SkipRestore -RunNativeTests:$RunNativeTests -VisualStudioPath $VisualStudioPath -PlatformToolset v145 -VcpkgRoot $VcpkgRoot
        if ($LASTEXITCODE -ne 0) { throw 'Capture application build failed.' }

        & (Join-Path $PSScriptRoot 'build-ui-cpp.ps1') -Configuration Release -Msix -SkipRestore:$SkipRestore -VisualStudioPath $VisualStudioPath -PlatformToolset v145
        if ($LASTEXITCODE -ne 0) { throw 'Framework-dependent UI build failed.' }

        $env:VCPKG_VISUAL_STUDIO_PATH = $VisualStudioPath
        $env:PSModulePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"
        Remove-Item Env:PATH -ErrorAction SilentlyContinue
        $env:Path = $originalExecutablePath
        $nativeArguments = @('/m:4', '/nr:false', '/nologo', '/v:minimal', '/p:Configuration=Release',
            '/p:Platform=x64', '/p:PlatformToolset=v145', '/p:CL_MPCount=4', '/p:SkipNativeGuiBuild=true',
            '/p:UnsignedRelease=true', "/p:SolutionDir=$repoRoot\", '/p:VcpkgManifestInstall=false',
            "/p:VcpkgInstalledDir=$repoRoot\vcpkg_installed\",
            "/p:ForceImportAfterCppTargets=$VcpkgRoot\scripts\buildsystems\msbuild\vcpkg.targets")
        foreach ($project in @('PresentMon\PresentMon.vcxproj', 'IntelPresentMon\PresentMonAPI2Loader\PresentMonAPI2Loader.vcxproj')) {
            Invoke-Checked $msbuild (@($project) + $nativeArguments)
        }
    }

    $nativeRoot = Join-Path $repoRoot 'build\Release'
    $uiRoot = Join-Path $nativeRoot 'msix-ui'
    $output = Join-Path $repoRoot ('build\Release\MSIX\' + [guid]::NewGuid().ToString('N'))
    $layout = Join-Path $output 'Layout'
    $dependencies = Join-Path $output 'Dependencies\x64'
    New-Item -ItemType Directory -Path $layout, $dependencies -Force | Out-Null

    function Copy-Payload([string]$Source, [string]$RelativePath) {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required payload missing: $Source" }
        $destination = Join-Path $layout $RelativePath
        if (Test-Path -LiteralPath $destination) { throw "Duplicate payload destination: $RelativePath" }
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $destination
    }

    foreach ($name in @('PresentMon.exe', 'PresentMonService.exe', 'PresentMonAPI2.dll', 'PresentMonAPI2Loader.dll', 'ddETWExternal.xml')) {
        Copy-Payload (Join-Path $nativeRoot $name) $name
    }
    foreach ($directory in @('Shaders', 'Presets', 'Blocklists')) {
        $source = Join-Path $nativeRoot $directory
        $files = @(Get-ChildItem -LiteralPath $source -Recurse -File)
        if (-not $files) { throw "Required payload directory is empty: $source" }
        foreach ($file in $files) { Copy-Payload $file.FullName ($directory + '\' + $file.FullName.Substring($source.Length + 1)) }
    }
    foreach ($name in @('PresentMonUI.exe', 'PresentMonUI.pri', 'App.xbf', 'MainWindow.xbf', 'PresentMon.UI.winmd', 'Assets\AppIcon.ico', 'Assets\AppIcon.png')) {
        Copy-Payload (Join-Path $uiRoot $name) ('ui\' + $name)
    }
    Copy-Payload (Join-Path $uiRoot 'Assets\AppIcon.png') 'Assets\AppIcon.png'

    $uciRoot = if ($env:PMON_UCI_SDK_DIR) { $env:PMON_UCI_SDK_DIR } else { Join-Path $repoRoot 'IntelPresentMon\ControlLib\uci\external' }
    if (Test-Path -LiteralPath $uciRoot) {
        $uciRoot = (Resolve-Path -LiteralPath $uciRoot).Path.TrimEnd('\')
        foreach ($file in Get-ChildItem -LiteralPath $uciRoot -Recurse -File) {
            Copy-Payload $file.FullName $file.FullName.Substring($uciRoot.Length + 1)
        }
    }
    foreach ($name in @('LICENSE.txt', 'THIRD_PARTY.txt')) { Copy-Payload (Join-Path $repoRoot $name) $name }
    foreach ($name in @('PresentMonAPI2Loader.dll', 'PresentMonAPI2Loader.lib')) { Copy-Payload (Join-Path $nativeRoot $name) ('SDK\' + $name) }
    Copy-Payload (Join-Path $repoRoot 'IntelPresentMon\PresentMonAPI2\PresentMonAPI.h') 'SDK\PresentMonAPI.h'

    [xml]$versions = Get-Content -LiteralPath (Join-Path $repoRoot 'Version.props') -Raw
    $version = $versions.SelectSingleNode('//*[local-name()="PresentMonFileVersion"]').InnerText
    $consoleVersion = $versions.SelectSingleNode('//*[local-name()="PresentMonVersion"]').InnerText
    Copy-Payload (Join-Path $nativeRoot "PresentMon-$consoleVersion-x64.exe") 'Console\PresentMon.exe'

    # Prepare AppxManifest.xml with version, publisher, UIAccess, and signed framework dependencies.
    [xml]$manifest = Get-Content -LiteralPath (Join-Path $installerDir 'Package.appxmanifest') -Raw
    $manifest.Package.Identity.SetAttribute('Version', $version)
    $basePublisher = if ($Publisher) { $Publisher } else { $manifest.Package.Identity.Publisher }
    $unsignedPublisherOid = 'OID.2.25.311729368913984317654407730594956997722=1'
    $manifestPublisher = if ($UnsignedRelease) { "$basePublisher, $unsignedPublisherOid" } else { $basePublisher }
    $manifest.Package.Identity.SetAttribute('Publisher', $manifestPublisher)
    if ($UnsignedRelease) {
        $uiAccessCap = $manifest.SelectSingleNode('//*[local-name()="Capability" and @Name="uiAccess"]')
        if ($uiAccessCap) { [void]$uiAccessCap.ParentNode.RemoveChild($uiAccessCap) }
    }

    $frameworkPaths = @(Get-Content -LiteralPath (Join-Path $uiRoot 'framework-package.txt') | Where-Object { $_.Trim() })
    if ($frameworkPaths.Count -ne 1) { throw 'Expected exactly one resolved x64 Windows App SDK framework.' }
    $frameworkPaths += $VCLibsPackage
    foreach ($frameworkPath in $frameworkPaths) {
        $frameworkManifest = Read-AppxManifest $frameworkPath
        $identity = $frameworkManifest.Package.Identity
        if ($identity.ProcessorArchitecture -ne 'x64' -or $frameworkManifest.Package.Properties.Framework -ne 'true') {
            throw "Not an x64 framework package: $frameworkPath"
        }
        Invoke-Checked winapp @('tool', 'signtool', '--', 'verify', '/pa', $frameworkPath)
        $dependency = $manifest.CreateElement('PackageDependency', $manifest.DocumentElement.NamespaceURI)
        $dependency.SetAttribute('Name', $identity.Name)
        $dependency.SetAttribute('Publisher', $identity.Publisher)
        $dependency.SetAttribute('MinVersion', $identity.Version)
        [void]$manifest.Package.Dependencies.AppendChild($dependency)
        Copy-Item -LiteralPath $frameworkPath -Destination $dependencies
    }
    $manifestPath = Join-Path $layout 'AppxManifest.xml'
    $manifest.Save($manifestPath)

    # Generate scale/targetsize tile assets from the application icon via winapp CLI.
    Invoke-Checked winapp @('manifest', 'update-assets', (Join-Path $uiRoot 'Assets\AppIcon.ico'), '--manifest', $manifestPath)

    # Merge WinUI XBF/localized resources and generated assets into root resources.pri.
    $resourceInput = Join-Path $output 'ResourceInput'
    New-Item -ItemType Directory -Path (Join-Path $resourceInput 'Assets') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $uiRoot 'PresentMonUI.pri') -Destination $resourceInput
    Copy-Item -Path (Join-Path $layout 'Assets\*') -Destination (Join-Path $resourceInput 'Assets') -Force
    Invoke-Checked winapp @('tool', 'makepri', '--', 'new', '/pr', $resourceInput, '/cf', (Join-Path $installerDir 'priconfig.xml'),
        '/in', 'Fluent.PresentMon', '/of', (Join-Path $layout 'resources.pri'), '/o')
    Invoke-Checked winapp @('tool', 'makepri', '--', 'dump', '/if', (Join-Path $layout 'resources.pri'), '/of', (Join-Path $output 'resources.xml'), '/dt', 'detailed', '/o')
    [xml]$resourceDump = Get-Content -LiteralPath (Join-Path $output 'resources.xml') -Raw
    if (-not $resourceDump.SelectSingleNode('//ResourceMap[@name="Fluent.PresentMon"]//NamedResource[@name="MainWindow.xbf"]')) {
        throw 'Packaged XAML resources were not indexed under the package identity.'
    }

    # Record native build metadata inside the package.
    $buildId = Get-Content -LiteralPath (Join-Path $repoRoot 'IntelPresentMon\Versioning\generated\build_id.h') -Raw
    $commitMatch = [regex]::Match($buildId, '(?m)^#define PM_BID_GIT_HASH "([^"]+)"')
    $dirtyMatch = [regex]::Match($buildId, '(?m)^#define PM_BID_DIRTY (true|false)')
    if (-not $commitMatch.Success -or -not $dirtyMatch.Success) { throw 'Native build identity is missing or invalid.' }
    [ordered]@{
        Version = $version
        CommitHash = $commitMatch.Groups[1].Value
        SourceModified = $dirtyMatch.Groups[1].Value -eq 'true'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $layout 'Distribution.json') -Encoding utf8

    # Update PresentMon.exe embedded manifest for UIAccess and sign the kernel executable when signing.
    $kernel = Join-Path $layout 'PresentMon.exe'
    $kernelManifest = Join-Path $output 'kernel.manifest'
    Invoke-Checked winapp @('tool', 'mt', '--', '-nologo', "-inputresource:$kernel;#1", "-out:$kernelManifest")
    [xml]$kernelXml = Get-Content -LiteralPath $kernelManifest -Raw
    $kernelXml.SelectSingleNode('//*[local-name()="requestedExecutionLevel"]').SetAttribute('uiAccess', (-not $UnsignedRelease).ToString().ToLowerInvariant())
    $kernelXml.Save($kernelManifest)
    Invoke-Checked winapp @('tool', 'mt', '--', '-nologo', '-manifest', $kernelManifest, "-outputresource:$kernel;#1")
    if (-not $UnsignedRelease) {
        $signArgs = @('sign', $kernel, $resolvedCert, '--password', $CertPassword)
        if ($TimestampUrl) { $signArgs += @('--timestamp', $TimestampUrl) }
        Invoke-Checked winapp $signArgs
    }

    # Pack and sign the MSIX via winapp CLI.
    $package = Join-Path $output "FluentPresentMon_${version}_x64.msix"
    if ($UnsignedRelease) {
        Invoke-Checked winapp @('package', $layout, '--output', $package, '--skip-pri', '--no-sign')
    }
    elseif ($TimestampUrl) {
        Invoke-Checked winapp @('package', $layout, '--output', $package, '--skip-pri', '--no-sign')
        Invoke-Checked winapp @('sign', $package, $resolvedCert, '--password', $CertPassword, '--timestamp', $TimestampUrl)
    }
    else {
        Invoke-Checked winapp @('package', $layout, '--output', $package, '--skip-pri', '--cert', $resolvedCert, '--cert-password', $CertPassword)
    }

    foreach ($name in @('Install.ps1', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $installerDir $name) -Destination $output
    }

    & (Join-Path $repoRoot 'Tools\test-msix-package.ps1') -Package $package -DependencyDirectory $dependencies

    $appBytes = Get-PackagePayloadBytes $package
    $frameworkBytes = [long]($frameworkPaths | ForEach-Object { Get-PackagePayloadBytes $_ } | Measure-Object -Sum).Sum
    [ordered]@{
        Package = $package
        AppPayloadBytes = $appBytes
        SharedFrameworkPayloadBytes = $frameworkBytes
        WithFrameworksAlreadyInstalledBytes = $appBytes
        FreshMachinePayloadBytes = $appBytes + $frameworkBytes
        Note = 'Logical payload bytes; excludes filesystem allocation, metadata, servicing versions and cross-package file deduplication.'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'size-report.json') -Encoding utf8
    $package | Set-Content -LiteralPath (Join-Path $repoRoot 'build\Release\MSIX\latest-package.txt') -Encoding utf8

    Write-Host "MSIX: $package"
    Write-Host "Offline distribution: $output (MSIX, Dependencies and Install.ps1)"
    Write-Host "App payload: $appBytes bytes; shared frameworks: $frameworkBytes bytes."
}
finally {
    $env:PSModulePath = $originalModulePath
    $env:Path = $originalExecutablePath
    $env:VCPKG_VISUAL_STUDIO_PATH = $originalVisualStudioPath
    Set-Location $originalLocation
}
