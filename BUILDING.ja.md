# PresentMon のビルド

## ビルドツールの依存関係のインストール

- Visual Studio 2026 18.7 以降（Community / Professional / Enterprise）または Visual Studio Build Tools 2026 18.7 以降（C++ によるデスクトップ開発、Windows SDK 10.0.26100、および C++ テストツールを含む）。ネイティブ WinUI パッケージの参照にはこのツールチェーン（`Windows Store` C++ MSBuild ターゲットを含む）が必要です。現在検証済みのインストール構成は Visual Studio 2026 18.9 以降です。

- Windows App SDK のビルド前提条件は、ネイティブプロジェクトの PackageReference エントリを通じて復元されます。

- [vcpkg](https://github.com/microsoft/vcpkg)

- [CMake](https://cmake.org)

- [winapp CLI](https://github.com/microsoft/WinAppCli)（`winget install Microsoft.winappcli --source winget`）および x64 リテール版 VCLibs デスクトップフレームワーク（MSIX パッケージング用）。

注意: PresentData ライブラリまたは PresentMon コンソールアプリケーションのみをビルドする場合は、
Visual Studio のみで十分です。その他のビルドおよびソース依存関係に関する手順は無視し、
`PresentData\PresentData.vcxproj` または `PresentMon\ConsoleApplication.sln` をビルドしてください。

## ソース依存関係のインストール

1. リポジトリのブートストラップスクリプトを実行します:

    ```powershell
    > cd PresentMonRepoDir
    > .\bootstrap.ps1
    ```

    ブートストラップスクリプトは以下を行います:

    - 固定された補助テストデータのプル。
    - パッケージ化されていないネイティブ WinUI 3 アプリケーション用の NuGet パッケージの復元。

    ETL リグレッションデータが不要な場合は、`-SkipAuxiliaryData` を指定してください。リグレッションフィクスチャの詳細については、[補助テストデータ](Tests/auxdata.md) を参照してください。

    キャプチャアプリケーションは WinUI 3 を使用しています。同梱のプリセットとブロックリストは `IntelPresentMon\AppWinUICpp\Assets` にあり、ネイティブカーネルはこれらのアセットを実行ファイルと共にステージングします。

2. 信頼済みテスト証明書を作成してインストールします。これは、デフォルトの署名付き Release ビルドで必要です。後述のオプトイン方式の未署名 Release ワークフローでは証明書は不要です。署名付きワークフローの場合は、コマンドシェルを管理者として開き、以下を実行してください:

    ```bat
    > makecert -r -pe -n "CN=Test Certificate - For Internal Use Only" -ss PrivateCertStore testcert.cer
    > certutil -addstore root testcert.cer
    ```

## PresentMon のビルド

MSI をビルドせずに完全なローカルキャプチャアプリケーションを作成するには、以下を実行してください:

```powershell
> .\Tools\build-capture-app.ps1 -Configuration Debug -RunNativeTests
```

これにより、Visual Studio 2026（通常版 IDE または Visual Studio Build Tools 2026 の両方に対応）が検出され、`vcpkg` は `-VcpkgRoot` / `VCPKG_ROOT`、選択された Visual Studio 内の `VC\vcpkg`、`PATH` 上の `vcpkg.exe`、他のインストール済み Visual Studio 内の `VC\vcpkg` の順で自動解決されます（Build Tools 単体に `vcpkg` が同梱されていない場合でも利用できます）。ネイティブ依存関係の復元時には、`build-capture-app.ps1` が選択された Visual Studio の開発者環境（`VC\Auxiliary\Build\vcvarsall.bat amd64`）を初期化したうえで `vcpkg install` を実行するため、通常版と Build Tools が共存する環境でも選択したインスタンスで確実に復元できます。その後、ネイティブ WinUI パッケージ参照を復元し、WinUI アプリケーション、キャプチャカーネル、サービス、およびミドルウェアをビルドして、ネイティブユニットテストをビルドおよび実行します。依存関係のビルドファイルは `build\vcpkg-cache` および `vcpkg_installed` に保存されます。また、vcpkg は標準のユーザーレジストリとバイナリキャッシュを使用する場合があります。以降のビルドでは `-SkipRestore` を使用してください。`-VisualStudioPath`、`-VcpkgRoot`、および `-PlatformToolset` で、明示的なツールインストールを選択できます。ネイティブ UI には、Visual Studio 2026 の v145 ツールセットが必要です。このスクリプトでグローバルな vcpkg 統合を行う必要はありません。

`-RunNativeTests` は `PresentMonAPI2Tests` もビルドし、
`UiProcessGuardTests` クラスと `RealtimeTrackProcessTest` を実行します。UI ガードは、
最小化された既存 UI のフォアグラウンド化、既存 UI の置換、および
対応する並行起動ケースを検証します。リアルタイムテストには、
ステージング済みサービスと PresentBench フレームソースが必要です。当該プロジェクトにおけるより広範なサービスおよび API
統合シナリオは、キャプチャヘルパーでは選択されません。
その後、ネイティブオーバーレイのスモークホストをビルドして実行します。このホストは
PresentBench と、生成された control-pipe、shared-memory、ETW、UI-mutex、log、および UI-data 名を持つステージング済みの `--svc-as-child` カーネルを起動します。Basic
プリセットをプッシュし、installed-service の状態やユーザー設定を変更することなく、
5 秒間、カーネル所有の可視オーバーレイを必要とします。

証明書のセットアップや署名を行わない最適化済みのローカル Release ビルドを行うには、明示的に指定してください：

```powershell
> .\Tools\build-capture-app.ps1 -Configuration Release -UnsignedRelease
```

`-UnsignedRelease` は `-Configuration Release` と併用した場合にのみ有効です。これは `/p:UnsignedRelease=true` をネイティブ MSBuild に渡し、カーネルの署名ステップをスキップして、マニフェストを `uiAccess=false` に設定します。Release の最適化と `NDEBUG` は引き続き有効です。デフォルトの Release ワークフローでは署名と `uiAccess=true` が維持されるため、このスイッチを省略してもその動作が保持されます。このスイッチは、証明書の作成や信頼、MSI のインストール、または Windows のセキュリティ設定の変更を行うものではありません。Release アプリケーションまたはソリューションのビルドで MSBuild を直接呼び出す際に適用する場合は、`/p:UnsignedRelease=true` を渡してください。

`winapp` CLI を使用して署名済み Release MSIX をビルドするには、以下を実行してください：

```powershell
> winapp cert generate --manifest IntelPresentMon\PMInstaller\Package.appxmanifest --output build\devcert.pfx
> winapp cert install build\devcert.pfx   # 初回のみ管理者権限で実行
> .\Tools\build-installer.ps1 -CertPath build\devcert.pfx
```

証明書のセットアップを行わずに、ローカルで署名なしの Release MSIX をビルドして検証するには、以下を実行してください：

```powershell
> .\Tools\build-installer.ps1 -UnsignedRelease
```

このヘルパーは、キャプチャアプリケーション、コンソール、および SDK ローダーをビルドし、その後、フレームワーク依存の UI をビルドして `winapp` CLI で MSIX を作成・検証します。`build\Release\MSIX\latest-package.txt` は、直近で正常にビルドされたパッケージを指します。リストア後には `-SkipRestore`、既存ビルドの再パッケージのみ行う場合は `-SkipBuild`、キャプチャテストには `-RunNativeTests` を使用してください。Windows 11 では、署名なしパッケージは Windows の署名なしパブリッシャー名前空間を使用し、管理者権限の PowerShell から `Add-AppxPackage -AllowUnsigned` を実行することでローカルテスト用にインストールできます。そのパッケージ ID は、意図的に署名済みビルドとは異なるものになっています。署名、オフラインインストール、およびサイズ計算については、[MSIX 配布](IntelPresentMon/PMInstaller/README.ja.md) を参照してください。

インストーラーは、他の MSIX アプリと共有されている Microsoft 署名済みの Windows App SDK および VCLibs フレームワークパッケージを使用します。DirectML と ONNX Runtime は PresentMon パッケージには含まれず、Microsoft の標準フレームワークに残ります。`Dependencies\x64` には、オフラインインストール用のオリジナルの署名済み依存関係が用意されています。

ネイティブソリューションプロジェクトを直接ビルドする場合は、`/p:PlatformToolset=v145` を指定し、vcpkg MSBuild 統合を設定してください。`Reflector` はチェックイン済みのリフレクションヘッダー用のネイティブリフレッシュツールです。MSIX 配布のビルドには `Tools\build-installer.ps1` を使用してください。

まず `bootstrap.ps1` を使用してネイティブ WinUI プロジェクトを復元してください。通常の UI ビルドは、`build\Debug\ui` または `build\Release\ui` 配下でパッケージ化されていない自己完結型のままとなります。開発用の完全な `ui` ディレクトリは、`PresentMon.exe` の隣に配置しておく必要があります。MSIX ビルドでは `/p:PresentMonMsix=true` を使用し、個別の中間ファイルと `build\Release\msix-ui` を利用します。これらのバイナリにはパッケージ登録と宣言済みのフレームワークが必要です。どちらのデプロイにおいても .NET は不要です。オーバーレイシェーダー、プリセット、およびブロックリストは `KernelProcess` によってステージングされます。

UI のみを反復的にビルドするには：

```powershell
> .\Tools\build-ui-cpp.ps1 -Configuration Debug
```

`build-ui-cpp.ps1` に `-RunTests` を渡すと、ネイティブコアおよびプロトコルチェック、バックドロップ・スモーク、およびシェル・スモークが実行されます。`KernelProcess.vcxproj` を直接ビルドする場合、`/p:SkipNativeGuiBuild=true` を指定すると WinUI ビルドの依存関係がスキップされます。これは、UI 出力が既にステージングされている場合や、ヘッドレスコマンドをテストする場合にのみ使用してください。`Release-EDSS` は Release 版 WinUI ペイロードを使用します。

## PresentMon の実行

### Intel PresentMon

`PresentMon.exe` は、ネイティブキャプチャカーネルと WinUI 3 コントロールパネルである `ui\PresentMonUI.exe` を起動します。これら 2 つのプロセスは既存の名前付きパイプアクションプロトコルを使用し、カーネルが引き続きキャプチャ、オーバーレイレンダリング、およびグローバルホットキーを管理します。

デバッグビルドの場合、最も簡単な IDE ワークフローは、`Client/KernelProcess` をスタートアッププロジェクトに設定し、サービスを子プロセスとして実行した状態で `PresentMon.exe` を起動することです：

```bat
> --svc-as-child --files-working --log-level verbose --middleware-dll-path .\PresentMonAPI2.dll --log-middleware-copy
```

PowerShell からは、以下のコマンドで開発用ペイロード全体を実行します：

```powershell
> Push-Location build\Debug
> .\PresentMon.exe --svc-as-child --files-working --middleware-dll-path .\PresentMonAPI2.dll
> Pop-Location
```

キャプチャを行わずに UI レイアウトを確認する場合は、`build\Debug\ui\PresentMonUI.exe` を直接実行してください。キャプチャおよびオーバーレイコントロールを使用するには、`PresentMon.exe` 経由で起動する必要があります。通常の起動ではインストール済みのサービスが使用されますが、`--svc-as-child` を使用した開発用起動では、ステージングされた子サービスが使用され、親サービスで終了します。通常の起動でフレームをキャプチャできない場合は、再試行する前にインストール済みの PresentMon サービスを確認してください。無関係なサービスやテストプロセスを終了させないでください。

`uiAccess=true` が設定されたデフォルトの署名済みリリースビルドの場合、リリース出力ペイロード全体を「Program Files」や「System32」などのセキュアディレクトリに移動するか、ローカル開発用にセキュアディレクトリのチェックを無効にしてください。通常、これらのビルドを IDE から実行することはできません。オプトイン形式の未署名リリースビルドでは `uiAccess=false` が使用され、前述の開発用コマンドを用いて `build\Release` から起動できます。このビルドでは UIAccess 権限は要求されません。署名済みリリースの検証には、インストーラーを使用する方が簡単な場合が多いです：

```powershell
> .\Tools\build-installer.ps1 -CertPath build\devcert.pfx
```

### PresentMon サービス

サービスを開始するには、コマンドウィンドウを管理者として開き、以下のコマンドを実行してください（ビルド実行ファイルへの完全な binPath を指定してください）：

```bat
> sc.exe create PresentMonService binPath="C:\...\PresentMonRepoDir\build\Release\PresentMonService.exe"
> sc.exe start PresentMonService
```

完了したら、以下のコマンドでサービスを停止し、削除してください：

```bat
> sc.exe stop PresentMonService
> sc.exe delete PresentMonService
```

### PresentMon スタンドアロン コンソール

スタンドアロン コンソール アプリケーションは `PresentMon-dev-x64.exe` です：

```bat
> build\Release\PresentMon-dev-x64.exe
```


## トラブルシューティング

- PresentMon の新バージョンに更新する際に vcpkg エラー（例：「error: while checking out baseline from commit...」）が発生する場合は、vcpkg のチェックアウトを更新してみてください。

- vcpkg がソリューションのビルドと同じ Visual Studio インストールを使用していることを確認してください。必要に応じて、vcpkg を実行する前に `VCPKG_VISUAL_STUDIO_PATH` を設定してください。


- PresentMon.exe から「A referral was returned form the server.」というエラーダイアログが表示された場合、
  PresentMon サービスの署名に使用された証明書が信頼済みルートにインストールされていない
  可能性が高いです。信頼済みテスト証明書のセットアップが正常に完了していることを確認してください。
  インストーラーを別の PC でビルドした場合や、信頼できる第三者から入手した場合は、
  対象の PC にも証明書をインストールする必要があります。

- IDE を管理者として起動せずに IDE からの実行やテストの実行などを行うには、開発ユーザーを Performance Log Users グループに追加してください。
