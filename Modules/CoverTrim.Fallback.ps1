#Requires -Version 5.1
<#
.SYNOPSIS
    CoverTrim.ps1 が環境により dot-source できないときの代替（表記を最小化した同一ロジック）
    メインスクリプトに埋め込んでいたフォールバックを Modules に一本化したもの。
#>
function Get-FlickFitCoverTrimEdgeMaxFrac {
    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }
    if (-not (Test-Path -LiteralPath $ImagePath)) { return $null }
    if (-not $script:PythonExe) { return $null }
    $here = $PSScriptRoot
    if (-not $here -and $MyInvocation.MyCommand.Path) {
        try { $here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $here = $null }
    }
    if ([string]::IsNullOrWhiteSpace($here)) { return $null }
    $edgePy = Join-Path $here 'CoverTrimEdgePenalty.py'
    if (-not (Test-Path -LiteralPath $edgePy)) { return $null }
    try {
        $raw = & $script:PythonExe @($edgePy, $ImagePath) 2>$null
        $lastLine = ($raw | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
        if (-not $lastLine) { return $null }
        $parsed = $lastLine.Trim() -replace ',', '.'
        $dv = 0.0
        if ([double]::TryParse($parsed, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dv)) {
            return $dv
        }
    } catch { }
    return $null
}

function Get-CoverTrimScore {
    param(
        [string]$CropRes,
        [double]$CoverAspect,
        [int]$PixelWidth = 0,
        [int]$PixelHeight = 0,
        [int]$TypicalSinglePageWidth = 0,
        [double]$WideWidthFactor = 1.3,
        [int]$WidePortraitPenalty = 30,
        [bool]$SkipWidePortraitScorePenalty = $false,
        [string]$PreviewPath = '',
        [double]$EdgeContentFracThreshold = 0.035,
        [int]$EdgeContentPenaltyPoints = 14
    )
    $trimRate = 0.0
    if ($CropRes -match 'TRIM_RATE:([\d.]+)') { $trimRate = [double]$Matches[1] }
    if ($trimRate -lt 0.0001) { $trimRate = 0.0 }
    $score = 0
    if ($trimRate -eq 0) {
        if ($CoverAspect -lt 1.0) { $score = 100 } else { $score = 85 }
    } else {
        if ($trimRate -lt 0.03) { $score = 86 }
        elseif ($trimRate -lt 0.10) { $score = 55 }
        elseif ($trimRate -lt 0.20) { $score = 40 }
        else { $score = 25 }
    }
    $rot = $false
    if ($PixelWidth -gt 0 -and $PixelHeight -gt 0 -and $TypicalSinglePageWidth -gt 0 -and $CoverAspect -lt 1.0 -and $PixelWidth -le $PixelHeight) {
        if ($PixelWidth -gt [int]([double]$TypicalSinglePageWidth * $WideWidthFactor)) {
            $rot = $true
            if ($trimRate -eq 0 -and -not $SkipWidePortraitScorePenalty) { $score = [Math]::Max(0, $score - $WidePortraitPenalty) }
        }
    }
    $edgeMx = $null
    $edgePen = 0
    if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
        $edgeMx = Get-FlickFitCoverTrimEdgeMaxFrac -ImagePath $PreviewPath
        if ($null -ne $edgeMx -and $edgeMx -ge $EdgeContentFracThreshold) {
            $edgePen = $EdgeContentPenaltyPoints
        }
    }
    $score = [Math]::Max(0, $score - $edgePen)
    $trimCap = $null
    if ($CropRes -match 'TRIMMED:1') {
        $trimCap = if ($trimRate -ge 0.03) { 85 } else { 90 }
        $score = [Math]::Min($score, $trimCap)
    }
    return [PSCustomObject]@{
        TrimRate               = $trimRate
        Score                  = $score
        IsPortrait             = ($CoverAspect -lt 1.0)
        RotatedSpreadSuspect   = $rot
        EdgeContentMaxFrac     = $edgeMx
        EdgePenaltyApplied     = $edgePen
        TrimScoreCap           = $trimCap
    }
}

