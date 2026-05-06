#Requires -Version 5.1
<#
.SYNOPSIS
    VolumePatternRules.txt（テキスト辞書）を解析し、巻数・話数判定前の前処理に使う。
.DESCRIPTION
    セクション: [ignore] [replace] [hint]（[regex] は将来用・現状は行を読むだけ破棄しない）
    行頭 # はコメント。replace は "左 => 右"（最初の => で分割）。**複数行は上から順にすべて適用**。
    本体の汎用ロジックに「追加」する。ファイルなし・空でも動作に影響しない。
#>

function Read-FlickFitVolumePatternRulesFile {
    param([Parameter(Mandatory)][string]$Path)
    $ignore = [System.Collections.Generic.List[string]]::new()
    $replace = [System.Collections.Generic.List[psobject]]::new()
    $hint   = [System.Collections.Generic.List[string]]::new()
    $regexExtra = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Ignore  = [string[]]@()
            Replace = [object[]]@()
            Hint    = [string[]]@()
            Regex   = [string[]]@()
        }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { [void]$lines.Add($_) }
    } catch {
        Write-Warning "VolumePatternRules.txt の読み込みに失敗しました。無視して続行: $($_.Exception.Message)"
        return [PSCustomObject]@{
            Ignore  = [string[]]@()
            Replace = [object[]]@()
            Hint    = [string[]]@()
            Regex   = [string[]]@()
        }
    }
    $section = 'none'
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t.StartsWith('#')) { continue }
        if ($t -match '^\[(\w+)\]\s*$') {
            $section = $Matches[1].ToLowerInvariant()
            continue
        }
        switch ($section) {
            'ignore' {
                if (-not [string]::IsNullOrWhiteSpace($t)) { [void]$ignore.Add($t) }
            }
            'replace' {
                $ix = $t.IndexOf('=>')
                if ($ix -lt 0) { continue }
                $L = $t.Substring(0, $ix).Trim()
                $R = $t.Substring($ix + 2).Trim()
                if ($L -ne '' -or $R -ne '') { [void]$replace.Add([pscustomobject]@{ From = $L; To = $R }) }
            }
            'hint' {
                if (-not [string]::IsNullOrWhiteSpace($t)) { [void]$hint.Add($t) }
            }
            'regex' {
                if (-not [string]::IsNullOrWhiteSpace($t)) { [void]$regexExtra.Add($t) }
            }
        }
    }
    return [PSCustomObject]@{
        Ignore  = @($ignore)
        Replace = @($replace)
        Hint    = @($hint)
        Regex   = @($regexExtra)
    }
}

function Merge-FlickFitVolumeTextRules {
    param(
        [psobject]$Into,
        [psobject]$From
    )
    if (-not $From) { return $Into }
    if (-not $Into) { return $From }
    $ignH = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ignList = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($Into.Ignore)) { if ($x -and $ignH.Add($x)) { [void]$ignList.Add($x) } }
    foreach ($x in @($From.Ignore)) { if ($x -and $ignH.Add($x)) { [void]$ignList.Add($x) } }
    $rep = [System.Collections.Generic.List[psobject]]::new()
    foreach ($o in @($Into.Replace)) { if ($null -ne $o) { [void]$rep.Add($o) } }
    foreach ($o in @($From.Replace)) { if ($null -ne $o) { [void]$rep.Add($o) } }
    $hintH = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hintL = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($Into.Hint)) { if ($x -and $hintH.Add($x)) { [void]$hintL.Add($x) } }
    foreach ($x in @($From.Hint))   { if ($x -and $hintH.Add($x)) { [void]$hintL.Add($x) } }
    $regH = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $regL = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($Into.Regex)) { if ($x -and $regH.Add($x)) { [void]$regL.Add($x) } }
    foreach ($x in @($From.Regex))  { if ($x -and $regH.Add($x)) { [void]$regL.Add($x) } }
    return [pscustomobject]@{
        Ignore  = @($ignList)
        Replace = @($rep)
        Hint    = @($hintL)
        Regex   = @($regL)
    }
}

