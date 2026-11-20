# Fluent PresentMon MSIX Distribution

Fluent PresentMon is distributed exclusively as an x64 MSIX package for Windows 11 (build 22000 or newer), built and signed with the [Windows App Development CLI (`winapp`)](https://github.com/microsoft/WinAppCli).

## Prerequisites

- Visual Studio 2026 18.7 or newer with Desktop development with C++ and Windows SDK 10.0.26100
- `winapp` CLI:
  ```powershell
  winget install Microsoft.winappcli --source winget
  ```
- x64 retail `Microsoft.VCLibs.Desktop` framework (installed with Windows SDK / Visual Studio)

## Build and Sign

### 1. Local development / self-signed workflow

Generate a self-signed development certificate matching `Package.appxmanifest` and trust it once from an administrator PowerShell:

```powershell
winapp cert generate --manifest IntelPresentMon\PMInstaller\Package.appxmanifest --output build\devcert.pfx
# Run once as Administrator:
winapp cert install build\devcert.pfx
```

Build, package, and sign the MSIX (with `uiAccess=true` enabled on `PresentMon.exe`):

```powershell
.\Tools\build-installer.ps1 -CertPath build\devcert.pfx
```

Useful options:
- `-SkipRestore`: skip vcpkg and NuGet restore on repeat builds
- `-SkipBuild`: repackage existing `build\Release` and `build\Release\msix-ui` outputs without recompiling
- `-CertPassword <pwd>`: PFX password (default: `password`, matching `winapp cert generate`)
- `-TimestampUrl <url>`: add RFC 3161 timestamping for production signing
- `-RunNativeTests`: run native capture and overlay tests before packaging

### 2. Unsigned validation build

To build an unsigned Release MSIX without a certificate (`uiAccess` disabled, unsigned publisher namespace):

```powershell
.\Tools\build-installer.ps1 -UnsignedRelease
```

On Windows 11, an unsigned package can be installed for local validation from an administrator PowerShell with `Add-AppxPackage -AllowUnsigned`. Its package identity differs intentionally from a signed build.

## Output Layout

Each run creates a fresh directory under `build\Release\MSIX\<guid>` and updates `build\Release\MSIX\latest-package.txt` after structural validation passes.

Distribute these together for offline installation:
- `FluentPresentMon_<version>_x64.msix`
- `Dependencies\x64\` (`Microsoft.WindowsAppRuntime.2` and `Microsoft.VCLibs.140.00.UWPDesktop`)
- `Install.ps1`

`Layout\`, `ResourceInput\`, `resources.xml`, `kernel.manifest`, and `size-report.json` are build artifacts and do not need to be distributed.

## Dependencies and Package Contents

- The WinUI 3 UI (`ui\PresentMonUI.exe`) is built with `/p:PresentMonMsix=true` as a framework-dependent C++/WinRT binary (no .NET runtime required).
- `Microsoft.WindowsAppRuntime.2` and `Microsoft.VCLibs.140.00.UWPDesktop` remain external shared frameworks in `Dependencies\x64`. DirectML and ONNX Runtime are not copied into the app package.
- ETW provider manifest registration is intentionally omitted; PresentMon decodes frame and application-timing events using built-in structures without requiring SCCD or a companion MSI.
- Increment `PresentMonFileVersion` in `Version.props` for package upgrades.

## Install, Update, and Remove

Run `Install.ps1` from an administrator **Windows PowerShell 5.1** prompt:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

- Administrator privileges are required for the packaged LocalSystem service (`FluentPresentMonService`).
- `Install.ps1` reuses already-installed compatible frameworks, deploys missing frameworks from `Dependencies\x64`, stops the packaged service during updates, installs the MSIX, and starts `FluentPresentMonService`.
- Package identity (`Fluent.PresentMon`), service (`FluentPresentMonService`), pipes, ETW session, shared memory, registry keys, settings (`Documents\FluentPresentMon`), and logs (`%LOCALAPPDATA%\FluentPresentMon`) are isolated from upstream Intel PresentMon.
- AppData and registry write virtualization are disabled so user settings and captures survive uninstall.
- Remove the app via Windows Settings or `Get-AppxPackage Fluent.PresentMon | Remove-AppxPackage`.

## Verification

- Every build automatically runs `Tools\test-msix-package.ps1` to verify payload files, shared framework declarations, service registration, UIAccess capability, execution aliases, and absence of bundled framework copies.
- After installing the package, run `.\Tools\test-msix-installed.ps1` from a normal user Windows PowerShell 5.1 prompt to verify the installed service and overlay.
