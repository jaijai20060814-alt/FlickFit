#Requires -Version 5.1
<#
.SYNOPSIS
    見開き画像の回転（軸は水平・垂直のまま、ピクセルを回転し拡張キャンバスに配置）
.DESCRIPTION
    Show-GutterMarginSetGui の「回転モード」やバッチから dot-source 後に呼び出す。
    枠・つまみの座標計算のみは GutterMarginRotationLayout.ps1（画素処理と分離）。
    欠けは FillColor（既定: 白）で塗る。GUI 連携は呼び出し側で ApplyImagePath 等に渡す。Get-FlickFitRotatedBitmap はプレビュー用。
#>

# 回転後のキャンバス寸法（プレビュー計画用）
function Get-FlickFitRotatedCanvasSize {
    param(
        [int]$Width,
        [int]$Height,
        [double]$AngleDegrees
    )
    if ($Width -le 0 -or $Height -le 0) {
        return [pscustomobject]@{ Width = 0; Height = 0 }
    }
    $theta = [Math]::Abs($AngleDegrees) * [Math]::PI / 180.0
    $cos = [Math]::Abs([Math]::Cos($theta))
    $sin = [Math]::Abs([Math]::Sin($theta))
    [pscustomobject]@{
        Width  = [int]([Math]::Ceiling($Height * $sin + $Width * $cos))
        Height = [int]([Math]::Ceiling($Height * $cos + $Width * $sin))
    }
}

function Save-FlickFitBitmapToPath {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path
    )
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.png') {
        $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        return
    }
    if ($ext -eq '.jpg' -or $ext -eq '.jpeg') {
        $encoders = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()
        $jpegCodec = $null
        foreach ($enc in $encoders) {
            if ($enc.MimeType -eq 'image/jpeg') { $jpegCodec = $enc; break }
        }
        if ($null -eq $jpegCodec) {
            $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            return
        }
        $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
        try {
            $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                [System.Drawing.Imaging.Encoder]::Quality,
                [long]92
            )
            $Bitmap.Save($Path, $jpegCodec, $ep)
        } finally {
            try { $ep.Dispose() } catch {}
        }
        return
    }
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
}

<#
.SYNOPSIS
    メモリ上で回転画像を生成する（呼び出し側が Bitmap を破棄）
#>
function Get-FlickFitRotatedBitmap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$SourceImage,
        [double]$AngleDegrees = 0,
        [System.Drawing.Color]$FillColor = [System.Drawing.Color]::White
    )
    if ($null -eq $SourceImage) { throw "SourceImage が null です" }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $w = $SourceImage.Width
    $h = $SourceImage.Height
    if ($w -le 0 -or $h -le 0) { throw "画像サイズが無効です" }
    if ([Math]::Abs($AngleDegrees) -lt 0.01) {
        return New-Object System.Drawing.Bitmap($SourceImage)
    }
    $sz = Get-FlickFitRotatedCanvasSize -Width $w -Height $h -AngleDegrees $AngleDegrees
    $newW = [int]$sz.Width
    $newH = [int]$sz.Height
    if ($newW -le 0 -or $newH -le 0) { throw "回転後サイズが無効です" }
    $bmp = New-Object System.Drawing.Bitmap($newW, $newH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = $null
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear($FillColor)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.TranslateTransform([float]($newW / 2.0), [float]($newH / 2.0))
        $g.RotateTransform([float]$AngleDegrees)
        $g.TranslateTransform([float](-$w / 2.0), [float](-$h / 2.0))
        $g.DrawImage($SourceImage, 0, 0, $w, $h)
    } finally {
        if ($null -ne $g) { try { $g.Dispose() } catch {} }
    }
    return $bmp
}

<#
.SYNOPSIS
    画像を回転し、拡張キャンバスに FillColor で塗りつぶして保存する
.OUTPUTS
    [string] 保存した OutputPath（成功時）
#>
function Invoke-FlickFitImageRotateToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [double]$AngleDegrees = 0,
        [System.Drawing.Color]$FillColor = [System.Drawing.Color]::White
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "ソースが見つかりません: $SourcePath"
    }
    $resolved = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
    $normOut = [System.IO.Path]::GetFullPath($OutputPath)

    if ([Math]::Abs($AngleDegrees) -lt 0.01) {
        if (-not [string]::Equals($resolved, $normOut, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $resolved -Destination $normOut -Force
        }
        return $normOut
    }

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $src = $null
    $bmp = $null
    $g = $null
    try {
        $src = [System.Drawing.Image]::FromFile($resolved)
        $w = $src.Width
        $h = $src.Height
        if ($w -le 0 -or $h -le 0) { throw "画像サイズが無効です" }

        $sz = Get-FlickFitRotatedCanvasSize -Width $w -Height $h -AngleDegrees $AngleDegrees
        $newW = [int]$sz.Width
        $newH = [int]$sz.Height
        if ($newW -le 0 -or $newH -le 0) { throw "回転後サイズが無効です" }

        $bmp = New-Object System.Drawing.Bitmap($newW, $newH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear($FillColor)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

        $g.TranslateTransform([float]($newW / 2.0), [float]($newH / 2.0))
        $g.RotateTransform([float]$AngleDegrees)
        $g.TranslateTransform([float](-$w / 2.0), [float](-$h / 2.0))
        $g.DrawImage($src, 0, 0, $w, $h)

        try { $g.Dispose(); $g = $null } catch {}
        Save-FlickFitBitmapToPath -Bitmap $bmp -Path $normOut
        return $normOut
    } finally {
        if ($null -ne $g) { try { $g.Dispose() } catch {} }
        if ($null -ne $bmp) { try { $bmp.Dispose() } catch {} }
        if ($null -ne $src) { try { $src.Dispose() } catch {} }
    }
}
