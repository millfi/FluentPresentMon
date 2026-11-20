#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$Package)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

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

if (-not $Package) {
    $packages = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'FluentPresentMon_*.msix' -File)
    if ($packages.Count -ne 1) { throw 'Pass -Package with exactly one PresentMon MSIX.' }
    $Package = $packages[0].FullName
}

$manifest = Read-AppxManifest $Package
if ($manifest.Package.Identity.Name -ne 'Fluent.PresentMon') { throw 'This installer only supports Fluent.PresentMon.' }
if ([Environment]::OSVersion.Version -lt [version]$manifest.Package.Dependencies.TargetDeviceFamily.MinVersion) {
    throw 'This MSIX requires Windows 11 or newer.'
}

$existingPackage = @(Get-AppxPackage -Name Fluent.PresentMon)
if ($existingPackage.Count -eq 0 -and (Get-Service -Name FluentPresentMonService -ErrorAction SilentlyContinue)) {
    throw 'An existing FluentPresentMonService is owned outside this MSIX. Resolve its ownership before installation.'
}

$dependencyPaths = @()
$available = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Dependencies\x64') -File | Where-Object Extension -in '.msix', '.appx')
foreach ($required in $manifest.Package.Dependencies.PackageDependency) {
    $installed = @(Get-AppxPackage -Name $required.Name | Where-Object {
        $_.Publisher -eq $required.Publisher -and $_.Architecture -eq 'X64' -and [version]$_.Version -ge [version]$required.MinVersion
    })
    if ($installed.Count -gt 0) { continue }
    $match = @($available | Where-Object {
        $candidate = Read-AppxManifest $_.FullName
        $identity = $candidate.Package.Identity
        $identity.Name -eq $required.Name -and $identity.Publisher -eq $required.Publisher -and
            $identity.ProcessorArchitecture -eq 'x64' -and [version]$identity.Version -ge [version]$required.MinVersion -and
            $candidate.Package.Properties.Framework -eq 'true'
    })
    if ($match.Count -ne 1) { throw "Missing or ambiguous framework dependency: $($required.Name)" }
    $dependencyPaths += $match[0].FullName
}

$parameters = @{ Path = $Package }
if ($dependencyPaths.Count -gt 0) { $parameters.DependencyPath = $dependencyPaths }

# Windows checks signatures and trust. Never import certificates or remove shared frameworks here.
$restartService = $false
try {
    $service = Get-CimInstance Win32_Service -Filter "Name='FluentPresentMonService'"
    if ($service -and $service.State -eq 'Running') {
        if ($existingPackage.Count -ne 1 -or $service.PathName.TrimStart('"') -notlike ($existingPackage[0].InstallLocation + '\*')) {
            throw 'The running service does not belong to the installed MSIX.'
        }
        Stop-Service -Name FluentPresentMonService
        $restartService = $true
    }
    Add-AppxPackage @parameters
    Start-Service -Name FluentPresentMonService
    $restartService = $false
}
finally {
    if ($restartService) { Start-Service -Name FluentPresentMonService }
}
Write-Host 'Fluent PresentMon installed. Launch Fluent PresentMon from Start, or use fluent-presentmon.exe / fluent-presentmon-console.exe.'
