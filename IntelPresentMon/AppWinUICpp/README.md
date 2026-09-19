# PresentMon native WinUI interface

The capture application starts this C++/WinRT WinUI 3 control panel from
`build\Debug\ui\PresentMonUI.exe`. Launch `build\Debug\PresentMon.exe` for a
connected capture session, or start the UI executable alone to inspect layout.
See [`BUILDING.md`](../../BUILDING.md) for the complete build, service, and
installer workflow.

`PresentMonUI.vcxproj` targets x64 and uses C++/WinRT, Windows App SDK 2.0.1,
Windows C++/WinRT 2.0.240405.15, and Windows SDK BuildTools 10.0.26100.4948.
The native package references require Visual Studio 2026 18.7 or newer with the
v145 toolset; 18.9 is the validated toolchain. Developer builds create an unpackaged,
self-contained Windows App SDK deployment. The complete development `ui` directory must
remain beside `PresentMon.exe`, and it does not deploy or require the .NET
runtime.

The installer builds with `PresentMonMsix=true` into `build\Release\msix-ui`
using separate intermediates. That build is framework-dependent and runs from
the MSIX with Microsoft's shared Windows App SDK and VCLibs frameworks. See
[MSIX deployment](../PMInstaller/README.md). It does not copy the framework's
WinUI, DirectML or ONNX Runtime binaries into the app package.

## Build and test

```powershell
.\Tools\build-ui-cpp.ps1 -Configuration Debug -RunTests
```

The core checks are built as
`build\Debug\ui-tests\PresentMonUI.Core.Tests.exe`. `-RunTests` runs the native
core and protocol checks, backdrop smoke, shell smoke, and installer-harvest
validator checks. `build-capture-app.ps1 -RunNativeTests` additionally runs the
real overlay host after building the staged kernel and API. It uses a generated
child-service session, isolated UI data and logs, and a PresentBench target;
the Basic overlay must remain visible for five seconds. The project also
supports `-RestoreOnly` for bootstrap and `-SkipRestore` for repeat local
builds.

## Structure

- `MainWindow.xaml` and `MainWindow.xaml.cpp`: adaptive navigation, process
  search, presets, capture controls, theme selection, and native file pickers.
- `Views`: graph and readout editing, searchable metrics, statistics, devices,
  colors, axes, labels, widget ordering, settings, and global shortcuts.
- `Services/AppSession`: session lifetime, native events, debounced persistence,
  target selection, capture timers, and coordination of UI changes.
- `Services/WindowsServices`: native window and process discovery plus PDH-based
  automatic GPU targeting.
- `Core`: JSON models and migrations, specification construction, atomic
  persistence, and target-selection logic.
- `Interop`: the cereal binary named-pipe client shared with the native kernel.
- `Assets/Presets`: the four built-in overlay loadouts.
- `Assets/BlockLists/TargetBlockList.txt`: the default capture target filter.

The kernel owns overlay rendering, telemetry, frame capture, and global hotkeys.
The UI uses the existing cereal binary protocol. The kernel stages presets and
the blocklist beside its executable for runtime use and installer packaging.

## Automatic targeting

While enabled, automatic targeting selects the application with the largest sum
of raw per-frame GPU Busy during each five-second interval. The first interval
after enabling lasts 200 ms. Totals reset after every selection interval; equal
positive totals are ordered by PID. A constant positive GPU Busy value also
contributes, without requiring ten samples or variation.

Visible-window and optional target-blocklist filters determine candidates.
Candidates are refreshed about every 250 ms and raw frame queues are consumed
about every 25 ms away from the UI thread. Polling and IPC can delay selection
slightly beyond the interval deadline. Tracking starts before the initial
200 ms interval. Removed candidates release their trackers, and disabling
automatic targeting releases the complete probe session. Invalid, negative,
and zero GPU Busy values do not contribute to the total.

If no candidate qualifies, the current selection and an active recording remain
unchanged. Process exit still clears the target. Enabling automatic targeting
clears the existing selection; disabling it retains the current target and
releases the probe session. Manual selections can be replaced by a later scan.
Any target change uses the usual capture-stop path. A toggle, manual selection,
or settings change during a scan invalidates that scan result.

## Compatibility and deployment

Existing `preferences.json` and `Loadouts/custom-auto.json` formats and their
supported migrations are preserved. Unknown JSON fields survive round trips.
Writes retain the prior valid backup; a corrupt original is saved for recovery
before replacement. Built-in presets remain read-only, and opening the loadout
editor selects the custom preset. ETL recording remains disabled. Theme choice
applies to the current UI session.

Development runs with `--files-working` use the working directory for settings
and captures. The UI displays the capture directory selected by the native
kernel. Launching the UI directly provides disconnected layout inspection;
capture and editing controls require a connected kernel and available service.
A normal kernel launch uses the installed service, while `--svc-as-child`
launches a staged child service for development or isolated smoke testing.

The title bar uses a Grid, icon, caption, and `Window.SetTitleBar`. The native
backdrop smoke test covers theme changes, minimize and restore, backdrop
replacement, and close behavior on a desktop with acrylic support.

## UI crash diagnostics

UI actions are written synchronously as JSON Lines to
`%LOCALAPPDATA%\FluentPresentMon\logs\PresentMonUI-actions-<pid>-<session>.jsonl`.
The `--p2c-log-folder` override and isolated `--data-directory` runs use their
selected log directory. This does not require ETW provider registration.
The existing `PresentMonUI.log` continues to contain error and notification text.

Each action record includes UTC time, a monotonically increasing sequence,
process/thread IDs, and source file/function/line. Records cover menu state,
page navigation, clicks on identified controls, numeric commits with old/new
values, toggles, choices, colors, and common commands. Free-form text controls
record their ID and text length rather than their contents. Numeric pending
input is limited to 128 characters. This is an application event trail, not
a recording of all keyboard input or of other applications.

Exception records include the operation, HRESULT, message and the reporting
handler's stack as module paths and relative addresses. The handler stack is
not the original throw stack; retain the matching EXE/PDB and a Windows crash
dump when the original throw site is needed. The session header identifies the
executable, compilation time and loaded XAML runtime. Files are separate for
each process/session so another running instance cannot interleave its events.
Each file rotates at 2 MiB and retains one `.jsonl.previous` segment. Older
sessions remain available in the log directory.

For investigation, collect the session JSONL and its `.previous` file together
with `PresentMonUI.log` and Windows Application Error/Windows Error Reporting
events. Sort by `sequence` within a session and correlate `utc` and `pid` with
the Windows crash record. `navigation.request`, `number.commit`,
`number.change`, and `navigation.complete` describe pending edits made while
leaving a page. The shell regression test verifies this sequence, preservation
of a focused pending Time scale edit, and rejection of a retired page's events.
