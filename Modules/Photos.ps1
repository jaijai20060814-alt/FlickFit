#Requires -Version 5.1
<#
.SYNOPSIS
    FlickFit - フォト/画像ビューア連携
.DESCRIPTION
    画像を既定アプリ（フォト等）で開く
#>

function Invoke-PhotosOpen {
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    if (-not (Test-Path -LiteralPath $ImagePath)) {
        Write-FlickFitHost "  [手動調整] 画像が見つかりません: $ImagePath" -ForegroundColor Red
        return
    }
    Start-Process -FilePath $ImagePath
}
