#Requires -Version 5.1
<#
.SYNOPSIS
    FlickFit - 表紙トリミングモジュール
.DESCRIPTION
    表紙トリミングの採点・確認フローを提供する。
    TRIM_RATE のパース、スコア算出、自動採用/確認プロンプトの制御を行う。
    通常は CoverTrim.Load.ps1 経由で読み込む。事前に Config, Utils, CoverTrimPreviewGui を dot-source すること
#>

$lb = [char]0x5B; $rb = [char]0x5D
$script:CoverTrimMsgOkAuto = '         ' + $lb + 'OK' + $rb + ' 自動トリミング（スコア90以上・自動採用）'
$script:CoverTrimMsgOkDone = '         ' + $lb + 'OK' + $rb + ' 自動トリミング完了（要確認）'
$script:CoverTrimMsgOkPortrait = '         ' + $lb + 'OK' + $rb + ' トリミング不要（縦長・自動採用）'
$script:CoverTrimMsgOkNoTrim = '         ' + $lb + 'OK' + $rb + ' トリミング不要（スコア90以上・自動採用）'
$script:CoverTrimMsgOkLandscape = '         ' + $lb + 'OK' + $rb + ' トリミング不要（横長・確認）'
$script:CoverTrimMsgWarn = '         ' + $lb + '警告' + $rb + ' 画像表示エラー'

# Modules\CoverTrimEdgePenalty.py の結果（四辺帯のコンテンツ占有率の最大）。失敗時は $null
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
        # 表紙専用: 本文より短辺が広いのは当たり前なので、横見開き 90 度納品の減点をスコアに反映しない（警告は従来どおり出せる）
        [bool]$SkipWidePortraitScorePenalty = $false,
        # プレビュー画像パスがあれば外周帯の文字・線・着色を検出して減点（CoverTrimEdgePenalty.py）
        [string]$PreviewPath = '',
        [double]$EdgeContentFracThreshold = 0.035,
        # 既定14 → 端が忙しい縦表紙でも 100→86 付近になりやすく、自動採用（≥90）から外れやすい
        [int]$EdgeContentPenaltyPoints = 14
    )
    $trimRate = 0.0
    if ($CropRes -match 'TRIM_RATE:([\d.]+)') { $trimRate = [double]$Matches[1] }
    # 実質ゼロ（丸めノイズ）の TRIM_RATE は未トリムと同扱い
    if ($trimRate -lt 0.0001) { $trimRate = 0.0 }
    $score = 0
    if ($trimRate -eq 0) {
        if ($CoverAspect -lt 1.0) { $score = 100 } else { $score = 85 }
    } else {
        # 切り抜き率がごく小さい: 「ほぼ不要・わずかに切った」扱い（旧 70 はノートリム成功と不釣り合いになりやすい）
        if ($trimRate -lt 0.03) { $score = 86 }
        elseif ($trimRate -lt 0.10) { $score = 55 }
        elseif ($trimRate -lt 0.20) { $score = 40 }
        else { $score = 25 }
    }
    $rotatedSpreadSuspect = $false
    if ($PixelWidth -gt 0 -and $PixelHeight -gt 0 -and $TypicalSinglePageWidth -gt 0 -and $CoverAspect -lt 1.0 -and $PixelWidth -le $PixelHeight) {
        if ($PixelWidth -gt [int]([double]$TypicalSinglePageWidth * $WideWidthFactor)) {
            $rotatedSpreadSuspect = $true
            # STEP5「本文の見開き」向け。表紙では Skip して 100/85 を維持（実際は疑い注意のメッセージのみ）
            if ($trimRate -eq 0 -and -not $SkipWidePortraitScorePenalty) { $score = [Math]::Max(0, $score - $WidePortraitPenalty) }
        }
    }

    $edgeMaxFrac = $null
    $edgePenalty = 0
    if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
        $edgeMaxFrac = Get-FlickFitCoverTrimEdgeMaxFrac -ImagePath $PreviewPath
        if ($null -ne $edgeMaxFrac -and $edgeMaxFrac -ge $EdgeContentFracThreshold) {
            $edgePenalty = $EdgeContentPenaltyPoints
        }
    }
    $score = [Math]::Max(0, $score - $edgePenalty)

    # トリミング実行済みは「無加工で安全」の100点から外す（自動採用ライン90なら要確認に寄せる）
    $trimScoreCap = $null
    if ($CropRes -match 'TRIMMED:1') {
        $trimScoreCap = if ($trimRate -ge 0.03) { 85 } else { 90 }
        $score = [Math]::Min($score, $trimScoreCap)
    }

    return [PSCustomObject]@{
        TrimRate               = $trimRate
        Score                  = $score
        IsPortrait             = ($CoverAspect -lt 1.0)
        RotatedSpreadSuspect   = $rotatedSpreadSuspect
        EdgeContentMaxFrac     = $edgeMaxFrac
        EdgePenaltyApplied     = $edgePenalty
        TrimScoreCap           = $trimScoreCap
    }
}

