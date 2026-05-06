# ノド・分割幅・表紙基準 — 仕様メモ（AI・保守向け）

このファイルは **`FlickFit-Core.ps1` 内の「見開き分割・ノドGUI・分割幅検証・表紙幅」** を改修するときの索引です。行番号は変わるため **関数名・変数名・grep キーワード** で辿ってください。

## 目的（プロダクト上の意図）

- **1ページとしての見え方**を優先しつつ、フォルダ内で **削りすぎ（過剰トリム）** を避けたい。
- 表紙幅は「同じフォルダで同じくらいの単ページ幅に寄せる」ための **実用的な基準** として採用されている。
- 自動判定が不安な箇所は **`Show-GutterMarginSetGui` でユーザー調整** に逃がす。

## 運用方針（NAS・`.cursor` が見えない場合）

- **Ugreen NAS** など、管理画面に **ドット始まりフォルダを表示する項目がまだない**環境では、`.cursor` 配下が一覧で見えにくいことがある。
- そのため **ルール・索引はこの `docs/` の Markdown に置く**（ファイル名はドットなしで NAS 上でも追いやすい）。
- 将来、Cursor 用の細かいルールをルートに置くなら **`AGENTS.md`**（先頭ドットなし）も候補。`.cursor/rules` と二重にならないよう、**「詳細は本 SPEC に書く」程度に短く**するのがおすすめ。

## Cursor チャットでの入力（AI に文脈を渡す手順）

1. チャット入力欄で **`@`（アットマーク）を入力**する。
2. 続けて **ファイル名の一部**（例: `SPEC` / `ノド` / `FlickFit-Core`）を打つと、ワークスペース内の候補が出る。
3. **一覧から選ぶ**と、そのファイルがコンテキストに入る（複数可: `@ファイルA` `@ファイルB`）。
4. フォルダ単位で渡したいときは `@` のあと **`docs`** などフォルダ名で候補が出れば、フォルダを選ぶ（バージョンにより挙動は多少異なる）。
5. **ノド・分割幅・表紙まわりの改修**では、最低でも **`@docs/SPEC-ノド・分割幅・表紙基準.md`** と **`@FlickFit-Core.ps1`**（または変更箇所が分かっている関数名を本文に書く）を併用すると手戻りが減る。

## 単一ソース・ファイル

| 対象 | ファイル |
|------|----------|
| メインロジック | `FlickFit-Core.ps1`（約1.3万行） |
| モジュール分割 | `Modules\*.ps1`（巻・写真等。ノド本体はメインに集約） |

## 重要な関数（検索の第一候補）

| 関数 | 役割 |
|------|------|
| `Show-GutterMarginSetGui` | ノド＋四辺余白の WinForms。`ValidationSummaryText` で上部に警告文。`ShowApplyThisPageOnlyButton` で「このページのみで採用」。 |
| `Invoke-SplitWidthValidation` | 分割後の左右幅が基準未満などのとき **通常ノドGUI** を開く。キャンセル＝現分割採用。`AllImagePaths` でフォルダ内ナビ。 |
| `Repair-GutterMarginGeometry` | のどと左右トリムの整合（Python 側 `raw_gutter<0` 防止）。 |
| `Repair-GutterVerticalMargins` | 上下トリムの合計クランプ。 |
| `Invoke-PythonCropGuiMargins` | `crop_gui_margins` 呼び出し。 |
| `Get-ProcessableFolderImages` | フォルダ内画像列（自然順）。 |

**grep 例:** `function Show-GutterMarginSetGui` / `function Invoke-SplitWidthValidation`

## フォルダループ内の主な変数

