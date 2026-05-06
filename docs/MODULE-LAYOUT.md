# モジュール構成（配布・保守用）

機能追加は行わず、**同梱ファイルの役割**だけを固定するメモです。

## 起動の流れ

1. `FlickFit-Core.ps1`（メイン）
2. `Modules\Load-Modules.ps1` が存在すれば dot-source（推奨）
3. 無い場合はメイン内のフォールバックで `Config` / `Utils` / `VolumeContext` 等を順に読む

## `Modules\` 一覧

| ファイル | 役割 |
|----------|------|
| `Load-Modules.ps1` | 依存順に各 `.ps1` と `UserConfig.json` を読み込む |
| `Config.ps1` | 拡張子・正規表現など共通定数 |
| `Utils.ps1` | `Read-HostWithEsc`、ファイル名サニタイズ、範囲パース等 |
| `VolumeContext.ps1` | 巻・話数・葉フォルダ列挙 |
| `CoverTrimPreviewGui.ps1` | 表紙プレビュー WinForms |
| `CoverTrim.ps1` | 表紙トリム採点・確認（正） |
| `CoverTrim.Fallback.ps1` | `CoverTrim.ps1` がパースできない環境向けの同一ロジック（表記最小） |
| `CoverTrim.Load.ps1` | 上記2つのどちらかを選んで dot-source |
| `Extract.ps1` | 解凍フロー |
| `Photos.ps1` | フォト連携 |
| `Compression.ps1` | 圧縮 |
| `UserConfig.json` | ユーザー既定（任意） |

## Python / WinRAR が PATH に無いとき

- **環境変数**（ユーザーまたはシステム）: `FLICKFIT_PYTHON` または `PYTHON` に `python.exe` の**フルパス**（`%LOCALAPPDATA%\...` 可）。
- **`UserConfig.json`**: `"PythonExe": "C:\\...\\python.exe"`（引用符・バックスラッシュ二重は JSON どおり）。
- **自動検出の順序**: 上記 → `py -3` で解決した実体 → レジストリ `Python\PythonCore` → PATH の `python` / `python3` → よくあるフォルダ。
- **WinRAR**: 標準インストール先に加え、レジストリ `HKLM/HKCU\SOFTWARE\WinRAR` と PATH の `WinRAR.exe` を試す。`UserConfig.json` の `"WinRAR"` でフルパス指定可。

## 配布するとき

- メイン＋ `Modules\` フォルダごと同梱する（`docs\` は実行に不要）。
- Python / WinRAR / 画像依存は従来どおり利用者環境に依存。
