#Requires -Version 5.1
<#
.SYNOPSIS
    漫画整理ツール - 共通ユーティリティ関数
.DESCRIPTION
    入出力、文字列変換、パース関数など
#>

function Write-FlickFitHost {
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()]$Object,
        $ForegroundColor = $null,
        [switch]$NoNewline
    )
    $text = if ($null -eq $Object) { '' } else { "$Object" }
    if (Get-Command Format-FlickFitPublicLogString -ErrorAction SilentlyContinue) {
        try { $text = Format-FlickFitPublicLogString -Text $text } catch {}
    }
    if ($null -ne $ForegroundColor) {
        if ($NoNewline) {
            Write-Host $text -ForegroundColor $ForegroundColor -NoNewline
        } else {
            Write-Host $text -ForegroundColor $ForegroundColor
        }
    } elseif ($NoNewline) {
        Write-Host $text -NoNewline
    } else {
        Write-Host $text
    }
}

function Write-FlickFitWarning {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { Write-Warning ''; return }
    $m = $Message
    if (Get-Command Format-FlickFitPublicLogString -ErrorAction SilentlyContinue) {
        try { $m = Format-FlickFitPublicLogString -Text $m } catch {}
    }
    Write-Warning $m
}

function Write-Step {
    param($Msg, $Color='Cyan')
    Write-FlickFitHost "`n=== $Msg ===" -ForegroundColor $Color
}

function Get-StringDisplayWidth {
    param([string]$Str)
    if (-not $Str) { return 0 }
    $w = 0
    for ($i = 0; $i -lt $Str.Length; $i++) {
        $c = [int][char]$Str[$i]
        if ([char]::IsHighSurrogate($Str[$i])) { $w += 2; $i++; continue }
        $w += if ($c -gt 0xFF -or ($c -ge 0x3000 -and $c -le 0x9FFF)) { 2 } else { 1 }
    }
    return $w
}

# コンソール・IME 混入の不可視文字を除き、全角数字を半角化（番号入力のパース用）
function Sanitize-ConsoleInputLine {
    param([string]$Line)
    if ($null -eq $Line) { return '' }
    $s = $Line.Trim()
    if ($s.Length -eq 0) { return '' }
    $s = Convert-FullWidthToHalfWidth $s
    # 範囲入力 1-2 / 1~2 を IME 由来のダッシュでも解釈（－～〜ー‐ 等 → 半角ハイフン）
    $s = $s -replace '[\uFF0D\u2010\u2011\u2012\u2013\u2014\u2015\u2212\u30FC\u301C\uFF5E]', '-'
    $s = $s -replace "[\uFEFF\u200B-\u200F\u202A-\u202E\u2060]", ''
    return $s.Trim()
}

function Read-HostWithEsc {
    param([string]$Prompt, [switch]$NoColon)
    # 巻ごと自動処理タイマー: ユーザー確認中は一時停止（$script:FolderAutoTimer は Config.ps1 で $null 初期化）
    if ($script:FolderAutoTimer -and $script:FolderAutoTimer.Enabled -and $script:FolderAutoTimer.Stopwatch.IsRunning) {
        $script:FolderAutoTimer.Stopwatch.Stop()
        $prevMs = $script:FolderAutoTimer.ElapsedMs; if ($null -eq $prevMs) { $prevMs = 0 }
        $script:FolderAutoTimer.ElapsedMs = $prevMs + $script:FolderAutoTimer.Stopwatch.ElapsedMilliseconds
    }
    $suffix = if ($NoColon) { " " } else { ": " }
    $dispPrompt = if ($null -eq $Prompt) { '' } else { [string]$Prompt }
    if (Get-Command Format-FlickFitPublicLogString -ErrorAction SilentlyContinue) {
        try { $dispPrompt = Format-FlickFitPublicLogString -Text $dispPrompt } catch {}
    }
    $prefix = "$dispPrompt$suffix"
    Write-Host $prefix -NoNewline
    $userInput = ""
    $script:FlickFitReadHostCtrlUCleared = $false
    $state = @{ maxDisplayWidth = 0 }
    $redraw = {
        $cw = Get-StringDisplayWidth $userInput
        if ($cw -gt $state.maxDisplayWidth) { $state.maxDisplayWidth = $cw }
        $pad = [Math]::Max(0, $state.maxDisplayWidth - $cw)
        Write-Host "`r$prefix$userInput" -NoNewline
        if ($pad -gt 0) { Write-Host (" " * $pad) -NoNewline }
        Write-Host "`r$prefix$userInput" -NoNewline
    }
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Escape') {
                Write-Host ""
                throw "中断: ESCキーが押されました"
            } elseif ($key.Key -eq 'Enter') {
                Write-Host ""
                if ($userInput.Trim() -match '(?i)^exit$') {
                    throw "中断: exit"
                }
                if ($script:FolderAutoTimer -and $script:FolderAutoTimer.Enabled) { $script:FolderAutoTimer.Stopwatch.Restart() }
                return (Sanitize-ConsoleInputLine $userInput)
            } elseif (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'U') {
                $userInput = ""
                $script:FlickFitReadHostCtrlUCleared = $true
                & $redraw
            } elseif ($key.Key -eq 'Backspace' -or $key.Key -eq 'Delete') {
                if ($userInput.Length -gt 0) {
                    $userInput = $userInput.Substring(0, $userInput.Length - 1)
                    & $redraw
                }
            } else {
                $charCode = [int][char]$key.KeyChar
                if ($charCode -ge 0x20) {
                    $userInput += $key.KeyChar
                    & $redraw
                } elseif ($key.Key -ge [ConsoleKey]::D0 -and $key.Key -le [ConsoleKey]::D9) {
                    # 一部コンソールで数字行の KeyChar が \0 になることがある
                    $userInput += [string]([int]$key.Key - [int][ConsoleKey]::D0)
                    & $redraw
                } elseif ($key.Key -ge [ConsoleKey]::NumPad0 -and $key.Key -le [ConsoleKey]::NumPad9) {
                    $userInput += [string]([int]$key.Key - [int][ConsoleKey]::NumPad0)
                    & $redraw
                }
            }
        }
    } catch {
        if ($_.Exception.Message -match '^中断:') { throw }
        Write-Host ""
        $ans = Read-Host $dispPrompt
        if ($ans -and ($ans.Trim() -match '(?i)^exit$')) { throw "中断: exit" }
        if ($script:FolderAutoTimer -and $script:FolderAutoTimer.Enabled) { $script:FolderAutoTimer.Stopwatch.Restart() }
        return (Sanitize-ConsoleInputLine $ans)
    }
}

