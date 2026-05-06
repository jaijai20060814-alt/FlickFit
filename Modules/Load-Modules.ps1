#Requires -Version 5.1
<#
.SYNOPSIS
    漫画整理ツール - モジュール一括ロード
.DESCRIPTION
    依存順に Config -> VolumePatternRules.Parse -> VolumePatternOverrides.Load（Initialize）-> Utils -> VolumeContext を dot-source する
    メインスクリプトの先頭で . .\Modules\Load-Modules.ps1 を実行すること
    任意モジュールの dot-source 失敗は Write-Verbose（メインに -Verbose を付けると [LoadModules] が見える）
#>
# Load-Modules.ps1 は Modules フォルダ内にある前提
$ModulesDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$script:FlickFitProjectRoot = if ((Split-Path -Leaf $ModulesDir) -eq 'Modules') { Split-Path -Parent $ModulesDir } else { $ModulesDir }

. (Join-Path $ModulesDir "Config.ps1")
. (Join-Path $ModulesDir "VolumePatternRules.Parse.ps1")
. (Join-Path $ModulesDir "VolumePatternOverrides.Load.ps1")
Initialize-FlickFitVolumePatternOverrides -ProjectRoot $script:FlickFitProjectRoot
. (Join-Path $ModulesDir "Utils.ps1")
$p = Join-Path $ModulesDir "PublicMode.ps1"
try { . $p } catch { Write-Verbose "[LoadModules] failed: $p : $($_.Exception.Message)" }
. (Join-Path $ModulesDir "VolumeContext.ps1")
$p = Join-Path $ModulesDir "CoverTrimPreviewGui.ps1"; try { . $p } catch { Write-Verbose "[LoadModules] failed: $p : $($_.Exception.Message)" }
$p = Join-Path $ModulesDir "FlickFitImageRotate.ps1"; try { . $p } catch { Write-Verbose "[LoadModules] failed: $p : $($_.Exception.Message)" }
# ノドGUI回転モードの枠・ヒット幾何（GUI本体は未だメイン Show-GutterMarginSetGui 内）
$p = Join-Path $ModulesDir "GutterMarginRotationLayout.ps1"; try { . $p } catch { Write-Verbose "[LoadModules] failed: $p : $($_.Exception.Message)" }
# CoverTrim: CoverTrim.ps1 を優先し、パース失敗時は CoverTrim.Fallback.ps1（CoverTrim.Load.ps1 が切替）
$p = Join-Path $ModulesDir "CoverTrim.Load.ps1"; try { . $p } catch { Write-Verbose "[LoadModules] failed: $p : $($_.Exception.Message)" }
. (Join-Path $ModulesDir "Extract.ps1")
. (Join-Path $ModulesDir "Photos.ps1")
. (Join-Path $ModulesDir "Compression.ps1")

# ユーザー設定: Modules\UserConfig.json を既定、プロジェクト直下 UserConfig.json で上書き（浅いマージ・ルート優先）
function Merge-FlickFitUserConfigObject {
    param(
        [object]$Base,
        [object]$Overlay
    )
    if (-not $Overlay) { return $Base }
    if (-not $Base) { return $Overlay }
    $acc = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties) {
        if ($p.MemberType -ne 'NoteProperty') { continue }
        $acc[$p.Name] = $p.Value
    }
    foreach ($p in $Overlay.PSObject.Properties) {
        if ($p.MemberType -ne 'NoteProperty') { continue }
        $acc[$p.Name] = $p.Value
    }
    [pscustomobject]$acc
}

$script:UserConfig = $null
$modulesLeaf = Split-Path -Leaf $ModulesDir
if ($modulesLeaf -eq 'Modules') {
    $projRoot = Split-Path -Parent $ModulesDir
    $pathModulesCfg = Join-Path $ModulesDir 'UserConfig.json'
    $pathRootCfg = Join-Path $projRoot 'UserConfig.json'
} else {
    # Load-Modules.ps1 がプロジェクト直下にある場合: Modules\UserConfig.json をベース、直下 UserConfig.json で上書き
    $pathModulesCfg = Join-Path $ModulesDir 'Modules\UserConfig.json'
    $pathRootCfg = Join-Path $ModulesDir 'UserConfig.json'
}

try {
    if (Test-Path -LiteralPath $pathModulesCfg) {
        $script:UserConfig = Get-Content -LiteralPath $pathModulesCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if (Test-Path -LiteralPath $pathRootCfg) {
        $rootLayer = Get-Content -LiteralPath $pathRootCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:UserConfig = Merge-FlickFitUserConfigObject -Base $script:UserConfig -Overlay $rootLayer
    }
} catch {
    Write-FlickFitHost "  [警告] UserConfig.json の読み込みに失敗しました:" -ForegroundColor Yellow
    Write-FlickFitHost "    $($_.Exception.Message)" -ForegroundColor Red
    $script:UserConfig = $null
}
if (Get-Command Initialize-FlickFitPublicMode -ErrorAction SilentlyContinue) {
    try { Initialize-FlickFitPublicMode } catch {}
}
