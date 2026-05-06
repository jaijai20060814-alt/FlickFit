#Requires -Version 5.1
<#
.SYNOPSIS
    VolumePatternOverrides.json（プロジェクト直下・任意）で配布元プレフィックス等を既定に追加マージする。
    VolumePatternRules.txt（同・任意）はテキスト辞書（[ignore]/[replace] 等）→ Initialize-FlickFitVolumeTextRules。
.DESCRIPTION
    話数プレフィックス・sanitize パターンの**内蔵既定は空**（公開用）。プロジェクト直下の VolumePatternOverrides.json でマージする。テンプレは VolumePatternOverrides.example.json、実名寄りの参考は VolumePatternOverrides.legacy-example.json。
    JSON が無い場合は該当正規表現を「常に不一致」にし、汎用ルート（chapter / 第N話 等）のみ。表紙トークンは Build-FlickFitCoverNamePatterns（別フェーズで整理可）。
    フェーズ1: 巻・話・Sanitize。フェーズ2a: 表紙は内蔵で cover/表紙/カバーのみ。固有名は VolumePatternOverrides.json の cover_folder_name_tokens_extra（例は example 参照）。
    フェーズ2b: optional 追加トークンを最優先 1 段、続けて一般（cover/表紙/カバー＋(0|cover) 等）を FlickFitRegexCoverSpecialPriorityToken / FlickFitRegexCoverGeneralTokenNoSpecial で分離。
#>

function Merge-FlickFitUniqueStringsCI {
    param([string[]]$Items)
    $h = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $acc = [System.Collections.Generic.List[string]]::new()
    foreach ($it in $Items) {
        if ([string]::IsNullOrWhiteSpace($it)) { continue }
        $t = $it.Trim()
        if ($h.Add($t)) { [void]$acc.Add($t) }
    }
    # 1 要素のとき戻りがスカラー化され、呼び出し側の .Count / -join で落ちるのを防ぐ
    $arr = $acc.ToArray()
    if ($arr.Length -eq 1) { return ,$arr }
    return $arr
}