function Confirm-YN {
    param([string]$Prompt, [bool]$DefaultY = $false)
    $hint = if ($DefaultY) { '(Y/n)' } else { '(y/N)' }
    $ans = Read-HostWithEsc "$Prompt $hint"
    if ($ans -eq '') { return $DefaultY }
    return ($ans -match '^[yY]')
}

function Sanitize-FileName {
    param($Name)
    if (-not $Name) { return "" }
    if (Get-Command Ensure-FlickFitVolumePatternRegexes -ErrorAction SilentlyContinue) { Ensure-FlickFitVolumePatternRegexes }
    if ($null -eq $script:FlickFitRegexSanitizeLeadingSourceNoise) {
        $script:FlickFitRegexSanitizeLeadingSourceNoise = '(?!)'
    }
    $n = $Name -replace $script:FlickFitRegexSanitizeLeadingSourceNoise, ''
    $n = $n -replace '^\d+\.', ''
    $zf = [char]0xFF1F; $zc = [char]0xFF1A; $zast = [char]0xFF0A; $zq = [char]0xFF02; $zlt = [char]0xFF1C; $zgt = [char]0xFF1E; $zpipe = [char]0xFF5C; $zsl = [char]0xFF0F; $zbs = [char]0xFF3C
    $n = $n -replace '\?', $zf -replace ':', $zc -replace '\*', $zast -replace '"', $zq -replace '<', $zlt -replace '>', $zgt -replace '\|', $zpipe -replace '/', $zsl -replace '\\', $zbs
    return $n.Trim()
}