function Initialize-FlickFitVolumeTextRules {
    param([string]$ProjectRoot = '')
    if ($ProjectRoot) { $script:FlickFitProjectRoot = $ProjectRoot }
    $script:FlickFitVolumeTextIgnoreList = @()
    $script:FlickFitVolumeTextReplaceList = [System.Collections.Generic.List[psobject]]::new()
    $script:FlickFitVolumeTextHintList = @()
    $script:FlickFitVolumeTextRegexList = @()
    if (-not $script:FlickFitProjectRoot) { return }
    $pBase = Join-Path $script:FlickFitProjectRoot 'VolumePatternRules.txt'
    $pLoc  = Join-Path $script:FlickFitProjectRoot 'VolumePatternRules.local.txt'
    $merged = $null
    if (Test-Path -LiteralPath $pBase) { $merged = Read-FlickFitVolumePatternRulesFile -Path $pBase }
    if (Test-Path -LiteralPath $pLoc) {
        $locP = Read-FlickFitVolumePatternRulesFile -Path $pLoc
        $merged = Merge-FlickFitVolumeTextRules -Into $merged -From $locP
    }
    if (-not $merged) { return }
    $script:FlickFitVolumeTextIgnoreList = if ($null -ne $merged.Ignore) { [string[]]@($merged.Ignore) } else { @() }
    if ($null -ne $merged.Replace) { foreach ($o in $merged.Replace) { [void]$script:FlickFitVolumeTextReplaceList.Add($o) } }
    $script:FlickFitVolumeTextHintList = if ($null -ne $merged.Hint) { [string[]]@($merged.Hint) } else { @() }
    $script:FlickFitVolumeTextRegexList = if ($null -ne $merged.Regex) { [string[]]@($merged.Regex) } else { @() }
}

function Test-FlickFitAnyScopeVerbose {
    for ($i = 0; $i -le 5; $i++) {
        try {
            $v = (Get-Variable -Name VerbosePreference -Scope $i -ErrorAction Stop).Value
            if ($v -eq 'Continue' -or $v -eq 'Inquire') { return $true }
        } catch { }
    }
    return $false
}

function Apply-FlickFitUserVolumeTextRules {
    param([string]$Text)
    if ($null -eq $Text) { return $Text }
    if ($null -eq $script:FlickFitVolumeTextIgnoreList) { $script:FlickFitVolumeTextIgnoreList = @() }
    if ($null -eq $script:FlickFitVolumeTextReplaceList) { $script:FlickFitVolumeTextReplaceList = [System.Collections.Generic.List[psobject]]::new() }
    $nIgn = 0
    if ($script:FlickFitVolumeTextIgnoreList) { $nIgn = @($script:FlickFitVolumeTextIgnoreList).Count }
    $nRep = if ($script:FlickFitVolumeTextReplaceList) { $script:FlickFitVolumeTextReplaceList.Count } else { 0 }
    if ($nIgn -eq 0 -and $nRep -eq 0) { return $Text }
    $s = $Text
    $verboseOn = (Test-FlickFitAnyScopeVerbose)
    foreach ($pair in $script:FlickFitVolumeTextReplaceList) {
        if ($null -eq $pair) { continue }
        $from = [string]$pair.From
        if ([string]::IsNullOrEmpty($from)) { continue }
        $to = if ($null -ne $pair.To) { [string]$pair.To } else { '' }
        try {
            $s = [regex]::Replace($s, [regex]::Escape($from), $to, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        } catch { }
    }
    foreach ($ig in $script:FlickFitVolumeTextIgnoreList) {
        if ([string]::IsNullOrWhiteSpace($ig)) { continue }
        try { $s = [regex]::Replace($s, [regex]::Escape($ig), '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) } catch { }
    }
    if ($verboseOn -and ($s -cne $Text)) {
        Write-Verbose ("[VolRules] before=" + $Text)
        Write-Verbose ("[VolRules] after="  + $s)
    }
    return $s
}