function Build-FlickFitCoverNamePatterns {
    param([string[]]$ExtraCoverTokens)
    $baseCoverTok = @('cover', '表紙', 'カバー')
    $merged = Merge-FlickFitUniqueStringsCI ($baseCoverTok + @($ExtraCoverTokens))
    $alt = ($merged | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $altGeneralNoSpecial = ($baseCoverTok | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $addOnly = Merge-FlickFitUniqueStringsCI @($ExtraCoverTokens)
    if (@($addOnly).Count -gt 0) {
        $escAdd = @($addOnly) | ForEach-Object { [regex]::Escape($_) }
        $script:FlickFitRegexCoverSpecialPriorityToken = '^(?i)(?:' + ($escAdd -join '|') + ')$'
    } else {
        $script:FlickFitRegexCoverSpecialPriorityToken = '(?!)'
    }
    $script:FlickFitRegexCoverGeneralTokenNoSpecial = '^(?i)(?:' + $altGeneralNoSpecial + ')\d*$|^[^\-_]+[-_](0|cover)$'
    $script:CoverFolderNameLikeRegex = '^(?i)(?:' + $alt + ')\d*$|^[^\-_]+[-_](0|cover)$|^0+$'
    $script:FlickFitRegexCoverUnionOrPad = '(?i)(?:' + $alt + ')|^[^\-_]+[-_](0|cover)$'
    $script:FlickFitRegexCoverLeafOrZero = '^(?i)(?:' + $alt + '|0)$'
    $script:FlickFitRegexCoverHashPref = '(?i)(^|[-_#])(?:' + $alt + ')'
    $script:FlickFitRegexCoverNameDigitsOnly = '^(?i)(?:' + $alt + ')\d*$'
    $script:FlickFitRegexCoverUnionLooseNoAnchor = '(?i)(?:' + $alt + ')\d*|^[^\-_]+[-_](0|cover)$'
    $script:FlickFitRegexCoverTokenAnywhere = '(?i)(?:' + $alt + ')'
    $script:FlickFitRegexVolCtxCoverLine1 = '(?i)(^|[\s_\-\.])(?:' + $alt + ')\d*([\s_\-]|$)'
    $script:FlickFitRegexVolCtxCoverLine2 = '(?i)^(?:' + $alt + ')\d*$'
    $script:FlickFitRegexCoverBareTokensOnly = '^(?i)(?:' + $alt + ')$'
}

function Initialize-FlickFitVolumePatternOverrides {
    param(
        [string]$ProjectRoot
    )
    if (Get-Command Initialize-FlickFitVolumeTextRules -ErrorAction SilentlyContinue) {
        try { Initialize-FlickFitVolumeTextRules -ProjectRoot $ProjectRoot } catch { }
    }
    $defChapter = @()
    $defVolume  = @()
    $defSanitize = @()
    $addCh  = @()
    $addVol = @()
    $addSan = @()
    $addCover = @()
    if ($ProjectRoot) {
        $jsonPath = Join-Path $ProjectRoot 'VolumePatternOverrides.json'
        if (Test-Path -LiteralPath $jsonPath) {
            try {
                $j = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $j -and $j.PSObject.Properties['source_prefixes'] -and $j.source_prefixes) {
                    $sp = $j.source_prefixes
                    if ($sp.PSObject.Properties['chapter'] -and $sp.chapter) { $addCh = @($sp.chapter) }
                    if ($sp.PSObject.Properties['volume'] -and $sp.volume) { $addVol = @($sp.volume) }
                }
                if ($j.PSObject.Properties['sanitize_source_noise_patterns'] -and $j.sanitize_source_noise_patterns) {
                    $addSan = @($j.sanitize_source_noise_patterns)
                }
                if ($j.PSObject.Properties['cover_folder_name_tokens_extra'] -and $j.cover_folder_name_tokens_extra) {
                    $addCover = @($j.cover_folder_name_tokens_extra)
                }
            } catch {
                $msg = "VolumePatternOverrides.json の読み込みに失敗しました（source/sanitize は未設定扱い）: $($_.Exception.Message)"
                if (Get-Command Write-FlickFitWarning -ErrorAction SilentlyContinue) {
                    Write-FlickFitWarning $msg
                } else {
                    Write-Warning $msg
                }
            }
        }
    }
    $mergedCh  = Merge-FlickFitUniqueStringsCI @($defChapter + $addCh)
    $mergedVol = Merge-FlickFitUniqueStringsCI @($defVolume + $addVol)
    $mergedSan = Merge-FlickFitUniqueStringsCI @($defSanitize + $addSan)
    if (@($mergedCh).Count -gt 0) {
        $escCh  = @($mergedCh) | ForEach-Object { [regex]::Escape($_) }
        $script:FlickFitRegexChapterSourceNumeric = '(?i)(?:' + ($escCh -join '|') + ')[\-_.]+(\d+)'
    } else {
        $script:FlickFitRegexChapterSourceNumeric = '(?!)'
    }
    if (@($mergedVol).Count -gt 0) {
        $escVol = @($mergedVol) | ForEach-Object { [regex]::Escape($_) }
        $script:FlickFitRegexVolumeSourceFolderId = '(?i)(?:' + ($escVol -join '|') + ')[\-_.]+\d+(?:_files)?$'
    } else {
        $script:FlickFitRegexVolumeSourceFolderId = '(?!)'
    }
    if (@($mergedSan).Count -gt 0) {
        $script:FlickFitRegexSanitizeLeadingSourceNoise = '(?i)^(' + (@($mergedSan) -join '|') + ')[\-_]'
    } else {
        $script:FlickFitRegexSanitizeLeadingSourceNoise = '(?!)'
    }
    Build-FlickFitCoverNamePatterns -ExtraCoverTokens $addCover
}

function Ensure-FlickFitVolumePatternRegexes {
    if ($null -ne $script:FlickFitRegexSanitizeLeadingSourceNoise -and
        $null -ne $script:FlickFitRegexChapterSourceNumeric -and
        $null -ne $script:FlickFitRegexVolumeSourceFolderId -and
        $null -ne $script:CoverFolderNameLikeRegex -and
        $null -ne $script:FlickFitRegexCoverSpecialPriorityToken) { return }
    if (Get-Command Initialize-FlickFitVolumePatternOverrides -ErrorAction SilentlyContinue) {
        Initialize-FlickFitVolumePatternOverrides -ProjectRoot $null
    }
    if ($null -eq $script:FlickFitRegexSanitizeLeadingSourceNoise) {
        $script:FlickFitRegexSanitizeLeadingSourceNoise = '(?!)'
    }
    if ($null -eq $script:FlickFitRegexChapterSourceNumeric) {
        $script:FlickFitRegexChapterSourceNumeric = '(?!)'
    }
    if ($null -eq $script:FlickFitRegexVolumeSourceFolderId) {
        $script:FlickFitRegexVolumeSourceFolderId = '(?!)'
    }
    if ($null -eq $script:CoverFolderNameLikeRegex -or $null -eq $script:FlickFitRegexCoverSpecialPriorityToken) {
        Build-FlickFitCoverNamePatterns -ExtraCoverTokens @()
    }
}