function Extract-TitleFromName {
    param([string]$Name)
    $t = Sanitize-FileName $Name
    $t = $t -replace '[（\(]\s*[0-9０-９]+\s*[）\)]\s*[sSwW]?\s*$', ''
    $t = $t -replace '\[[^\]]+\]', ' ' -replace '【[^】]*】', ' ' -replace '[（\(][^）\)]*[）\)]', ' '
    $t = $t -replace '\s+\d{1,3}\s*[-\-－─—]\s*.*$', ''
    $t = $t -replace '\s+\d{1,3}\s+[ぁ-んァ-ヶ一-龯A-Za-z&＆].*$', ''
    $t = $t -replace '\s+\d{1,3}\s*$', ''
    $t = $t -replace '第[0-9０-９]+巻[sSwW]?[ぁ-んァ-ヶ一-龯\s]*', '' `
            -replace '\s+[vV][oO][lL]?\.?\s*[0-9]+[sSwW]?\w*', '' `
            -replace '\s+[vV]\d{1,3}[-\-－～~]\d{1,3}\w*', '' `
            -replace '\s+[vV]\d{1,3}[sSwWbB]?\s*$', '' `
            -replace '\s+[0-9]+巻[sSwW]?\w*', '' `
            -replace '\s+(DL|zip|rar|RAW|raw)[-\.]?.*$', ''
    $t = $t -replace '\s*[sSwW]\s*$', ''
    $t = $t -replace '([ぁ-んァ-ヶ一-龯])\s+\d{1,3}\s+[ぁ-んァ-ヶ一-龯].*$', '$1'
    $t = $t -replace '^[A-Za-z0-9][A-Za-z0-9\.\-_]*\s+', ''
    $t = $t -replace '^[A-Za-z][A-Za-z\s\-\.]+\s*[\-\s]\s*', ''
    return ($t -replace '\s+', ' ').Trim()
}

function Convert-ZenToHan {
    param([string]$Str)
    for ($i = 0; $i -lt 10; $i++) { $Str = $Str.Replace([string]([char](65296+$i)), [string]$i) }
    return $Str
}

function Convert-FullWidthToHalfWidth {
    param([string]$Text)
    $result = $Text
    for ($i = 0; $i -lt 10; $i++) {
        $result = $result.Replace([string]([char](0xFF10 + $i)), [string]$i)
    }
    return $result
}

function Parse-RangeInput {
    param([string]$InputStr, [int]$MaxVal)
    $indices = [System.Collections.Generic.List[int]]::new()
    try { $max = [int]$MaxVal } catch { return $indices }
    if ($max -lt 1) { return $indices }
    $normLine = Sanitize-ConsoleInputLine $InputStr
    if ([string]::IsNullOrWhiteSpace($normLine)) { return $indices }
    # \d は Unicode 数字も拾うため [0-9] のみ。[regex]::Match で $Matches 競合を避ける
    $rxRange = New-Object System.Text.RegularExpressions.Regex(
        '^\s*([0-9]+)\s*[-~]\s*([0-9]+)\s*$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    $rxOne = New-Object System.Text.RegularExpressions.Regex(
        '^\s*([0-9]+)\s*$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    foreach ($p in $normLine.Split(',')) {
        $seg = Sanitize-ConsoleInputLine $p
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        $mR = $rxRange.Match($seg)
        if ($mR.Success) {
            $a = [int]$mR.Groups[1].Value
            $b = [int]$mR.Groups[2].Value
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($i = $a; $i -le $b; $i++) {
                if ($i -ge 1 -and $i -le $max) { $indices.Add($i - 1) }
            }
            continue
        }
        $m1 = $rxOne.Match($seg)
        if ($m1.Success) {
            $v = [int]$m1.Groups[1].Value
            if ($v -ge 1 -and $v -le $max) { $indices.Add($v - 1) }
        }
    }
    return $indices
}

function Parse-ChapterInput {
    param([string]$InputStr, [hashtable]$ChapterNumToIndex)
    $indices = [System.Collections.Generic.List[int]]::new()
    $sortedChNums = @($ChapterNumToIndex.Keys | Sort-Object { [double]$_ })
    foreach ($p in $InputStr.Split(',')) {
        $trimmed = $p.Trim()
        if ($trimmed -match '^(\d+(?:\.\d+)?)\s*[-~]\s*(\d+(?:\.\d+)?)$') {
            $lo = [double]$Matches[1]; $hi = [double]$Matches[2]
            foreach ($chKey in $sortedChNums) {
                $chVal = [double]$chKey
                if ($chVal -ge $lo -and $chVal -le $hi) {
                    $idx = $ChapterNumToIndex[$chKey]
                    if (-not $indices.Contains($idx)) { $indices.Add($idx) }
                }
            }
        } elseif ($trimmed -match '^(\d+(?:\.\d+)?)$') {
            $ch = $Matches[1]
            if ($ChapterNumToIndex.ContainsKey($ch)) { 
                $idx = $ChapterNumToIndex[$ch]
                if (-not $indices.Contains($idx)) { $indices.Add($idx) }
            }
        }
    }
    return $indices
}

# STEP2 話数振り分け: 候補行 [1]..[N] をカンマ・ハイフン範囲で指定 → chapterPaths 配列上のインデックス
function Parse-Step2UiFolderSelection {
    param([string]$InputStr, [int[]]$UiToChapterPathIndex)
    if (-not $UiToChapterPathIndex -or $UiToChapterPathIndex.Count -eq 0) { return @() }
    $n = $UiToChapterPathIndex.Count
    $selUi = [System.Collections.Generic.List[int]]::new()
    foreach ($p in $InputStr.Split(',')) {
        $trimmed = $p.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match '^(\d+)\s*[-~～]\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            for ($u = $a; $u -le $b; $u++) {
                if ($u -ge 1 -and $u -le $n -and -not $selUi.Contains($u)) { [void]$selUi.Add($u) }
            }
        } elseif ($trimmed -match '^(\d+)$') {
            $u = [int]$Matches[1]
            if ($u -ge 1 -and $u -le $n -and -not $selUi.Contains($u)) { [void]$selUi.Add($u) }
        }
    }
    $chapterIdxOut = [System.Collections.Generic.List[int]]::new()
    foreach ($u in ($selUi | Sort-Object)) {
        [void]$chapterIdxOut.Add($UiToChapterPathIndex[$u - 1])
    }
    return @($chapterIdxOut)
}
