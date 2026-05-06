# FlickFit

**バージョン 1.0.0**（2026-05-06・初回公開版）  
変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照してください。

**FlickFit** は、漫画画像フォルダをスマホやサーバー向けビューアで読みやすくするための Windows 用画像前処理ツールです。

見開き分割・余白調整・表紙まわりの自動処理を行い、CBZ / ZIP / RAR 形式で出力します。

主な想定: **Kavita** / **Komga** などの漫画ビューア向け。

---

## 主な機能

- 作品フォルダ内の画像整理
- 表紙候補の自動判定と確認
- 見開き画像のノド位置調整・分割
- 余白トリミング
- CBZ / ZIP / RAR 出力
- ランチャー GUI
- PublicMode / NgWords による公開向けログ安全化
- STEP7 の作業フォルダ削除・解凍元アーカイブ移動設定
- 日本語パス対応

---

## 必要な環境

外部ツールは、必須のものと任意のものに分かれます。

### 最低限これだけで動く

- **OS**: Windows 10 / 11
- **PowerShell**: PowerShell 7（pwsh）推奨  
  ※ 無い場合は Windows PowerShell 5.1 でもランチャーは起動できます。
- **Python**: 3.x
- **Python ライブラリ**
  - Pillow
  - OpenCV
  - NumPy

インストール例:

```powershell
pip install pillow opencv-python numpy
````

未導入時は、ランチャーやメイン処理の環境チェックで案内されます。

### あれば便利

* **WinRAR**
  RAR 形式で出力する場合のみ必要です。
  CBZ / ZIP だけなら WinRAR は不要です。

### 無くてもOK

* **WinRAR 未インストール**
  ランチャーは警告を出しますが、CBZ / ZIP 出力なら処理できます。
  RAR 出力を選んだ場合のみ、WinRAR が無いと作成できません。

---

## 使い方（3ステップ）

### 1. ZIP を展開する

`FlickFit_v1.0.0.zip` を好きな場所に展開します。

### 2. 起動する

展開したフォルダ内の次をダブルクリックします。

```text
FlickFit.bat
```

正式な起動方法は `FlickFit.bat` です。

環境によっては、起動時に一瞬コマンド画面が表示されることがあります。
これは BAT 経由の制約によるもので、通常は問題ありません。

### 3. 作品フォルダを選んで実行する

ランチャーで作品フォルダを選択し、`実行` を押します。

メイン処理は別の PowerShell ウィンドウで動作します。
詳細ログや確認メッセージは、その PowerShell ウィンドウで確認してください。

まずは 1 つの作品フォルダで試すことをおすすめします。

---

## 出力の場所

既定では、作品フォルダ直下の `_output` に出力します。

```text
作品フォルダ\
└─ _output\
```

出力先フォルダ名は `UserConfig.json` で変更できます。

---

## 設定ファイル

設定は次の順で参照されます。

1. ルート直下の `UserConfig.json`
2. 無い場合は `Modules\UserConfig.json`

例として、`Modules\UserConfig.example.json` があります。

必要に応じてコピーして、ルート直下に `UserConfig.json` として置いてください。

```text
Modules\UserConfig.example.json
↓ コピー
UserConfig.json
```

ランチャーの詳細オプションから保存した設定は、ルート直下の `UserConfig.json` に保存されます。

---

## CompressionFormat（圧縮出力形式）

メイン処理の STEP6 で書き出すアーカイブ形式です。

`UserConfig.json` では次のように指定できます。

```json
{
  "CompressionFormat": "CBZ"
}
```

指定できる値:

* `CBZ`（既定）
* `ZIP`
* `RAR`

未定義・空・上記以外の値は `CBZ` として扱います。

### CBZ / ZIP

WinRAR が無くても、PowerShell の ZIP 作成機能で作成できます。

### RAR

RAR 出力には WinRAR が必要です。
WinRAR が見つからない場合、ランチャーの詳細オプションでは警告が表示されます。

選択自体はできますが、実行時には作成に失敗します。

WinRAR の場所を明示したい場合は、`UserConfig.json` の `WinRAR` キーに `WinRAR.exe` のフルパスを指定できます。

```json
{
  "WinRAR": "C:\\Program Files\\WinRAR\\WinRAR.exe"
}
```

### ランチャーから変更する

ランチャーの `詳細オプション...` から、`作成する圧縮形式` を選択できます。

選択後、`OK` を押すとルート直下の `UserConfig.json` に保存されます。

---

## PublicMode / NgWords

ログやスクリーンショットを第三者に見せる前に、コンソール表示のフルパスや伏せたい語を隠すための機能です。

`UserConfig.json` に次のように書きます。

```json
{
  "PublicMode": true,
  "NgWords": [
    "伏せたい文字列"
  ]
}
```

### PublicMode

`PublicMode: true` にすると、表示用ログに対してパスのマスク処理がかかります。

内部判定や実ファイルパスの処理には使わず、表示直前の安全化に使います。

### NgWords

`NgWords` は文字列の配列です。
部分一致でログ表示から伏せます。大文字小文字は無視します。

圧縮出力名のベース名安全化にも使われます。

### マスク対象

主に次の表示がマスク対象です。

* `Write-FlickFitHost`
* `Write-FlickFitWarning`
* `Read-HostWithEsc` のプロンプト表示

### 限界

次の経路はマスクされずに出ることがあります。

* `throw` のメッセージ
* 外部プロセスの直接出力
* Python の標準出力
* デバッグ用に直接出している行

公開前には、実ログでも確認してください。

---

## 生画像（JPG / PNG / AVIF 等）について

作業フォルダ直下などに置いた元の画像ファイルは、自動では削除しません。

アーカイブ解凍由来や変換パイプライン側は別処理ですが、共有ログ用マスクとは別に、元データの消失リスクを抑える方針です。

処理前に、必要に応じて元データのバックアップを取ってください。

---

## VolumePatternOverrides.json について

巻数・表紙・ファイル名整理に使う追加パターンを、必要に応じて外部 JSON で指定できます。

基本の流れ:

```text
VolumePatternOverrides.example.json
↓ コピー
VolumePatternOverrides.json
```

`VolumePatternOverrides.json` は任意ファイルです。
無い場合でも、内蔵の汎用パターンで動作します。

追加できる主な項目:

* `source_prefixes.chapter`
* `source_prefixes.volume`
* `sanitize_source_noise_patterns`
* `cover_folder_name_tokens_extra`

固有のフォルダ名・プレフィックス等は、本体ではなくここに分離する想定です。

---

## VolumePatternRules.txt について

`VolumePatternRules.txt` は、巻数・話数・表紙候補などの判定を補助するためのルールファイルです。

通常はそのままで問題ありません。

個人用にルールを足したい場合は、公開配布物ではなく自分の環境側で管理してください。
個人用ルールや実行履歴が混ざるファイルは、配布 ZIP に含めないことを推奨します。

---

## ランチャーの補足

FlickFit は、ランチャーからメイン処理を別 PowerShell ウィンドウで起動します。

処理が終わったあと、メイン処理側の PowerShell ウィンドウで Enter を押すと、ランチャーに戻って次の作品を選べます。

ランチャーからの起動では、日本語パスを扱うため、一時 `.cmd` を UTF-8 / `chcp 65001` で生成してメイン処理を起動しています。

完了検知は WinForms Timer による Poll で行います。
PowerShell の `Process.Exited` や `System.Threading.Timer` の ScriptBlock callback は、PowerShell 実行コンテキスト外で動きクラッシュする可能性があるため使用していません。

---

## よくある状況

| 状況             | 対処                                                 |
| -------------- | -------------------------------------------------- |
| Python が見つからない | python.org からインストールするか、`py` を PATH に通してください        |
| Python パッケージ不足 | `pip install pillow opencv-python numpy` を実行してください |
| WinRAR が見つからない | CBZ / ZIP なら不要です。RAR 出力時のみ WinRAR を入れてください         |
| 途中で止まった        | `_process_log.json` がある場合、再開できることがあります             |
| GUI が出る        | 分割や余白の確認が必要なケースです                                  |
| 初回起動が少し遅い      | Python / 設定 / モジュール確認で数秒かかることがあります                 |
| ランチャーが戻らない     | `launcher_trace.log` がある場合は、内容を確認してください            |

---

## ファイル構成

```text
FlickFit.bat              ← 起動用
FlickFitLauncher.ps1      ← ランチャー
FlickFit-Core.ps1         ← メイン処理
Modules\                  ← 共通処理・設定
docs\                     ← 保守向け資料
CHANGELOG.md              ← 変更履歴
README.md                 ← このファイル
VERSION                   ← バージョン表記
VolumePatternRules.txt    ← 巻数・パターン補助ルール
VolumePatternOverrides.example.json ← 追加パターン用テンプレート
```

---

## docs について

`docs\` には、保守や修正時に参照するためのメモを置いています。

公開配布版では、開発途中メモではなく、保守向けに整理した資料のみを同梱しています。

主な内容:

* `MODULE-LAYOUT.md`
* `SPEC-ノド・分割幅・表紙基準.md`

---

## ライセンス

FlickFit は GNU General Public License v3.0 のもとで公開されています。
詳細は [LICENSE](LICENSE) を参照してください。

Copyright (c) 2026 jaijai20060814

---

## 免責

入力データのバックアップは自己責任で行ってください。

本ツールの使用により発生したデータ損失・環境差による不具合について、作者は責任を負いません。
