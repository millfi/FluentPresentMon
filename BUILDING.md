# Building PresentMon

## Install Build Tool Dependencies

- Visual Studio 2026 18.7 or newer (Community/Professional/Enterprise) or Visual Studio Build Tools 2026 18.7 or newer with Desktop development with C++, Windows SDK 10.0.26100, and C++ test tools. The native WinUI package references require this toolchain (including the `Windows Store` C++ MSBuild targets); the current validated installation is Visual Studio 2026 18.9+.

- Windows App SDK build prerequisites are restored through the native project's PackageReference entries.

- [vcpkg](https://github.com/microsoft/vcpkg)

- [CMake](https://cmake.org)

- [winapp CLI](https://github.com/microsoft/WinAppCli) (`winget install Microsoft.winappcli --source winget`) and the x64 retail VCLibs Desktop framework (for MSIX packaging).

Note: if you only want to build the PresentData library, or the PresentMon Console application
you only need Visual Studio.  Ignore the other build and source dependency instructions and build
`PresentData\PresentData.vcxproj` or `PresentMon\ConsoleApplication.sln`.

## Install Source Dependencies

1. Run the repository bootstrap script:

    ```powershell
    > cd PresentMonRepoDir
    > .\bootstrap.ps1
    ```

    The bootstrap script:

    - Pulls the pinned auxiliary test data.
    - Restores NuGet packages for the unpackaged native WinUI 3 application.

    Use `-SkipAuxiliaryData` when the ETL regression data is not needed. See [auxiliary test data](Tests/auxdata.md) for the full regression fixtures.

    The capture application uses WinUI 3. Its bundled presets and blocklist are in `IntelPresentMon\AppWinUICpp\Assets`; the native kernel stages these assets alongside the executable.

2. Create and install a trusted test certificate. This is required for the default signed Release build. The opt-in unsigned Release workflow below does not require a certificate. For the signed workflow, open a command shell as administrator and run the following:

    ```bat
    > makecert -r -pe -n "CN=Test Certificate - For Internal Use Only" -ss PrivateCertStore testcert.cer
    > certutil -addstore root testcert.cer
    ```

## Building PresentMon

For a complete local capture application without building the MSI, run:

```powershell
> .\Tools\build-capture-app.ps1 -Configuration Debug -RunNativeTests
```

This discovers Visual Studio 2026 (either full IDE editions or Visual Studio Build Tools 2026) and resolves `vcpkg` in order from `-VcpkgRoot` / `VCPKG_ROOT`, the selected Visual Studio installation's `VC\vcpkg`, `PATH`, or another installed Visual Studio instance (so Build Tools installations without a bundled `vcpkg` still work). When restoring native dependencies, `build-capture-app.ps1` initializes the selected Visual Studio developer environment (`VC\Auxiliary\Build\vcvarsall.bat amd64`) before running `vcpkg install`, ensuring `vcpkg` uses the selected IDE or Build Tools instance even when both are installed side by side. It then restores the native WinUI package references, builds the WinUI application, capture kernel, service, and middleware, and builds and runs the native unit tests. Dependency build files stay under `build\vcpkg-cache` and `vcpkg_installed`; vcpkg may also use its standard user registry and binary caches. Use `-SkipRestore` on subsequent builds. `-VisualStudioPath`, `-VcpkgRoot`, and `-PlatformToolset` select explicit tool installations. The native UI requires the v145 toolset from Visual Studio 2026. No global vcpkg integration is required by this script.

`-RunNativeTests` also builds `PresentMonAPI2Tests` and runs the
`UiProcessGuardTests` class plus `RealtimeTrackProcessTest`. The UI guards
verify foregrounding an existing minimized UI, replacing an existing UI, and
the corresponding concurrent-launch cases. The realtime test requires the
staged service and a PresentBench frame source. Broader service and API
integration scenarios in that project are not selected by the capture helper.
It then builds and runs the native overlay smoke host. That host starts
PresentBench and a staged `--svc-as-child` kernel with generated control-pipe,
shared-memory, ETW, UI-mutex, log, and UI-data names. It pushes the Basic
preset and requires a visible kernel-owned overlay for five seconds without
touching installed-service state or user preferences.

For an optimized local Release build without certificate setup or signing, explicitly opt in:

```powershell
> .\Tools\build-capture-app.ps1 -Configuration Release -UnsignedRelease
```

`-UnsignedRelease` is accepted only with `-Configuration Release`. It forwards `/p:UnsignedRelease=true` to native MSBuild, skips the kernel's signing step, and sets its manifest to `uiAccess=false`. Release optimization and `NDEBUG` remain enabled. The default Release workflow retains signing and `uiAccess=true`; omitting the switch preserves that behavior. This switch does not create or trust certificates, install the MSI, or change Windows security settings. To opt in when directly invoking MSBuild for a Release application or solution build, pass `/p:UnsignedRelease=true`.

To build and sign the Release MSIX using `winapp` CLI:

```powershell
> winapp cert generate --manifest IntelPresentMon\PMInstaller\Package.appxmanifest --output build\devcert.pfx
> winapp cert install build\devcert.pfx   # run once as Administrator
> .\Tools\build-installer.ps1 -CertPath build\devcert.pfx
```

To build and validate a local unsigned Release MSIX without certificate setup, run:

```powershell
> .\Tools\build-installer.ps1 -UnsignedRelease
```

The helper builds the capture application, console and SDK loader, then builds an isolated framework-dependent UI and packages/validates the MSIX via `winapp` CLI. `build\Release\MSIX\latest-package.txt` points to the most recent successful package. Use `-SkipRestore` after restore, `-SkipBuild` to repackage existing Release outputs, and `-RunNativeTests` for the capture tests. On Windows 11, the unsigned package uses the Windows unsigned publisher namespace and can be installed for local testing with `Add-AppxPackage -AllowUnsigned` from an administrator PowerShell; its package identity is intentionally different from a signed build. See [MSIX deployment](IntelPresentMon/PMInstaller/README.md) for signing, offline installation, and size accounting.

The installer uses Microsoft-signed Windows App SDK and VCLibs framework packages shared with other MSIX apps. DirectML and ONNX Runtime are not in the PresentMon package; they remain in Microsoft's standard framework. `Dependencies\x64` provides the original signed dependencies for offline installation.

When building native solution projects directly, pass `/p:PlatformToolset=v145` and configure vcpkg MSBuild integration. `Reflector` is a native refresh tool for the checked-in reflection header. Use `Tools\build-installer.ps1` for the MSIX distribution.

Restore the native WinUI project first with `bootstrap.ps1`. Normal UI builds remain unpackaged and self-contained under `build\Debug\ui` or `build\Release\ui`. The complete development `ui` directory must stay next to `PresentMon.exe`. MSIX builds use `/p:PresentMonMsix=true`, separate intermediates and `build\Release\msix-ui`; these binaries require package registration and the declared frameworks. Neither deployment requires .NET. Overlay shaders, presets and blocklists are staged by `KernelProcess`.

To iterate on the UI alone:

```powershell
> .\Tools\build-ui-cpp.ps1 -Configuration Debug
```

Pass `-RunTests` to `build-ui-cpp.ps1` to run native core and protocol checks, backdrop smoke, and shell smoke checks. When directly building `KernelProcess.vcxproj`, `/p:SkipNativeGuiBuild=true` skips its WinUI build dependency. Use this only when the UI output is already staged or when testing headless commands. `Release-EDSS` uses the Release WinUI payload.

## Running PresentMon

### Intel PresentMon

`PresentMon.exe` starts the native capture kernel and the WinUI 3 control panel, `ui\PresentMonUI.exe`. The two processes use the existing named-pipe action protocol; the kernel continues to own capture, overlay rendering, and global hotkeys.

For Debug builds, the easiest IDE workflow is to set `Client/KernelProcess` as the startup project and launch `PresentMon.exe` with the service running as a child process:

```bat
> --svc-as-child --files-working --log-level verbose --middleware-dll-path .\PresentMonAPI2.dll --log-middleware-copy
```

From PowerShell, run the complete development payload with:

```powershell
> Push-Location build\Debug
> .\PresentMon.exe --svc-as-child --files-working --middleware-dll-path .\PresentMonAPI2.dll
> Pop-Location
```

For UI layout checks without capture, run `build\Debug\ui\PresentMonUI.exe` directly. Capture and overlay controls require launching through `PresentMon.exe`. A normal launch uses the installed service; a `--svc-as-child` development launch uses the staged child service and ends with its parent. If a normal launch cannot capture frames, check the installed PresentMon service before retrying; do not terminate unrelated service or test processes.

For default signed Release builds with `uiAccess=true`, either move the full Release output payload to a secure directory such as "Program Files" or "System32", or disable the secure directory check for local development. You cannot run these builds from the IDE typically. An opt-in unsigned Release build uses `uiAccess=false` and can be launched from `build\Release` with the development command shown above; it does not request UIAccess privileges. The installer is often the easier path for signed Release validation:

```powershell
> .\Tools\build-installer.ps1 -CertPath build\devcert.pfx
```

### PresentMon Service

To start the service, open a command window as Administrator, then run the following commands (using the full binPath to your build executable):

```bat
> sc.exe create PresentMonService binPath="C:\...\PresentMonRepoDir\build\Release\PresentMonService.exe"
> sc.exe start PresentMonService
```

When you are finished, stop and remove the service with:

```bat
> sc.exe stop PresentMonService
> sc.exe delete PresentMonService
```

### PresentMon Standalone Console

The standalone console application is `PresentMon-dev-x64.exe`:

```bat
> build\Release\PresentMon-dev-x64.exe
```


## Troubleshooting

- If you are seeing vcpkg errors when updating to a new version of PresentMon (e.g., "error: while checking out baseline from commit...") then try updating your vcpkg checkout.

- Make sure vcpkg is using the same Visual Studio installation as the solution build. If needed, set `VCPKG_VISUAL_STUDIO_PATH` before running vcpkg.


- If you get an error dialog from PresentMon.exe stating "A referral was returned form the server."
  you most likely do not have the certificate that the PresentMon service was signed with installed
  into your trusted root.  Ensure that the trusted test certificate setup completed successfully.  If
  you built the installer on another PC or received it from a trusted third party, you need to
  install the certificate on the target PC as well.

- Add the development user to the Performance Log Users group to run from the IDE, run tests, etc. without launching the IDE as administrator.
