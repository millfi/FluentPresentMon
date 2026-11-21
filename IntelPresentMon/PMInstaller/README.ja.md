# Fluent PresentMon MSIX 配布

Fluent PresentMon は、Windows 11（ビルド 22000 以降）向けの x64 MSIX パッケージとしてのみ配布されます。ビルドおよび署名は [Windows App Development CLI (`winapp`)](https://github.com/microsoft/WinAppCli) を使用して行います。

## 前提条件

- Visual Studio 2026 18.7 以降（Community / Professional / Enterprise）または Visual Studio Build Tools 2026 18.7 以降（C++ によるデスクトップ開発および Windows SDK 10.0.26100 を含む）
- `winapp` CLI:
  ```powershell
  winget install Microsoft.winappcli --source winget
  ```
- x64 リテール版 `Microsoft.VCLibs.Desktop` フレームワーク（Windows SDK / Visual Studio とともにインストールされます）

## ビルドと署名

### 1. ローカル開発 / 自己署名ワークフロー

`Package.appxmanifest` に一致する自己署名開発証明書を生成し、初回のみ管理者権限の PowerShell で信頼登録します:

```powershell
winapp cert generate --manifest IntelPresentMon\PMInstaller\Package.appxmanifest --output build\devcert.pfx
# 初回のみ管理者として実行:
winapp cert install build\devcert.pfx
```

MSIX をビルド、パッケージ化、および署名します（`PresentMon.exe` では `uiAccess=true` が有効になります）:

```powershell
.\Tools\build-installer.ps1 -CertPath build\devcert.pfx
```

主なオプション:
- `-SkipRestore`: 再ビルド時に vcpkg と NuGet の復元をスキップします
- `-SkipBuild`: 再コンパイルせずに既存の `build\Release` および `build\Release\msix-ui` 出力を再パッケージ化します
- `-CertPassword <pwd>`: PFX パスワード（デフォルト: `password`、`winapp cert generate` の既定値と一致）
- `-TimestampUrl <url>`: 本番署名用に RFC 3161 タイムスタンプを付与します
- `-RunNativeTests`: パッケージ化前にネイティブのキャプチャおよびオーバーレイテストを実行します
- `-VisualStudioPath <path>`: 使用する Visual Studio 2026 または Visual Studio Build Tools 2026 のインストール先を明示指定します（省略時は `Windows Store` C++ ターゲットを備えたインストールを優先して自動検出し、その環境の `vcvarsall.bat amd64` 上で `vcpkg install` を実行します）
- `-VcpkgRoot <path>`: `vcpkg.exe` を含むディレクトリを明示指定します（省略時は `VCPKG_ROOT`、選択された Visual Studio 内の `VC\vcpkg`、`PATH` 上の `vcpkg.exe`、他のインストール済み Visual Studio の順で自動解決します）

### 2. 未署名検証ビルド

証明書なしで未署名の Release MSIX をビルドするには（`uiAccess` 無効、未署名パブリッシャー名前空間を使用）:

```powershell
.\Tools\build-installer.ps1 -UnsignedRelease
```

Windows 11 では、未署名パッケージは管理者権限の PowerShell から `Add-AppxPackage -AllowUnsigned` を実行することでローカルテスト用にインストールできます。そのパッケージ ID は署名済みビルドとは意図的に異なります。

## 出力レイアウト

各実行では `build\Release\MSIX\<guid>` 配下に新しいディレクトリが作成され、構造検証が成功した後に `build\Release\MSIX\latest-package.txt` が更新されます。

オフラインインストールには、以下をまとめて配布してください:
- `FluentPresentMon_<version>_x64.msix`
- `Dependencies\x64\`（`Microsoft.WindowsAppRuntime.2` および `Microsoft.VCLibs.140.00.UWPDesktop`）
- `Install.ps1`

`Layout\`、`ResourceInput\`、`resources.xml`、`kernel.manifest`、および `size-report.json` はビルド成果物であり、配布する必要はありません。

## 依存関係とパッケージ内容

- WinUI 3 UI（`ui\PresentMonUI.exe`）は `/p:PresentMonMsix=true` を指定してフレームワーク依存の C++/WinRT バイナリとしてビルドされます（.NET ランタイムは不要です）。
- `Microsoft.WindowsAppRuntime.2` および `Microsoft.VCLibs.140.00.UWPDesktop` は `Dependencies\x64` に外部の共有フレームワークとして配置されます。DirectML や ONNX Runtime はアプリパッケージにはコピーされません。
- ETW プロバイダーマニフェスト登録は意図的に省略されています。PresentMon は組み込みの構造体を使用してフレームおよびアプリケーションタイミングイベントをデコードするため、SCCD や別添の MSI は不要です。
- パッケージをアップグレードする場合は、`Version.props` の `PresentMonFileVersion` をインクリメントしてください。

## インストール、更新、およびアンインストール

管理者権限の **Windows PowerShell 5.1** プロンプトから `Install.ps1` を実行します:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

- パッケージ化された LocalSystem サービス（`FluentPresentMonService`）を登録するため、管理者権限が必要です。
- `Install.ps1` は、既にインストール済みの互換フレームワークを再利用し、不足しているフレームワークを `Dependencies\x64` から展開します。更新時はパッケージ化サービスを停止し、MSIX をインストールした後に `FluentPresentMonService` を起動します。
- パッケージ ID（`Fluent.PresentMon`）、サービス（`FluentPresentMonService`）、パイプ、ETW セッション、共有メモリ、レジストリキー、設定（`Documents\FluentPresentMon`）、およびログ（`%LOCALAPPDATA%\FluentPresentMon`）は、上流の Intel PresentMon から分離されています。
- AppData およびレジストリの書き込み仮想化は無効化されているため、ユーザー設定やキャプチャデータはアンインストール後も保持されます。
- アプリを削除するには、Windows の「設定」を使用するか、`Get-AppxPackage Fluent.PresentMon | Remove-AppxPackage` を実行してください。

## 検証

- すべてのビルドで `Tools\test-msix-package.ps1` が自動実行され、ペイロードファイル、共有フレームワーク宣言、サービス登録、UIAccess 機能、実行エイリアス、およびフレームワークファイルのローカルコピーが含まれていないことが検証されます。
- パッケージをインストールした後、通常ユーザー権限の Windows PowerShell 5.1 プロンプトから `.\Tools\test-msix-installed.ps1` を実行すると、インストール済みサービスとオーバーレイの動作を検証できます。
