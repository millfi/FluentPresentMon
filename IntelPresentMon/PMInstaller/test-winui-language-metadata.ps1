[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$harvestScript = Join-Path $scriptRoot 'harvest-winui.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('presentmon-harvest-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $scratch 'payload'
$wixFile = Join-Path $scratch 'WinUIFiles.wxs'
$specialFiles = @(
    'Microsoft.UI.Xaml.dll',
    'Microsoft.UI.Xaml.Phone.dll',
    'gd-gb\Microsoft.ui.xaml.dll.mui',
    'gd-gb\Microsoft.UI.Xaml.Phone.dll.mui',
    'mi-NZ\Microsoft.ui.xaml.dll.mui',
    'mi-NZ\Microsoft.UI.Xaml.Phone.dll.mui',
    'ug-CN\Microsoft.ui.xaml.dll.mui',
    'ug-CN\Microsoft.UI.Xaml.Phone.dll.mui'
)

function Write-TestPe {
    param([string]$Path)

    $bytes = [byte[]]::new(512)
    [BitConverter]::GetBytes([uint16]0x5a4d).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([uint32]0x80).CopyTo($bytes, 0x3c)
    [BitConverter]::GetBytes([uint32]0x00004550).CopyTo($bytes, 0x80)
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Language metadata test failed: $Message" }
}

try {
    [void][IO.Directory]::CreateDirectory($payload)
    Write-TestPe -Path (Join-Path $payload 'PresentMonUI.exe')
    Write-TestPe -Path (Join-Path $payload 'Microsoft.UI.Xaml.dll')
    Write-TestPe -Path (Join-Path $payload 'Microsoft.UI.Xaml.Phone.dll')
    [IO.File]::WriteAllBytes((Join-Path $payload 'PresentMonUI.pri'), [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes((Join-Path $payload 'ordinary.dll'), [byte[]](4, 5, 6))
    foreach ($relativePath in $specialFiles | Where-Object { $_ -notin @('Microsoft.UI.Xaml.dll', 'Microsoft.UI.Xaml.Phone.dll') }) {
        $path = Join-Path $payload $relativePath
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.File]::WriteAllBytes($path, [byte[]](7, 8, 9))
    }

    $global:LASTEXITCODE = 0
    & $harvestScript -OutputRoot $payload -WixFile $wixFile
    if ($LASTEXITCODE -ne 0) { throw "Harvest script failed with exit code $LASTEXITCODE." }
    [xml]$document = Get-Content -LiteralPath $wixFile -Raw
    $namespace = 'http://schemas.microsoft.com/wix/2006/wi'
    $manager = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $manager.AddNamespace('w', $namespace)
    $prefix = '$(var.WinUIOutputDir)\'
    $files = @($document.SelectNodes('//w:File', $manager))

    foreach ($relativePath in $specialFiles) {
        $source = $prefix + $relativePath
        $node = @($files | Where-Object { $_.GetAttribute('Source') -ceq $source })
        Assert-Condition ($null -ne $node -and $node.Count -eq 1) "Missing harvested file $relativePath."
        Assert-Condition ($node[0].GetAttribute('Language') -ceq '0') "Expected neutral language metadata for $relativePath."
    }
    $ordinary = @($files | Where-Object { $_.GetAttribute('Source') -ceq ($prefix + 'ordinary.dll') })
    Assert-Condition ($ordinary.Count -eq 1) 'Missing ordinary harvested file.'
    Assert-Condition (-not $ordinary[0].HasAttribute('Language')) 'Ordinary file received unexpected language metadata.'
    Write-Host 'WinUI MSI language metadata tests passed (8 neutral framework entries).'
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