| 名前 | 意味 |
|------|------|
| `$folderCoverWidth` | **見開き分割後の検証・分割時カバー幅** などに使う「表紙由来の基準幅」。処理の途中で更新される。 |
| `$folderTypicalSingleWidth` | **先頭画像を除く最大5枚**から取った幅の中央値。**縦長1ページの `trim_single_safe`** 用 `effectiveCoverWidth` 補正にのみ使用（見開きの+1%検証の主役ではない）。 |
| `$script:FolderGutterCache[$dir]` | フォルダ＋画像サイズに紐づくノド・余白キャッシュ。 |
| `$script:SplitWidthApplyGutterOnlyThisPage` | 「このページのみで採用」時に **キャッシュ更新をスキップ** するフラグ。 |
| `$script:SplitWidthGuiPresetResult` | 分割幅GUI確定後、**再分割**に渡すノド・余白のプリセット。 |
| `$script:SplitWidthNewCoverCandidate` | 基準幅を下げる候補（`set_new_cover` 戻り値経由）。 |
| `$script:OneSidedSplitWidthAutoAdopt` | 以降同様ケースを自動採用。 |
| `$script:SplitWidthLastConfirmedByFolder[$dir]` | 分割幅GUIで **OK したノド・余白**（フォルダキー）。キャッシュと **±3px 以内**なら次回以降は GUI を出さず同設定で再分割（`Test-FlickFitSplitWidthParamsReuse`）。 |

## ユーザー向け操作の対応関係

- **OK（この設定で分割）** → ハッシュテーブルで `GutterX` 等を返し、呼び出し側が Python 分割 or 余白のみ実行。
- **このページのみで採用** → `ApplyOnlyThisSpread` / `guiMarginApplyOnlyThisPage` 経由で **キャッシュ書き換えをスキップ**（複数箇所で `FolderGutterCache` 代入をガード）。
- **分割幅が足りない** → `Invoke-SplitWidthValidation`：**先にノドGUI**（バックアップがあると MessageBox「基準幅採用」は出さず遅延）。キャンセル後に表紙基準を下げるかコンソール確認あり得る。ただし **前回 OK 値と今の `FolderGutterCache` が各数値で±3px以内**かつ完全一致でないときは GUI 省略で `gutter_reselect`（パラメータ `-ReuseConfirmedTolPx` で変更可）。

## 変更するときの指針（よある要望 → 探す場所）

| やりたいこと | 探すキーワード / 場所 |
|--------------|------------------------|
| ノドGUIのボタン配置・文言 | `Show-GutterMarginSetGui` 内 `btnOk` / `btnApplyOne` / `btnRowGap` |
| 左右余白の上限（ノドオフ時） | `txtLeft.Add_Leave` / `leftBarDragging` / `minBand` 12 |
| 分割幅警告の条件 | `Invoke-SplitWidthValidation` 内 `targetMin` / `widthOk` |
| 表紙より狭いときの MessageBox | `Invoke-SplitWidthValidation` 内 `deferNewCoverPrompt` / `canShowMarginGuiEarly` |
| キャッシュを書かない条件 | `SplitWidthApplyGutterOnlyThisPage` / `skipCache` |
| 片側コンテンツの分割後検証 | `Invoke-SplitWidthValidation` 呼び出し（`OneSidedContent`） |
| 通常見開き（B）の分割後検証 | 同じく `Invoke-SplitWidthValidation`（別ブロック） |
| 分割幅GUIの連続省略（±3px） | `Test-FlickFitSplitWidthParamsReuse` / `SplitWidthLastConfirmedByFolder` / `Invoke-SplitWidthValidation -GutterCacheFolderKey` |

## 注意（パース・埋め込み）

- メイン `.ps1` には **埋め込み Python** があり、`Parser::ParseFile` で全体をパースすると **誤検知が大量**に出る。構文確認は **変更箇所の関数単位** または **実行テスト** が現実的。

## 更新ルール

- 挙動を変えたら **このファイルの該当表だけ** 手直しする（長文化しない）。
- 新しい `script:` フラグや関数を増やしたら **1行追加**する。

---
*最終目的: 別の AI / 人間が「分割・ノド・表紙」の話題で入ったとき、まずこのファイルと上記 grep で着地する。*
