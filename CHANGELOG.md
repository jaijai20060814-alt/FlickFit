# Changelog

## v1.0.0 - 2026-05-06

- 初回公開版
- 画像フォルダ / EPUB 展開後フォルダの整理に対応
- 表紙トリミング、見開き分割、余白処理、CBZ/ZIP/RAR 出力に対応
- PublicMode / NgWords による公開向けログ安全化を追加
- VolumePatternOverrides による固有パターン分離に対応
- ランチャーからの Core 起動を一時 `.cmd` watcher 方式へ変更し、日本語パスと処理完了後のランチャー復帰を安定化
- `Process.Exited` / `System.Threading.Timer` に PowerShell scriptblock を渡さない（`ScriptBlock.GetContextFromTLS` によるホスト異常終了の回避）
- メイン完了検知は WinForms `Timer` の Poll のみ
