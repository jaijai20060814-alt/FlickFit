#Requires -Version 5.1
<#
.SYNOPSIS
    CoverTrim.ps1 を優先して dot-source し、失敗時は CoverTrim.Fallback.ps1 を試す。
    Load-Modules.ps1 とメインスクリプトの両方から同じ経路で呼ぶ。
    失敗理由は Write-Verbose（メインや Load-Modules に -Verbose を付けると表示）。
#>
$__coverTrimDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent }
$__coverTrimMain = Join-Path $__coverTrimDir 'CoverTrim.ps1'
$__coverTrimFb   = Join-Path $__coverTrimDir 'CoverTrim.Fallback.ps1'
$__coverTrimOk = $false
if (Test-Path -LiteralPath $__coverTrimMain) {
    try {
        . $__coverTrimMain
        if (Get-Command Invoke-CoverTrimConfirm -ErrorAction SilentlyContinue) { $__coverTrimOk = $true }
        else {
            Write-Verbose "[CoverTrimLoad] primary loaded but Invoke-CoverTrimConfirm missing: $__coverTrimMain"
        }
    } catch {
        Write-Verbose "[CoverTrimLoad] primary failed: $__coverTrimMain : $($_.Exception.Message)"
    }
} else {
    Write-Verbose "[CoverTrimLoad] primary script missing: $__coverTrimMain"
}
if (-not $__coverTrimOk -and (Test-Path -LiteralPath $__coverTrimFb)) {
    try {
        . $__coverTrimFb
    } catch {
        Write-Verbose "[CoverTrimLoad] fallback failed: $__coverTrimFb : $($_.Exception.Message)"
    }
} elseif (-not $__coverTrimOk) {
    Write-Verbose "[CoverTrimLoad] fallback script missing: $__coverTrimFb"
}