function Write-CoverTrimVerify {
    param([string]$OrigPath, [string]$PreviewPath, [bool]$UsedFallback)
    $origW = $null; $origH = $null; $previewW = $null; $previewH = $null
    if (-not $script:PythonExe) { return }
    try {
        $safeOrig = $OrigPath.Replace("'", "''")
        $safePrev = $PreviewPath.Replace("'", "''")
        $pyDim = "from PIL import Image; img=Image.open(r'$safeOrig'); print(img.width,img.height)"
        $origDim = & $script:PythonExe -c $pyDim 2>$null
        if ($origDim -match '(\d+)\s+(\d+)') { $origW = [int]$Matches[1]; $origH = [int]$Matches[2] }
        $pyDim2 = "from PIL import Image; img=Image.open(r'$safePrev'); print(img.width,img.height)"
        $previewDim = & $script:PythonExe -c $pyDim2 2>$null
        if ($previewDim -match '(\d+)\s+(\d+)') { $previewW = [int]$Matches[1]; $previewH = [int]$Matches[2] }
        $isTrimmed = ($previewW -ne $null) -and ($origW -ne $null) -and (($previewW -lt $origW - 10) -or ($previewH -lt $origH - 10))
        $lb = [char]0x5B; $rb = [char]0x5D
        $msg = '         ' + $lb + '検証' + $rb + ' 元画像: ' + $origW + 'x' + $origH + '  出力: ' + $previewW + 'x' + $previewH + '  トリミング済=' + $isTrimmed + '  fallback=' + $UsedFallback
        Write-FlickFitHost $msg -ForegroundColor $(if ($isTrimmed) { "Green" } else { "Yellow" })
    } catch {
        $lb = [char]0x5B; $rb = [char]0x5D
        Write-FlickFitHost ('         ' + $lb + '検証' + $rb + ' サイズ取得エラー: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-CoverTrimConfirm {
    param([string]$CropRes, [double]$CoverAspect, [string]$PreviewPath, [string]$OrigPath, [bool]$UsedFallback = $false)
    $scoreInfo = Get-CoverTrimScore -CropRes $CropRes -CoverAspect $CoverAspect -PreviewPath $PreviewPath
    $coverScore = $scoreInfo.Score
    $lb = [char]0x5B; $rb = [char]0x5D
    $scoreMsg = '         ' + $lb + '表紙スコア: ' + $coverScore + ' / 100' + $rb
    $confirmPrompt = '         ' + $lb + '確認' + $rb
    $menuLine = '         ' + $lb + '1/Enter' + $rb + ' 採用  ' + $lb + '2' + $rb + ' 次の画像  ' + $lb + 'S' + $rb + ' 通常分割  ' + $lb + 'D' + $rb + ' 削除  ' + $lb + 'N' + $rb + ' キャンセル'

    if ($CropRes -match 'TRIMMED:1') {
        Write-CoverTrimVerify -OrigPath $OrigPath -PreviewPath $PreviewPath -UsedFallback $UsedFallback
        Write-FlickFitHost $scoreMsg -ForegroundColor Gray
        if ($coverScore -ge 90) {
            Write-FlickFitHost $script:CoverTrimMsgOkAuto -ForegroundColor Green
            return "1"
        }
        Write-FlickFitHost $script:CoverTrimMsgOkDone -ForegroundColor Green
        Write-FlickFitHost "         （プレビューウィンドウで操作してください）" -ForegroundColor DarkGray
        $guiAns = Show-CoverTrimPreviewGui -PreviewPath $PreviewPath
        if ($null -ne $guiAns) { return $guiAns }
        try { Start-Process $PreviewPath } catch { Write-FlickFitHost $script:CoverTrimMsgWarn -ForegroundColor Yellow }
        Write-FlickFitHost $menuLine -ForegroundColor DarkGray
        return Read-HostWithEsc $confirmPrompt
    }

    if ($scoreInfo.IsPortrait) {
        Write-FlickFitHost $scoreMsg -ForegroundColor Gray
        if ($true -eq $scoreInfo.RotatedSpreadSuspect) {
            Write-FlickFitHost "         $lb警告$rb 短辺が本体幅より大きい縦向き（横見開き 90 度納品の疑い）→ 確認してください" -ForegroundColor Yellow
        }
        if ($true -eq $scoreInfo.RotatedSpreadSuspect -or $scoreInfo.Score -lt 90) {
            Write-FlickFitHost $script:CoverTrimMsgOkLandscape -ForegroundColor Green
            Write-FlickFitHost "         （プレビューウィンドウで操作してください）" -ForegroundColor DarkGray
            $guiAns2 = Show-CoverTrimPreviewGui -PreviewPath $PreviewPath
            if ($null -ne $guiAns2) { return $guiAns2 }
            try { Start-Process $PreviewPath } catch { Write-FlickFitHost $script:CoverTrimMsgWarn -ForegroundColor Yellow }
            Write-FlickFitHost $menuLine -ForegroundColor DarkGray
            return Read-HostWithEsc $confirmPrompt
        }
        Write-FlickFitHost $script:CoverTrimMsgOkPortrait -ForegroundColor Green
        return "1"
    }

    Write-FlickFitHost $scoreMsg -ForegroundColor Gray
    if ($coverScore -ge 90) {
        Write-FlickFitHost $script:CoverTrimMsgOkNoTrim -ForegroundColor Green
        return "1"
    }
    Write-FlickFitHost $script:CoverTrimMsgOkLandscape -ForegroundColor Green
    Write-FlickFitHost "         （プレビューウィンドウで操作してください）" -ForegroundColor DarkGray
    $guiAns2 = Show-CoverTrimPreviewGui -PreviewPath $PreviewPath
    if ($null -ne $guiAns2) { return $guiAns2 }
    try { Start-Process $PreviewPath } catch { Write-FlickFitHost $script:CoverTrimMsgWarn -ForegroundColor Yellow }
    Write-FlickFitHost $menuLine -ForegroundColor DarkGray
    return Read-HostWithEsc $confirmPrompt
}
