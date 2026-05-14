# Changelog

## v1.0.2 - 2026-05-13

### Fixed / Improved

- STEP5 のノド/余白 GUI でセッション内に画像を削除したあと、別の画像で OK したノド・余白の結果が捨てられていた問題を修正（例: 2ページ目で 002 を削除後、003 で確定した設定をそのまま適用）。
- STEP5 の表紙まわりループで、削除・分割後の再開インデックスを古い `$nextIdx` 固定加算ではなく、実際に Python が処理したパス（`$splitPath2` / `ApplyImagePath`）基準で決めるよう改善。リゾルバ失敗時は一覧上のパスから推定し、最後の手段として警告付きで再評価。
- メニュー [4] のど・余白 GUI と PhotosEdit の成功後も、同様に再開位置を安定化。
- `[DeleteDbg]` 系のコンソール行は、`$script:FlickFitDebugStep5Delete = $true` のときのみ出力（通常実行では非表示）。

### Changed

- 巻数判定: 「第1部 カラー版 02 [aKraa]」のようなフォルダ名で、「第1部」の `1` を巻数として拾わないよう改善。
- ノド/余白プレビュー GUI: Ctrl + マウスホイール時の拡大上限を ×8 から ×12 に変更。

### Added

- `tests/Get-VolContext-VolRegression.ps1`: 巻数判定の回帰テストを追加。
- 実行時のバージョン表記をリポジトリ直下 **`VERSION`** を正本とする **`Get-FlickFitVersion`**（`Modules/FlickFitVersion.ps1`）に統一。`FlickFit-Core.ps1` / `FlickFitLauncher.ps1` は `$script:FlickFitVersion` を表示に使用（ファイルが無い・読めない場合は `dev` で起動継続）。

## v1.0.1 - 2026-05-07

### Fixed

- STEP5 のノド/余白 GUI で画像削除を行ったあと、リトライ経路に入り、削除した画像が復元または trim_only フォールバックされることがある問題を修正しました。
- GUI 削除後に対象画像が存在しない場合は、retry / fallback / backup restore を行わず、次の画像へ進むようにしました。
- STEP5 バランス型処理で前回の ERROR 結果が残らないよう、処理冒頭で `$result` を初期化しました。
- PublicMode.ps1 内で PowerShell の自動変数 `$HOME` と衝突する `$home` 変数名を使っていた問題を修正しました。

## v1.0.0 - 2026-05-06

- 初回公開版
- 画像フォルダ / EPUB 展開後フォルダの整理に対応
- 表紙トリミング、見開き分割、余白処理、CBZ/ZIP/RAR 出力に対応
- PublicMode / NgWords による公開向けログ安全化を追加
- VolumePatternOverrides による固有パターン分離に対応
- ランチャーからの Core 起動を一時 `.cmd` watcher 方式へ変更し、日本語パスと処理完了後のランチャー復帰を安定化
- `Process.Exited` / `System.Threading.Timer` に PowerShell scriptblock を渡さない（`ScriptBlock.GetContextFromTLS` によるホスト異常終了の回避）
- メイン完了検知は WinForms `Timer` の Poll のみ