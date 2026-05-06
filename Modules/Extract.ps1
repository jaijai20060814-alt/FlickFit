#Requires -Version 5.1
<#
.SYNOPSIS
    FlickFit - STEP 1: 解凍処理モジュール
.DESCRIPTION
    圧縮ファイルの解凍、ネスト解凍、EPUB処理、フォルダ精査を行う
#>

function Invoke-FlickFitExtract {
    param(
        [string]$WorkDir,
        [string[]]$ArchiveExtensions,
        [string[]]$ImageExtensions,
        [string[]]$ConvertExtensions = @('.tif', '.tiff', '.png', '.bpg', '.jxl'),
        [string]$WinRAR,
        [string]$PythonExe,
        [bool]$DryRun,
        [bool]$RunPhaseA,
        [ref]$CancelRequested
    )
    $targetRoots = [System.Collections.Generic.List[string]]::new()
    $unpackRoot = $null
    $epubFolderVolMap   = @{}
    $epubCoverMap       = @{}
    $epubMainFolderMap  = @{}
    $epubTitleMap       = @{}   # フォルダ名 -> OPFから取得したタイトル
    $epubCreatorMap     = @{}   # フォルダ名 -> OPFから取得した作者
    $epubSpineImageMap  = @{}   # フォルダ名 -> spine順画像パスリスト
    # EpubMetadata.py のパス（このスクリプトと同じ Modules フォルダ）
    $epubMetadataPy = Join-Path $PSScriptRoot 'EpubMetadata.py'
    $selectedExistingFolders = @()
    $selectedArchives = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $subfolderArchivesToProcess = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    if ($CancelRequested.Value) { throw "中断: 処理がキャンセルされました" }
    Write-Step "STEP 1: 解凍"

    # フォルダ名に [ ] 等を含む場合、-Path 既定はワイルドカード扱いになる → -LiteralPath
    if (-not (Test-Path -LiteralPath $WorkDir)) { throw "作業ディレクトリが存在しません: $WorkDir" }
    Push-Location -LiteralPath $WorkDir
    try {
        $localDirs = @(Get-ChildItem -LiteralPath . -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^_unpacked$' } | Sort-Object { [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(10,'0') }) })
        if ($localDirs.Count -gt 0) {
            Write-FlickFitHost "  フォルダ一覧 ($($localDirs.Count) 件):" -ForegroundColor Cyan
            $lines = @($localDirs | ForEach-Object { "    [D] $($_.Name)" })
            $n = $lines.Count; $mid = [Math]::Ceiling($n / 2); $colWidth = 48
            for ($i = 0; $i -lt $mid; $i++) {
                $left = $lines[$i].PadRight($colWidth)
                $right = if ($i + $mid -lt $n) { $lines[$i + $mid] } else { "" }
                if ($right) { Write-FlickFitHost ($left + "  " + $right) -ForegroundColor Gray } else { Write-FlickFitHost $left -ForegroundColor Gray }
            }
            Write-FlickFitHost ""
        }

        $archives = @(Get-ChildItem -LiteralPath . -File -ErrorAction SilentlyContinue | Where-Object { $ArchiveExtensions -contains $_.Extension.ToLower() } | Sort-Object Name)
        $subfolderArchives = @()
        foreach ($subDir in $localDirs) {
            $subArchives = @(Get-ChildItem -LiteralPath $subDir.FullName -File -ErrorAction SilentlyContinue |
                Where-Object { $ArchiveExtensions -contains $_.Extension.ToLower() })
            if ($subArchives.Count -gt 0) { $subfolderArchives += $subArchives }
        }

        if ($RunPhaseA -and ($archives.Count -gt 0 -or $subfolderArchives.Count -gt 0)) {
            foreach ($arc in $archives) { $selectedArchives.Add($arc) }
            foreach ($arc in $subfolderArchives) { $subfolderArchivesToProcess.Add($arc) }
            $totalArchives = $selectedArchives.Count + $subfolderArchivesToProcess.Count
            if ($totalArchives -eq 0) { throw "中断: 解凍対象がありません" }

            Write-FlickFitHost "$($archives.Count) 件の圧縮ファイルが見つかりました（直下）:" -ForegroundColor Cyan
            $selectedArchives | ForEach-Object { Write-FlickFitHost "  - $($_.Name)" -ForegroundColor Gray }
            if ($subfolderArchives.Count -gt 0) {
                Write-FlickFitHost "$($subfolderArchives.Count) 件の圧縮ファイルがサブフォルダ内に見つかりました:" -ForegroundColor Cyan
                $subfolderArchivesToProcess | ForEach-Object {
                    Write-FlickFitHost "  - $($_.FullName.Replace($WorkDir + '\', ''))" -ForegroundColor Gray
                }
            }
            Write-FlickFitHost "`n  解凍対象 ($totalArchives 件):"
            $selectedArchives | ForEach-Object { Write-FlickFitHost "    [OK] $($_.Name)" -ForegroundColor Green }
            $subfolderArchivesToProcess | ForEach-Object { Write-FlickFitHost "    [OK] $($_.FullName.Replace($WorkDir + '\', ''))" -ForegroundColor Green }
            $extractConfirm = (Read-HostWithEsc "`n  解凍を実行しますか？ (Y/n)").Trim()
            if ($extractConfirm -match '^[nN]') { throw "中断: ユーザーキャンセル" }

            # Windows PowerShell 5.1 の New-Item に -LiteralPath はない
            $unpackP = Join-Path $WorkDir "_unpacked"
            [void][System.IO.Directory]::CreateDirectory($unpackP)
            $unpackRoot = Get-Item -LiteralPath $unpackP

            foreach ($arc in $selectedArchives) {
                $dest = Join-Path $unpackRoot.FullName (Sanitize-FileName $arc.BaseName)
                Write-FlickFitHost "  解凍中: $($arc.Name)" -ForegroundColor Gray
                if (-not $DryRun -and $WinRAR) { & $WinRAR x -y -o+ $arc.FullName "$dest\" | Out-Null }
            }
            foreach ($arc in $subfolderArchivesToProcess) {
                $parentDirName = Split-Path (Split-Path $arc.FullName -Parent) -Leaf
                $parentDest = Join-Path $unpackRoot.FullName (Sanitize-FileName $parentDirName)
                $dest = Join-Path $parentDest (Sanitize-FileName $arc.BaseName)
                Write-FlickFitHost "  解凍中: $($arc.FullName.Replace($WorkDir + '\', ''))" -ForegroundColor Gray
                if (-not $DryRun -and $WinRAR) {
                    if (-not (Test-Path -LiteralPath $parentDest)) { [void][System.IO.Directory]::CreateDirectory($parentDest) }
                    & $WinRAR x -y -o+ $arc.FullName "$dest\" | Out-Null
                }
            }

            $maxNestedPasses = 5
            for ($nestPass = 0; $nestPass -lt $maxNestedPasses; $nestPass++) {
                $innerArchives = @(Get-ChildItem -LiteralPath $unpackRoot.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $ArchiveExtensions -contains $_.Extension.ToLower() })
                if ($innerArchives.Count -eq 0) { break }
                Write-FlickFitHost "`n  ネスト解凍（$($innerArchives.Count) 件）:" -ForegroundColor Cyan
                foreach ($ia in $innerArchives) {
                    $parentDir = Split-Path $ia.FullName -Parent
                    $destDir = Join-Path $parentDir (Sanitize-FileName $ia.BaseName)
                    Write-FlickFitHost "    解凍中: $($ia.FullName.Replace($unpackRoot.FullName + '\', ''))" -ForegroundColor Gray
                    if (-not $DryRun -and $WinRAR) {
                        if (-not (Test-Path -LiteralPath $destDir)) { [void][System.IO.Directory]::CreateDirectory($destDir) }
                        & $WinRAR x -y -o+ $ia.FullName "${destDir}\" | Out-Null
                        Remove-Item -LiteralPath $ia.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $epubArchives = @($selectedArchives | Where-Object { $_.Extension.ToLower() -eq '.epub' })
            if ($epubArchives.Count -gt 0) {
                Write-FlickFitHost "`n  [EPUB処理] $($epubArchives.Count) 件のEPUBファイルを処理します" -ForegroundColor Cyan
                foreach ($epubArc in $epubArchives) {
                    $epubFolder = Join-Path $unpackRoot.FullName (Sanitize-FileName $epubArc.BaseName)
                    if (-not (Test-Path -LiteralPath $epubFolder)) { continue }

                    $epubBaseName = $epubArc.BaseName
                    Write-FlickFitHost "`n  ========================================" -ForegroundColor DarkGray
                    Write-FlickFitHost "  EPUB: $($epubArc.Name)" -ForegroundColor Cyan

                    # -- OPFメタデータ解析（EpubMetadata.py） ------------------
                    $opfMeta = $null
                    if ($PythonExe -and (Test-Path -LiteralPath $epubMetadataPy)) {
                        try {
                            $prevEnc = [Console]::OutputEncoding
                            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                            $env:PYTHONUTF8 = '1'
                            $metaJson = (& $PythonExe $epubMetadataPy $epubFolder 2>$null) -join ''
                            [Console]::OutputEncoding = $prevEnc
                            if ($metaJson) {
                                $opfMeta = $metaJson | ConvertFrom-Json
                                if ($opfMeta.error) {
                                    Write-FlickFitHost "    [OPF警告] $($opfMeta.error)" -ForegroundColor Yellow
                                    $opfMeta = $null
                                }
                            }
                        } catch {
                            Write-FlickFitHost "    [OPF警告] メタデータ解析に失敗しました: $_" -ForegroundColor Yellow
                        }
                    }

                    # 画像処理は拡張子で限定済み。実行形式等が混入していても触らないが、件数だけ警告
                    if ($script:FlickFitDangerousNonImageExtensions -and $script:FlickFitDangerousNonImageExtensions.Count -gt 0) {
                        $dangF = @(
                            Get-ChildItem -LiteralPath $epubFolder -Recurse -File -ErrorAction SilentlyContinue |
                                Where-Object { $script:FlickFitDangerousNonImageExtensions -contains $_.Extension.ToLower() }
                        )
                        if ($dangF.Count -gt 0) {
                            $sample = @($dangF | Select-Object -First 5 | ForEach-Object { $_.Name })
                            $more = if ($dangF.Count -gt 5) { " … (+$($dangF.Count - 5))" } else { '' }
                            Write-FlickFitWarning "    [安全] 非画像（実行形式等）が $($dangF.Count) 件（無視。画像のみ処理）: $($sample -join ', ')$more"
                        }
                    }

                    # -- タイトル・作者 -----------------------------------------
                    if ($opfMeta -and $opfMeta.title) {
                        Write-FlickFitHost "    タイトル  : $($opfMeta.title)" -ForegroundColor Cyan
                        $epubTitleMap[$epubBaseName] = $opfMeta.title
                    }
                    if ($opfMeta -and $opfMeta.creator) {
                        Write-FlickFitHost "    作者      : $($opfMeta.creator)" -ForegroundColor Cyan
                        $epubCreatorMap[$epubBaseName] = $opfMeta.creator
                    }
                    if ($opfMeta -and $opfMeta.series_title) {
                        Write-FlickFitHost "    シリーズ  : $($opfMeta.series_title)" -ForegroundColor DarkCyan
                    }

                    # -- 巻番号（OPF優先 -> ファイル名フォールバック）------------
                    $epubVol = $null
                    if ($opfMeta -and $null -ne $opfMeta.vol_num) {
                        try { $epubVol = [int]$opfMeta.vol_num } catch {}
                    }
                    if ($null -eq $epubVol) {
                        # ファイル名から推定
                        $volStr = $null
                        if    ($epubBaseName -match '第\s*(\d{1,3})\s*巻')                        { $volStr = $Matches[1] }
                        elseif ($epubBaseName -match '\s+(\d{1,3})\s*[－—─-]')                 { $volStr = $Matches[1] }
                        elseif ($epubBaseName -match '[_\s]0*(\d{1,3})\s*[【〔「｢\[\(（]')     { $volStr = $Matches[1] }
                        elseif ($epubBaseName -match '(?:_|\s)0*(\d{1,3})\s*$')                { $volStr = $Matches[1] }
                        elseif ($epubBaseName -match '(?:_|^)v(\d{1,3})(?:_|$|\s)')           { $volStr = $Matches[1] }
                        elseif ($epubBaseName -match '[（\(]\s*(\d{1,3})\s*[）\)]')            { $volStr = $Matches[1] }
                        if ($volStr) { try { $epubVol = [int](Convert-ZenToHan $volStr) } catch {} }
                    }
                    if ($null -ne $epubVol) {
                        $src = if ($opfMeta -and $null -ne $opfMeta.vol_num) { 'OPF' } else { 'ファイル名' }
                        Write-FlickFitHost "    巻番号    : 第 $epubVol 巻  （検出元: $src）" -ForegroundColor Green
                        $epubFolderVolMap[$epubFolder] = $epubVol
                    } else {
                        Write-FlickFitHost "    巻番号    : 検出できませんでした" -ForegroundColor Yellow
                    }

                    # -- spine順画像リスト（OPF取得済みの場合）----------------
                    $spineImages = @()
                    if ($opfMeta -and $opfMeta.images_in_order -and $opfMeta.images_in_order.Count -gt 0) {
                        $spineImages = @($opfMeta.images_in_order | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
                        if ($spineImages.Count -gt 0) {
                            Write-FlickFitHost "    spine順画像: $($spineImages.Count) 枚" -ForegroundColor DarkCyan
                            $epubSpineImageMap[$epubBaseName] = $spineImages

                            # -- spine順に連番リネーム（ファイル名順 ≠ ページ順の場合に対応）--
                            if (-not $DryRun) {
                                $padLen = [Math]::Max(4, $spineImages.Count.ToString().Length)
                                # 既に連番済みかチェック（先頭が "0001.ext" 形式なら不要）
                                $firstExpected = "{0:D$padLen}$([System.IO.Path]::GetExtension($spineImages[0]))" -f 1
                                $needRename = (Split-Path $spineImages[0] -Leaf) -ine $firstExpected

                                if ($needRename) {
                                    Write-FlickFitHost "    spine順リネーム中..." -ForegroundColor DarkCyan
                                    # 旧カバーパスの spine 内インデックスを先に記録
                                    $oldCoverPath = if ($epubCoverMap.ContainsKey($epubBaseName)) { $epubCoverMap[$epubBaseName] } else { $null }
                                    $coverSpineIdx = -1
                                    if ($oldCoverPath) {
                                        for ($ci = 0; $ci -lt $spineImages.Count; $ci++) {
                                            if ([string]::Equals($spineImages[$ci], $oldCoverPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                                                $coverSpineIdx = $ci; break
                                            }
                                        }
                                    }
                                    $tmpPrefix = "_sr_$(([Guid]::NewGuid().ToString('N').Substring(0,6)))_"
                                    # Pass1: 全ファイルを一時名にリネーム（名前衝突を回避）
                                    $tmpPaths = [System.Collections.Generic.List[string]]::new()
                                    foreach ($imgPath in $spineImages) {
                                        if (Test-Path -LiteralPath $imgPath) {
                                            $ext  = [System.IO.Path]::GetExtension($imgPath)
                                            $tmpN = "$tmpPrefix$([System.IO.Path]::GetFileNameWithoutExtension($imgPath))$ext"
                                            $tmpP = Join-Path (Split-Path $imgPath -Parent) $tmpN
                                            try { Rename-Item -LiteralPath $imgPath -NewName $tmpN -ErrorAction Stop } catch { $tmpP = $imgPath }
                                            $tmpPaths.Add($tmpP)
                                        } else { $tmpPaths.Add($imgPath) }
                                    }
                                    # Pass2: 連番最終名にリネーム
                                    $renamedSpine = [System.Collections.Generic.List[string]]::new()
                                    for ($si = 0; $si -lt $tmpPaths.Count; $si++) {
                                        $tp = $tmpPaths[$si]
                                        if (Test-Path -LiteralPath $tp) {
                                            $ext  = [System.IO.Path]::GetExtension($tp)
                                            $finN = "{0:D$padLen}$ext" -f ($si + 1)
                                            $finP = Join-Path (Split-Path $tp -Parent) $finN
                                            try { Rename-Item -LiteralPath $tp -NewName $finN -ErrorAction Stop } catch { $finP = $tp }
                                            $renamedSpine.Add($finP)
                                            if ($si -eq $coverSpineIdx) { $epubCoverMap[$epubBaseName] = $finP }
                                        } else { $renamedSpine.Add($tp) }
                                    }
                                    $epubSpineImageMap[$epubBaseName] = @($renamedSpine)
                                    Write-FlickFitHost "    リネーム完了: 0001～$("{0:D$padLen}" -f $renamedSpine.Count)" -ForegroundColor DarkCyan
                                }
                            }
                        }
                    }

                    # -- 画像フォルダ一覧（既存ロジック）----------------------
                    $imgFolders = @(Get-ChildItem -LiteralPath $epubFolder -Recurse -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        $imgCount = @(Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue | Where-Object { $ImageExtensions -contains $_.Extension.ToLower() }).Count
                        if ($imgCount -gt 0) { [PSCustomObject]@{ Path=$_.FullName; Name=$_.Name; RelPath=$_.FullName.Replace($epubFolder + '\', ''); ImageCount=$imgCount } }
                    } | Where-Object { $_ })
                    $rootImgCount = @(Get-ChildItem -LiteralPath $epubFolder -File -ErrorAction SilentlyContinue | Where-Object { $ImageExtensions -contains $_.Extension.ToLower() }).Count
                    if ($rootImgCount -gt 0) {
                        $imgFolders = @([PSCustomObject]@{ Path=$epubFolder; Name=(Split-Path $epubFolder -Leaf); RelPath='.'; ImageCount=$rootImgCount }) + $imgFolders
                    }
                    if ($imgFolders.Count -eq 0) {
                        Write-FlickFitHost "    画像フォルダが見つかりません" -ForegroundColor Yellow
                        continue
                    }

                    $imgFolders = @($imgFolders | Sort-Object -Property ImageCount -Descending)
                    Write-FlickFitHost "`n    画像フォルダ一覧:" -ForegroundColor White
                    for ($i = 0; $i -lt $imgFolders.Count; $i++) {
                        $f = $imgFolders[$i]
                        $marker = if ($i -eq 0) { " ★メイン" } else { "" }
                        Write-FlickFitHost ("      [{0}] {1} ({2}枚){3}" -f ($i+1), $f.RelPath, $f.ImageCount, $marker) -ForegroundColor $(if ($i -eq 0) { "Green" } else { "Gray" })
                    }
                    $mainFolder = $imgFolders[0]
                    Write-FlickFitHost "`n    メインページフォルダ: $($mainFolder.RelPath) ($($mainFolder.ImageCount)枚)" -ForegroundColor Green
                    $epubMainFolderMap[$epubBaseName] = $mainFolder.Path

                    # -- 表紙画像の特定 ----------------------------------------
                    $mainImages = @(Get-ChildItem -LiteralPath $mainFolder.Path -File -ErrorAction SilentlyContinue |
                        Where-Object { $ImageExtensions -contains $_.Extension.ToLower() } |
                        Sort-Object { [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(10,'0') }) })

                    # OPF cover-image プロパティが最優先
                    $opfCoverPath = if ($opfMeta -and $opfMeta.cover_image_path) { $opfMeta.cover_image_path } else { $null }

                    # spine先頭がカバー候補
                    $spineFirstCover = if ($spineImages.Count -gt 0) {
                        $spineImages | Where-Object { $_ -match '(?i)(cover|表紙|カバー|hyoushi)' } | Select-Object -First 1
                    } else { $null }
                    if (-not $spineFirstCover -and $spineImages.Count -gt 0) {
                        $spineFirstCover = $spineImages[0]
                    }

                    $coverFolderCandidates = @($imgFolders | Where-Object {
                        $_.Name -match $script:FlickFitRegexCoverTokenAnywhere -or $_.RelPath -match '(?i)(cover|表紙)'
                    })
                    $coverInMain = @($mainImages | Where-Object { $_.Name -match '(?i)(cover|表紙|カバー|hyoushi)' })

                    if ($opfCoverPath -and (Test-Path -LiteralPath $opfCoverPath)) {
                        # OPF の cover-image プロパティで明示されたカバー（最優先）
                        $epubCoverMap[$epubBaseName] = $opfCoverPath
                        Write-FlickFitHost "    -> 表紙（OPF cover-image）: $(Split-Path $opfCoverPath -Leaf)" -ForegroundColor Green
                    } elseif ($spineFirstCover -and (Test-Path -LiteralPath $spineFirstCover)) {
                        # spineから特定
                        $epubCoverMap[$epubBaseName] = $spineFirstCover
                        Write-FlickFitHost "    -> 表紙（spine先頭）: $(Split-Path $spineFirstCover -Leaf)" -ForegroundColor Green
                    } elseif ($coverInMain.Count -gt 0) {
                        $epubCoverMap[$epubBaseName] = $coverInMain[0].FullName
                        Write-FlickFitHost "    -> 表紙候補（メインフォルダ内）: $($coverInMain[0].Name)" -ForegroundColor Cyan
                    } elseif ($coverFolderCandidates.Count -gt 0) {
                        Write-FlickFitHost "`n    表紙フォルダ候補:" -ForegroundColor Cyan
                        for ($i = 0; $i -lt $coverFolderCandidates.Count; $i++) {
                            Write-FlickFitHost "      [$($i+1)] $($coverFolderCandidates[$i].RelPath) ($($coverFolderCandidates[$i].ImageCount)枚)" -ForegroundColor White
                        }
                        $coverFolderAns = Read-HostWithEsc "    表紙フォルダ番号 (空:最初の画像を表紙)"
                        if ($coverFolderAns -match '^\d+$') {
                            $cfIdx = [int]$coverFolderAns - 1
                            if ($cfIdx -ge 0 -and $cfIdx -lt $coverFolderCandidates.Count) {
                                $coverImages = @(Get-ChildItem -LiteralPath $coverFolderCandidates[$cfIdx].Path -File -ErrorAction SilentlyContinue |
                                    Where-Object { $ImageExtensions -contains $_.Extension.ToLower() } |
                                    Sort-Object { [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(10,'0') }) })
                                if ($coverImages.Count -gt 0) {
                                    for ($j = 0; $j -lt $coverImages.Count; $j++) { Write-FlickFitHost "      [$($j+1)] $($coverImages[$j].Name)" -ForegroundColor Gray }
                                    $coverImgAns = Read-HostWithEsc "    表紙画像番号 (空:1)"
                                    $covImgIdx = if ($coverImgAns -match '^\d+$') { [int]$coverImgAns - 1 } else { 0 }
                                    if ($covImgIdx -ge 0 -and $covImgIdx -lt $coverImages.Count) {
                                        $epubCoverMap[$epubBaseName] = $coverImages[$covImgIdx].FullName
                                        Write-FlickFitHost "    -> 表紙: $($coverImages[$covImgIdx].Name)" -ForegroundColor Green
                                    }
                                }
                            }
                        } else {
                            if ($mainImages.Count -gt 0) {
                                $epubCoverMap[$epubBaseName] = $mainImages[0].FullName
                                Write-FlickFitHost "    -> 表紙（先頭画像）: $($mainImages[0].Name)" -ForegroundColor Green
                            }
                        }
                    } else {
                        if ($imgFolders.Count -eq 1 -and $mainImages.Count -gt 0) {
                            # 画像フォルダが1つだけの場合は自動的に先頭画像を表紙に使用
                            $epubCoverMap[$epubBaseName] = $mainImages[0].FullName
                            Write-FlickFitHost "    -> 表紙（先頭画像・自動）: $($mainImages[0].Name)" -ForegroundColor Green
                            continue
                        }
                        Write-FlickFitHost "`n    表紙フォルダが見つかりません。フォルダを選択してください:" -ForegroundColor Yellow
                        try { Start-Process "explorer.exe" -ArgumentList $epubFolder } catch {}
                        for ($i = 0; $i -lt $imgFolders.Count; $i++) {
                            $f = $imgFolders[$i]
                            Write-FlickFitHost "      [$($i+1)] $($f.RelPath) ($($f.ImageCount)枚)  -> $($f.Path)" -ForegroundColor White
                        }
                        Write-FlickFitHost "      [0] 先頭画像を表紙に使用" -ForegroundColor DarkGray
                        $folderAns = Read-HostWithEsc "    フォルダ番号 (空:0)"
                        if ($folderAns -match '^\d+$' -and [int]$folderAns -gt 0) {
                            $fIdx = [int]$folderAns - 1
                            if ($fIdx -ge 0 -and $fIdx -lt $imgFolders.Count) {
                                $coverImages = @(Get-ChildItem -LiteralPath $imgFolders[$fIdx].Path -File -ErrorAction SilentlyContinue |
                                    Where-Object { $ImageExtensions -contains $_.Extension.ToLower() } |
                                    Sort-Object { [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(10,'0') }) })
                                if ($coverImages.Count -gt 0) {
                                    for ($j = 0; $j -lt $coverImages.Count; $j++) { Write-FlickFitHost "      [$($j+1)] $($coverImages[$j].Name)" -ForegroundColor Gray }
                                    $coverImgAns = Read-HostWithEsc "    表紙画像番号 (空:1)"
                                    $covImgIdx = if ($coverImgAns -match '^\d+$') { [int]$coverImgAns - 1 } else { 0 }
                                    if ($covImgIdx -ge 0 -and $covImgIdx -lt $coverImages.Count) {
                                        $epubCoverMap[$epubBaseName] = $coverImages[$covImgIdx].FullName
                                        Write-FlickFitHost "    -> 表紙: $($coverImages[$covImgIdx].Name)" -ForegroundColor Green
                                    }
                                }
                            }
                        } else {
                            if ($mainImages.Count -gt 0) {
                                $epubCoverMap[$epubBaseName] = $mainImages[0].FullName
                                Write-FlickFitHost "    -> 表紙（先頭画像）: $($mainImages[0].Name)" -ForegroundColor Green
                            }
                        }
                    }
                }
            }

            $unpackedDirs = @(Get-ChildItem -LiteralPath $unpackRoot.FullName -Directory -ErrorAction SilentlyContinue)
            $allCandidateDirs = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($d in $unpackedDirs) {
                $allCandidateDirs.Add([PSCustomObject]@{ Path=$d.FullName; Name=$d.Name; Source='解凍' })
            }
            foreach ($d in $localDirs) {
                $existing = $unpackedDirs | Where-Object { $_.Name -eq $d.Name }
                if (-not $existing) {
                    $allCandidateDirs.Add([PSCustomObject]@{ Path=$d.FullName; Name=$d.Name; Source='既存' })
                }
            }
            $sortedCandidates = @($allCandidateDirs | Sort-Object { [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(10,'0') }) })
            $hasExisting = @($sortedCandidates | Where-Object { $_.Source -eq '既存' }).Count -gt 0

            if ($hasExisting) {
                Write-FlickFitHost "`n=== フォルダ一覧精査 ===" -ForegroundColor Cyan
                Write-FlickFitHost "処理対象となるフォルダ一覧:" -ForegroundColor White
                for ($i = 0; $i -lt $sortedCandidates.Count; $i++) {
                    $c = $sortedCandidates[$i]
                    $srcLabel = if ($c.Source -eq '解凍') { "[解凍]" } else { "[既存]" }
                    $color = if ($c.Source -eq '解凍') { "Green" } else { "Yellow" }
                    Write-FlickFitHost ("  [{0,2}] {1} {2}" -f ($i+1), $srcLabel, $c.Name) -ForegroundColor $color
                }
                Write-FlickFitHost "`n  除外するフォルダがあれば番号を入力 (例: 1,3,5 または 1-3)" -ForegroundColor Gray
                Write-FlickFitHost "  Enter: すべて処理 / q: 中断" -ForegroundColor Gray
                $excludeInput = Read-HostWithEsc "除外番号"
                if ($excludeInput -eq 'q') { throw "中断: ユーザーキャンセル" }
                $excludeIndices = @()
                if ($excludeInput -and $excludeInput.Trim() -ne '') {
                    $excludeIndices = @(Parse-RangeInput $excludeInput $sortedCandidates.Count)
                }
                $selectedDirs = @()
                for ($i = 0; $i -lt $sortedCandidates.Count; $i++) {
                    if ($excludeIndices -notcontains ($i + 1)) { $selectedDirs += $sortedCandidates[$i] }
                }
                if ($selectedDirs.Count -eq 0) { throw "中断: 処理対象がありません" }
                Write-FlickFitHost "`n  処理対象 ($($selectedDirs.Count) フォルダ):" -ForegroundColor White
                foreach ($d in $selectedDirs) {
                    $srcLabel = if ($d.Source -eq '解凍') { "[解凍]" } else { "[既存]" }
                    $color = if ($d.Source -eq '解凍') { "Green" } else { "Yellow" }
                    Write-FlickFitHost ("    [OK] {0} {1}" -f $srcLabel, $d.Name) -ForegroundColor $color
                }
            } else {
                $selectedDirs = $sortedCandidates
            }

            $selectedExistingFolders = @($selectedDirs | Where-Object { $_.Source -eq '既存' } | ForEach-Object { $_.Path })
            foreach ($d in $selectedDirs) { $targetRoots.Add($d.Path) }

        } elseif ($RunPhaseA -and $localDirs.Count -gt 0) {
            Write-FlickFitHost "圧縮ファイルが見つかりません。既存フォルダを処理します:" -ForegroundColor Yellow
            $lines = @($localDirs | ForEach-Object { "  - $($_.Name)" })
            $n = $lines.Count; $mid = [Math]::Ceiling($n / 2); $colWidth = 48
            for ($i = 0; $i -lt $mid; $i++) {
                $left = $lines[$i].PadRight($colWidth)
                $right = if ($i + $mid -lt $n) { $lines[$i + $mid] } else { "" }
                if ($right) { Write-FlickFitHost ($left + "  " + $right) -ForegroundColor Gray } else { Write-FlickFitHost $left -ForegroundColor Gray }
            }
            $folderConfirm = (Read-HostWithEsc "`n  これらのフォルダを整理しますか？ (Y/n)").Trim()
            if ($folderConfirm -match '^[nN]') { throw "中断: ユーザーキャンセル" }
            $selectedExistingFolders = @($localDirs | ForEach-Object { $_.FullName })
            foreach ($d in $localDirs) { $targetRoots.Add($d.FullName) }
        } elseif ($RunPhaseA) {
            # 圧縮ファイルもサブフォルダもないが、作業フォルダ直下に画像／変換対象（.bpg 等）だけある場合
            $rootFiles = @(Get-ChildItem -LiteralPath $WorkDir -File -ErrorAction SilentlyContinue)
            $processableExt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($x in $ImageExtensions) { [void]$processableExt.Add($x.ToLower()) }
            foreach ($x in $ConvertExtensions) { [void]$processableExt.Add($x.ToLower()) }
            $rootProcessable = @($rootFiles | Where-Object { $processableExt.Contains($_.Extension.ToLower()) })
            if ($rootProcessable.Count -gt 0) {
                Write-FlickFitHost "圧縮ファイル・サブフォルダはありません。作業フォルダ直下の画像を処理します:" -ForegroundColor Yellow
                Write-FlickFitHost "  -> $($rootProcessable.Count) 件（例: $($rootProcessable[0].Name) ほか）" -ForegroundColor Gray
                $folderConfirm = (Read-HostWithEsc "`n  このフォルダを整理しますか？ (Y/n)").Trim()
                if ($folderConfirm -match '^[nN]') { throw "中断: ユーザーキャンセル" }
                $selectedExistingFolders = @($WorkDir)
                $targetRoots.Add($WorkDir)
            } else {
                throw "処理対象となるファイルが見つかりません。（ZIP/RAR 等、または画像入りのサブフォルダ／作業フォルダ直下の画像が必要です）"
            }
        } else {
            $localDirs = @(Get-ChildItem -LiteralPath . -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^_unpacked$' })
            if ($localDirs.Count -eq 0) { throw "処理対象のフォルダが見つかりません。" }
            foreach ($d in $localDirs) { $targetRoots.Add($d.FullName) }
        }
    } catch {
        throw
    } finally {
        Pop-Location
    }

    return @{
        UnpackRoot                 = $unpackRoot
        TargetRoots                = $targetRoots
        EpubFolderVolMap           = $epubFolderVolMap
        EpubCoverMap               = $epubCoverMap
        EpubMainFolderMap          = $epubMainFolderMap
        EpubTitleMap               = $epubTitleMap
        EpubCreatorMap             = $epubCreatorMap
        EpubSpineImageMap          = $epubSpineImageMap
        SelectedExistingFolders    = $selectedExistingFolders
        SelectedArchives           = $selectedArchives
        SubfolderArchivesToProcess = $subfolderArchivesToProcess
    }
}
