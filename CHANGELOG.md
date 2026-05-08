# Changelog

## v1.0.1 - 2026-05-07

### Fixed

- STEP5 のノド/余白 GUI で画像削除を行ったあと、リトライ経路に入り、削除した画像が復元または trim_only フォールバックされることがある問題を修正しました。
- GUI 削除後に対象画像が存在しない場合は、retry / fallback / backup restore を行わず、次の画像へ進むようにしました。
- STEP5 バランス型処理で前回の ERROR 結果が残らないよう、処理冒頭で `$result` を初期化しました。
- PublicMode.ps1 内で PowerShell の自動変数 `$HOME` と衝突する `$home` 変数名を使っていた問題を修正しました。
- STEP5 削除・リトライ調査用の詳細デバッグログを、既定では表示しないようにしました。

## v1.0.0 - 2026-05-06

- 初回公開版
- 画像フォルダ / EPUB 展開後フォルダの整理に対応
- 表紙トリミング、見開き分割、余白処理、CBZ/ZIP/RAR 出力に対応
- PublicMode / NgWords による公開向けログ安全化を追加
- VolumePatternOverrides による固有パターン分離に対応
- ランチャーからの Core 起動を一時 `.cmd` watcher 方式へ変更し、日本語パスと処理完了後のランチャー復帰を安定化
- `Process.Exited` / `System.Threading.Timer` に PowerShell scriptblock を渡さない（`ScriptBlock.GetContextFromTLS` によるホスト異常終了の回避）
- メイン完了検知は WinForms `Timer` の Poll のみ
