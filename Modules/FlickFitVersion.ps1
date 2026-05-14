#Requires -Version 5.1
<#
.SYNOPSIS
    プロジェクト直下の VERSION ファイルからパッケージバージョン文字列を返す（正本）。
.DESCRIPTION
    FlickFit-Core.ps1 / FlickFitLauncher.ps1 と同じ階層に置いた VERSION を読み取ります。
    読み取れない場合は 'dev' を返し、起動を止めません。
#>
function Get-FlickFitVersion {
    [CmdletBinding()]
    param(
        # VERSION が置いてあるフォルダ（通常は FlickFit-Core.ps1 があるディレクトリ）
        [string]$PackageRoot = ''
    )
    $fallback = 'dev'
    try {
        $root = $PackageRoot
        if ([string]::IsNullOrWhiteSpace($root)) {
            $here = $PSScriptRoot
            if ([string]::IsNullOrWhiteSpace($here)) {
                $here = Split-Path -Parent $MyInvocation.MyCommand.Path
            }
            if ((Split-Path -Leaf $here) -eq 'Modules') {
                $root = Split-Path -Parent $here
            } else {
                $root = $here
            }
        }
        if ([string]::IsNullOrWhiteSpace($root)) { return $fallback }
        $verPath = Join-Path $root 'VERSION'
        if (-not (Test-Path -LiteralPath $verPath -PathType Leaf)) { return $fallback }
        $raw = Get-Content -LiteralPath $verPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $raw) { return $fallback }
        $v = [string]$raw.Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $fallback }
        return $v
    } catch {
        return $fallback
    }
}
