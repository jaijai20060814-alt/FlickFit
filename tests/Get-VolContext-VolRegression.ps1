#Requires -Version 7.0
<#
.SYNOPSIS
    Get-VolContext の巻抽出（Vol）の回帰確認用スタンドアロンスクリプト
.DESCRIPTION
    本体の処理に影響せず、dummy パス（...\_unpacked\<フォルダ名>）で Get-VolContext を呼び ExpectedVol と突き合わせる。
.NOTES
    UTF-8 保存・pwsh 前提。リポジトリルートからの相対または tests 直下から実行できる。
.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Get-VolContext-VolRegression.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Console]::OutputEncoding.WebName -notmatch '^utf') {
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath

# (?!) は「常に不一致」の .NET 正規表現。VolumeContext と同様、未定義や StrictMode 回避のプレースホルダとして使う。
$script:CoverFolderNameLikeRegex = '^(?i)(?:cover|表紙|カバー)\d*$|^[^\-_]+[-_](0|cover)$|^0+$'
$script:FlickFitRegexVolCtxCoverLine1 = '(?!)'
$script:FlickFitRegexVolCtxCoverLine2 = '(?!)'
$script:FlickFitRegexVolumeSourceFolderId = '(?!)'
$script:ImageExtensions = @('.jpg')

$utilsPath = Join-Path $RepoRoot 'Modules\Utils.ps1'
$volPath = Join-Path $RepoRoot 'Modules\VolumeContext.ps1'
if (-not (Test-Path -LiteralPath $utilsPath) -or -not (Test-Path -LiteralPath $volPath)) {
    Write-Host 'Modules（Utils.ps1 / VolumeContext.ps1）が見つかりません。リポジトリルート構成を確認してください。' -ForegroundColor Red
    exit 2
}

. $utilsPath
. $volPath

# STEP2 と同様の「_unpacked 直下のリーフ名」を想定したダミールート
$FakeUnpackedRoot = 'C:\_FlickFitVolRegression\_unpacked'

$Cases = @(
    @{ Leaf = 'ジョジョの奇妙な冒険 第1部 カラー版 01 [aKraa]' ; ExpectedVol = 1 }
    @{ Leaf = 'ジョジョの奇妙な冒険 第1部 カラー版 02 [aKraa]' ; ExpectedVol = 2 }
    @{ Leaf = 'ジョジョの奇妙な冒険 第 1 部 カラー版 03 [aKraa]' ; ExpectedVol = 3 }
    @{ Leaf = '作品名 第1巻' ; ExpectedVol = 1 }
    @{ Leaf = '作品名 第 2 巻' ; ExpectedVol = 2 }
    @{ Leaf = '作品名 vol.03' ; ExpectedVol = 3 }
    @{ Leaf = '作品名 Vol 04' ; ExpectedVol = 4 }
    @{ Leaf = '作品名 カラー版06' ; ExpectedVol = 6 }
    @{ Leaf = '作品名 完全版 05' ; ExpectedVol = 5 }
    @{ Leaf = '作品名 [第1巻]' ; ExpectedVol = 1 }
)

$failures = 0
foreach ($c in $Cases) {
    $path = Join-Path $FakeUnpackedRoot $c.Leaf
    $ctx = Get-VolContext -Path $path -SiblingChapterRatio -1
    $vol = $null
    if ($null -ne $ctx -and $ctx.PSObject.Properties['Vol']) { $vol = $ctx.Vol }

    $ok = ($null -ne $vol) -and ([int]$vol -eq [int]$c.ExpectedVol)
    if ($ok) {
        Write-Host ("[OK] '{0}' -> Vol={1} (Type={2})" -f $c.Leaf, $vol, $ctx.Type) -ForegroundColor Green
    }
    else {
        $failures++
        Write-Host ("[NG] '{0}' : expected Vol={1}, actual Vol={2}, Type={3}" -f $c.Leaf, $c.ExpectedVol, $(if ($null -eq $vol) { '(null)' } else { "$vol" }), $ctx.Type) -ForegroundColor Red
    }
}

if ($failures -gt 0) {
    Write-Host "`n失敗: $failures / $($Cases.Count)" -ForegroundColor Red
    exit 1
}

Write-Host "`nすべて成功 ($($Cases.Count) 件)" -ForegroundColor Green
exit 0