function Write-CoverTrimVerify {
    param([string]$OrigPath, [string]$PreviewPath, [bool]$UsedFallback)
    $origW = $null; $origH = $null; $previewW = $null; $previewH = $null
    if (-not $script:PythonExe) { return }
    try {
        $pyDim = "from PIL import Image; img=Image.open(r'$($OrigPath.Replace("'","''"))'); print(img.width,img.height)"
        $origDim = & $script:PythonExe -c $pyDim 2>$null
        if ($origDim -match '(\d+)\s+(\d+)') { $origW = [int]$Matches[1]; $origH = [int]$Matches[2] }
        $pyDim2 = "from PIL import Image; img=Image.open(r'$($PreviewPath.Replace("'","''"))'); print(img.width,img.height)"
        $previewDim = & $script:PythonExe -c $pyDim2 2>$null
        if ($previewDim -match '(\d+)\s+(\d+)') { $previewW = [int]$Matches[1]; $previewH = [int]$Matches[2] }
        $isTrimmed = ($null -ne $previewW) -and ($null -ne $origW) -and (($previewW -lt $origW - 10) -or ($previewH -lt $origH - 10))
        Write-FlickFitHost "         [検証] 元画像: ${origW}x${origH}  出力: ${previewW}x${previewH}  トリミング済=$isTrimmed  fallback=$UsedFallback" -ForegroundColor $(if ($isTrimmed) { "Green" } else { "Yellow" })
    } catch {
        Write-FlickFitHost "         [検証] サイズ取得エラー: $_" -ForegroundColor Red
    }
}

function Invoke-CoverTrimConfirm {
    param([string]$CropRes, [double]$CoverAspect, [string]$PreviewPath, [string]$OrigPath, [bool]$UsedFallback = $false)
    $si = Get-CoverTrimScore -CropRes $CropRes -CoverAspect $CoverAspect -PreviewPath $PreviewPath
    $coverScore = $si.Score
    $menuFb = '         [1/Enter] 採用  [2] 次の画像  [S] 通常分割  [D] 削除  [N] キャンセル'
    if ($CropRes -match 'TRIMMED:1') {
        Write-CoverTrimVerify -OrigPath $OrigPath -PreviewPath $PreviewPath -UsedFallback $UsedFallback
        Write-FlickFitHost "         [表紙スコア: $coverScore / 100]" -ForegroundColor Gray
        if ($coverScore -ge 90) {
            Write-FlickFitHost "         ✓ 自動トリミング（スコア90以上・自動採用）" -ForegroundColor Green
            return "1"
        }
        Write-FlickFitHost "         ✓ 自動トリミング完了（要確認）" -ForegroundColor Green
        Write-FlickFitHost "         （プレビューウィンドウで操作してください）" -ForegroundColor DarkGray
        $g = Show-CoverTrimPreviewGui -PreviewPath $PreviewPath
        if ($null -ne $g) { return $g }
        try { Start-Process $PreviewPath } catch { Write-FlickFitHost "         ⚠ 画像表示エラー" -ForegroundColor Yellow }
        Write-FlickFitHost $menuFb -ForegroundColor DarkGray
        return Read-HostWithEsc "         [確認]"
    }
    if ($si.IsPortrait) {
        Write-FlickFitHost "         [表紙スコア: $coverScore / 100]" -ForegroundColor Gray
        if ($true -eq $si.RotatedSpreadSuspect -or $coverScore -lt 90) {
            if ($true -eq $si.RotatedSpreadSuspect) {
                Write-FlickFitHost "         [警告] 短辺が本体幅より大きい縦向き（横見開き疑い）" -ForegroundColor Yellow
            }
            Write-FlickFitHost "         ✓ トリミング不要（横長・確認）" -ForegroundColor Green
            Write-FlickFitHost "         （プレビューウィンドウで操作してください）" -ForegroundColor DarkGray
            $g2 = Show-CoverTrimPreviewGui -PreviewPath $PreviewPath
            if ($null -ne $g2) { return $g2 }
            try { Start-Process $PreviewPath } catch { Write-FlickFitHost "         ⚠ 画像表示エラー" -ForegroundColor Yellow }
            Write-FlickFitHost $menuFb -ForegroundColor DarkGray
            return Read-HostWithEsc "         [確認]"
        }
        Write-FlickFitHost "         ✓ トリミング不要（縦長・自動採用）" -ForegroundColor Green
        return "1"
    }
    Write-FlickFitHost "         [表紙スコア: $coverScore / 100]" -ForegroundColor Gray
    if ($coverScore -ge 90) {
        Write-FlickFitHost "         ✓ トリミング不要（スコア90以上・自動採用）" -ForegroundColor Green
        return "1"
    }
    Write-FlickFitHost "         ✓ トリミング不要（横長・確認）" -ForegroundColor Green
    Write-FlickFitHost "         （プレビューウィンドウで操作してください）" -ForegroundColor DarkGray
    $g2 = Show-CoverTrimPreviewGui -PreviewPath $PreviewPath
    if ($null -ne $g2) { return $g2 }
    try { Start-Process $PreviewPath } catch { Write-FlickFitHost "         ⚠ 画像表示エラー" -ForegroundColor Yellow }
    Write-FlickFitHost $menuFb -ForegroundColor DarkGray
    return Read-HostWithEsc "         [確認]"
}
