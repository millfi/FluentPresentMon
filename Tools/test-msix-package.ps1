[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$DependencyDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unsignedPublisherOid = 'OID.2.25.311729368913984317654407730594956997722=1'

function Assert-Package([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "MSIX validation failed: $Message" }
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

$manifest = Read-AppxManifest $Package
Assert-Package ($manifest.Package.Identity.Name -eq 'Fluent.PresentMon') 'Unexpected package identity.'
Assert-Package ($manifest.Package.Identity.ProcessorArchitecture -eq 'x64') 'Unexpected architecture.'
Assert-Package ([version]$manifest.Package.Identity.Version -gt [version]'0.0.0.0') 'Unresolved package version.'
Assert-Package ([version]$manifest.Package.Dependencies.TargetDeviceFamily.MinVersion -ge [version]'10.0.22000.0') 'Minimum OS version must be Windows 11.'

$dependencies = @($manifest.Package.Dependencies.PackageDependency)
Assert-Package ($dependencies.Count -eq 2) 'Expected Windows App SDK and VCLibs Desktop dependencies.'
Assert-Package (@($dependencies | Where-Object Name -eq 'Microsoft.WindowsAppRuntime.2').Count -eq 1) 'Missing official Windows App SDK dependency.'
Assert-Package (@($dependencies | Where-Object Name -eq 'Microsoft.VCLibs.140.00.UWPDesktop').Count -eq 1) 'Missing VCLibs Desktop dependency.'

$frameworkFiles = @{}
foreach ($required in $dependencies) {
    $candidates = @(Get-ChildItem -LiteralPath $DependencyDirectory -File | Where-Object Extension -in '.msix', '.appx' | Where-Object {
        $candidate = Read-AppxManifest $_.FullName
        $identity = $candidate.Package.Identity
        $identity.Name -eq $required.Name -and $identity.Publisher -eq $required.Publisher -and
            [version]$identity.Version -ge [version]$required.MinVersion -and $identity.ProcessorArchitecture -eq 'x64' -and
            $candidate.Package.Properties.Framework -eq 'true'
    })
    Assert-Package ($candidates.Count -eq 1) "Missing or incompatible offline dependency: $($required.Name)"
    $framework = [IO.Compression.ZipFile]::OpenRead($candidates[0].FullName)
    try {
        foreach ($entry in $framework.Entries) {
            if ($entry.Name -match '\.(dll|winmd|pri)$') { $frameworkFiles[$entry.Name] = $true }
        }
    }
    finally { $framework.Dispose() }
}

$archive = [IO.Compression.ZipFile]::OpenRead($Package)
try {
    $entries = @{}
    foreach ($entry in $archive.Entries) { $entries[$entry.FullName.Replace('\', '/')] = $entry }

    $isSigned = $entries.ContainsKey('AppxSignature.p7x')
    $hasUiAccess = $null -ne $manifest.SelectSingleNode('//*[local-name()="Capability" and @Name="uiAccess"]')
    if ($isSigned) {
        Assert-Package $hasUiAccess 'Signed MSIX packages must declare the uiAccess capability.'
    }
    else {
        Assert-Package ($manifest.Package.Identity.Publisher -match "(?:^|,\s*)$([regex]::Escape($unsignedPublisherOid))(?:,|$)") `
            'Unsigned packages must use the Windows unsigned publisher namespace.'
        Assert-Package (-not $hasUiAccess) 'Unsigned MSIX packages must omit the uiAccess capability.'
    }

    Assert-Package ($entries.ContainsKey('Distribution.json') -and $entries['Distribution.json'].Length -gt 0) 'Missing Distribution.json.'
    foreach ($path in @('PresentMon.exe', 'PresentMonService.exe', 'PresentMonAPI2.dll', 'PresentMonAPI2Loader.dll', 'ddETWExternal.xml',
        'ui/PresentMonUI.exe', 'ui/PresentMonUI.pri', 'ui/App.xbf', 'ui/MainWindow.xbf', 'resources.pri', 'Assets/AppIcon.png',
        'SDK/PresentMonAPI2Loader.dll', 'SDK/PresentMonAPI2Loader.lib', 'SDK/PresentMonAPI.h',
        'Console/PresentMon.exe',
        'Blocklists/TargetBlockList.txt', 'LICENSE.txt', 'THIRD_PARTY.txt')) {
        Assert-Package ($entries.ContainsKey($path) -and $entries[$path].Length -gt 0) "Required payload missing: $path"
    }
    foreach ($index in 0..3) { Assert-Package ($entries.ContainsKey("Presets/preset-$index.json")) "Missing preset $index." }
    Assert-Package (@($entries.Keys | Where-Object { $_ -like 'Shaders/*.cso' }).Count -gt 0) 'Missing compiled shaders.'

    foreach ($entry in $archive.Entries) {
        Assert-Package ($entry.FullName -eq 'resources.pri' -or -not $frameworkFiles.ContainsKey($entry.Name)) "App-local copy of shared framework file: $($entry.FullName)"
        Assert-Package ($entry.Name -notmatch '\.(pdb|msix|appx)$') "Development or nested package payload: $($entry.FullName)"
    }
    foreach ($application in $manifest.Package.Applications.Application) {
        Assert-Package ($entries.ContainsKey($application.Executable.Replace('\', '/'))) 'Broken application executable path.'
    }
    foreach ($node in $manifest.SelectNodes('//*[local-name()="VisualElements"]')) {
        foreach ($attribute in @('Square150x150Logo', 'Square44x44Logo')) {
            Assert-Package ($entries.ContainsKey($node.GetAttribute($attribute).Replace('\', '/'))) 'Missing Start menu logo.'
        }
    }

    $service = $manifest.SelectSingleNode('//*[local-name()="Service"]')
    Assert-Package ($null -ne $service -and $service.Name -eq 'FluentPresentMonService' -and $service.StartAccount -eq 'localSystem' -and $service.StartupType -eq 'auto') 'Service registration changed.'
    Assert-Package ($service.ParentNode.Executable -eq 'PresentMonService.exe') 'Service executable changed.'
    foreach ($capability in @('runFullTrust', 'packagedServices', 'localSystemServices', 'unvirtualizedResources')) {
        Assert-Package ($null -ne $manifest.SelectSingleNode("//*[local-name()='Capability' and @Name='$capability']")) "Missing capability: $capability"
    }
    Assert-Package ($null -eq $manifest.SelectSingleNode('//*[local-name()="Extension" and @Category="windows.eventTracing"]') -and
        $null -eq $manifest.SelectSingleNode('//*[local-name()="CustomCapability"]')) 'Unexpected ETW registration or custom capability.'
    foreach ($alias in @('fluent-presentmon.exe', 'fluent-presentmon-console.exe')) {
        Assert-Package ($null -ne $manifest.SelectSingleNode("//*[local-name()='ExecutionAlias' and @Alias='$alias']")) "Missing execution alias: $alias"
    }
}
finally { $archive.Dispose() }

Write-Host 'MSIX structural validation passed: payload, shared frameworks, service, UIAccess, and aliases.'
