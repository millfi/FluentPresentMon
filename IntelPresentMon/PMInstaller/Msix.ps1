Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-MsixIdentityTool {
    $candidates = @()
    if ($env:PRESENTMON_MSIX_IDENTITY_TOOL) {
        $candidates += [IO.Path]::GetFullPath($env:PRESENTMON_MSIX_IDENTITY_TOOL)
    }
    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($PSScriptRoot))
    while ($current) {
        $candidates += Join-Path $current.FullName 'PresentMonMsixIdentity.exe'
        $candidates += Join-Path $current.FullName 'build\Release\PresentMonMsixIdentity.exe'
        $candidates += Join-Path $current.FullName 'build\Debug\PresentMonMsixIdentity.exe'
        $current = $current.Parent
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw 'PresentMonMsixIdentity.exe is missing. Build IntelPresentMon\PMInstaller\MsixIdentity.vcxproj first.'
}

function Invoke-MsixIdentity {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $tool = Get-MsixIdentityTool
    $output = @(& $tool @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $message = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
        if (-not $message) { $message = "PresentMonMsixIdentity.exe failed with exit code $LASTEXITCODE." }
        throw $message
    }
    $result = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    if (-not $result) { throw 'PresentMonMsixIdentity.exe returned no result.' }
    return $result
}

function Get-MsixFamilyName {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Publisher)
    return Invoke-MsixIdentity @('family-name', $Name, $Publisher)
}

function Get-MsixCertificateSignatureHash {
    param([Parameter(Mandatory)][string]$CertificatePath)
    return Invoke-MsixIdentity @('signature-hash', [IO.Path]::GetFullPath($CertificatePath))
}

function Read-MsixManifest {
    param([Parameter(Mandatory)][string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw "Missing AppxManifest.xml: $Path" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Read-MsixDistribution {
    param([Parameter(Mandatory)][string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('Distribution.json')
        if (-not $entry) { throw "Missing Distribution.json: $Path" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $distribution = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($distribution.EtwRegistration -notin @('None', 'Msix', 'Msi')) { throw 'Invalid ETW distribution mode.' }
        return $distribution
    }
    finally { $archive.Dispose() }
}

function Invoke-MsixTool {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
}

function Get-MsixPayloadBytes {
    param([string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return [long]($archive.Entries | Where-Object {
            $_.FullName -notmatch '^(AppxMetadata/|AppxBlockMap.xml$|AppxSignature.p7x$|\[Content_Types\].xml$)'
        } | Measure-Object Length -Sum).Sum
    }
    finally { $archive.Dispose() }
}
