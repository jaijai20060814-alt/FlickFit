# 漫画整理ツール モジュール

（FlickFit **v1.0.1** 同梱）

**単一の正（source of truth）**: 入出力・パース・巻/話判定はここを編集する。`FlickFit-Core.ps1` では同名関数を定義しない（Load-Modules 後に上書きしない）。

## 構成

| モジュール | 内容 |
|-----------|------|
| Config.ps1 | 拡張子、WinRAR/Python/BPG パス等の定数、`$script:FolderAutoTimer` 初期化 |
| Utils.ps1 | 入出力（`Write-FlickFitHost` / `Write-FlickFitWarning` / `Write-Step` / `Read-HostWithEsc`）、文字列変換、パース（Confirm-YN, Sanitize-FileName, Parse-RangeInput 等） |
| VolumeContext.ps1 | 巻数・話数判定（Get-VolContext, Get-VolFromParentName, Get-ChapterNumber, Get-RealRoot, Get-LeafFolders） |
| VolumePatternRules.Parse.ps1 | プロジェクト直下 `VolumePatternRules.txt` / `VolumePatternRules.local.txt` のテキスト辞書（追加の ignore・replace） |
| VolumePatternOverrides.Load.ps1 | `VolumePatternOverrides.json` のマージ初期化 |
| PublicMode.ps1 | `PublicMode` / `NgWords` によるログ・出力名の安全化 |
| CoverTrim.Load.ps1 / CoverTrim.ps1 / CoverTrim.Fallback.ps1 | 表紙トリミング（フォールバック切替） |
| CoverTrimPreviewGui.ps1 | 表紙プレビュー GUI |
| FlickFitImageRotate.ps1 | 回転ユーティリティ |
| GutterMarginRotationLayout.ps1 | ノド GUI 回転レイアウト |
| Extract.ps1 | 解凍・EPUB・フォルダ選別 |
| Photos.ps1 | フォト連携 |
| Compression.ps1 | ZIP / RAR / CBZ 出力 |
| Load-Modules.ps1 | 依存順に一括 dot-source（UserConfig マージ・PublicMode 初期化を含む） |

### 巻数テキストルール（公開用の注意）

- **`[ignore]`** は名前に対する**部分一致**で削除します。短すぎる語はタイトルや巻表記まで崩すことがあります。
- **`[replace]`** はファイル**上から順に**すべて適用します（順序で結果が変わります）。
- デバッグ時、PowerShell を **`-Verbose`** で起動すると、前処理で文字列が変わったときだけ `[VolRules] before=` / `after=` が表示されます（本体のコンソール）。

## ロード順（`Load-Modules.ps1` の実際）

1. Config.ps1  
2. VolumePatternRules.Parse.ps1  
3. VolumePatternOverrides.Load.ps1 → `Initialize-FlickFitVolumePatternOverrides`  
4. Utils.ps1（`Write-FlickFitHost` / `Write-FlickFitWarning` / `Write-Step` / `Read-HostWithEsc` 等）  
5. PublicMode.ps1（任意・失敗時は Verbose のみ）  
6. VolumeContext.ps1  
7. CoverTrimPreviewGui.ps1（任意）  
8. FlickFitImageRotate.ps1（任意）  
9. GutterMarginRotationLayout.ps1（任意）  
10. CoverTrim.Load.ps1（CoverTrim / Fallback）  
11. Extract.ps1  
12. Photos.ps1  
13. Compression.ps1  
14. `Modules\UserConfig.json` と直下 `UserConfig.json` の浅いマージ → `Initialize-FlickFitPublicMode`

## 使い方

メインスクリプトの先頭で：

```powershell
$scriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptRoot "Modules\Load-Modules.ps1")
```

## 今後のモジュール候補

- ImageProcessing.ps1（Get-ImageAspect, Renumber-Images, Convert-ToJpg）
- Step1-Extract.ps1 ～ Step7-Cleanup.ps1（各工程を関数化）
