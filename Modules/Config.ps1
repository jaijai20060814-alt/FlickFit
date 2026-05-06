#Requires -Version 5.1
<#
.SYNOPSIS
    漫画整理ツール - 設定・定数モジュール
.DESCRIPTION
    拡張子、外部ツールパス、その他定数を定義
#>
[CmdletBinding()]
param()

# 画像拡張子
$script:ImageExtensions   = @('.jpg', '.jpeg', '.webp', '.bmp', '.gif', '.avif')
# EPUB 解凍後など: 画像処理の対象外。検出したら警告のみ（コピー・実行はしない）
$script:FlickFitDangerousNonImageExtensions = @(
    '.exe', '.dll', '.bat', '.cmd', '.ps1', '.js', '.vbs', '.scr', '.com', '.msi', '.cpl', '.jse', '.wsh'
)
$script:ConvertExtensions = @('.tif', '.tiff', '.png', '.bpg', '.jxl')  # JPGに変換する画像形式
$script:ArchiveExtensions = @('.zip', '.rar', '.7z', '.cbz', '.cbr', '.se', '.epub')  # .se = 外枠アーカイブ
$script:BestRawName       = ""

# WinRAR（既定パス → レジストリ → PATH）
function Initialize-FlickFitWinRARPath {
    $cands = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(
            'C:\Program Files\WinRAR\WinRAR.exe',
            'C:\Program Files (x86)\WinRAR\WinRAR.exe'
        )) {
        if (Test-Path -LiteralPath $p) { [void]$cands.Add($p) }
    }
    foreach ($rk in @('HKLM:\SOFTWARE\WinRAR', 'HKCU:\SOFTWARE\WinRAR')) {
        try {
            $wr = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
            if ($wr) {
                foreach ($prop in @('exe64', 'exe32', 'ExePath', 'Path')) {
                    $v = $wr.$prop
                    if ($v -is [string] -and $v.Trim() -and (Test-Path -LiteralPath $v.Trim())) { [void]$cands.Add($v.Trim()) }
                }
            }
        } catch {}
    }
    try {
        $wc = Get-Command WinRAR.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wc -and $wc.Source -and (Test-Path -LiteralPath $wc.Source)) { [void]$cands.Add($wc.Source) }
    } catch {}
    $script:WinRAR = $cands | Select-Object -First 1
}
Initialize-FlickFitWinRARPath

# Python 候補を列挙し最初に動くものを $script:PythonExe に設定（メインから -Rescan で再実行可）
function Initialize-FlickFitPythonDetection {
    param([switch]$Rescan)
    if ($Rescan) { $script:PythonExe = $null }
    $script:PythonCandidatesForHelp = @()
    try {
        $allCands = [System.Collections.ArrayList]::new()
        function Add-PyCand([string]$p) {
            if ([string]::IsNullOrWhiteSpace($p)) { return }
            $x = $p.Trim().Trim('"')
            try { $x = [System.Environment]::ExpandEnvironmentVariables($x) } catch {}
            if ($x -and $x -notmatch 'WindowsApps' -and (Test-Path -LiteralPath $x) -and -not $allCands.Contains($x)) {
                [void]$allCands.Add($x)
            }
        }

        # 0. 環境変数（PATH が通っていなくても直指定できる）
        foreach ($evName in @('FLICKFIT_PYTHON', 'PYTHON', 'PYTHON_EXE')) {
            $ev = [Environment]::GetEnvironmentVariable($evName, 'Process')
            if (-not $ev) { $ev = [Environment]::GetEnvironmentVariable($evName, 'User') }
            if (-not $ev) { $ev = [Environment]::GetEnvironmentVariable($evName, 'Machine') }
            Add-PyCand $ev
        }

        # 1. py ランチャー → 実体の python.exe（PATH の py が古い・別環境でもこちらが確実なことが多い）
        $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pyLauncher -and $pyLauncher.Source) {
            try {
                $realPy = & $pyLauncher.Source -3 -c "import sys; print(sys.executable)" 2>$null
                if ($realPy) { Add-PyCand ([string]$realPy).Trim() }
            } catch {}
            Add-PyCand $pyLauncher.Source
        }

        # 2. レジストリ（Python Core InstallPath）
        foreach ($hive in @('HKLM', 'HKCU')) {
            $pyCore = "${hive}:\SOFTWARE\Python\PythonCore"
            if (-not (Test-Path -LiteralPath $pyCore)) { continue }
            Get-ChildItem -LiteralPath $pyCore -ErrorAction SilentlyContinue | ForEach-Object {
                $ip = Join-Path $_.PSPath 'InstallPath'
                if (-not (Test-Path -LiteralPath $ip)) { return }
                try {
                    $props = Get-ItemProperty -LiteralPath $ip -ErrorAction SilentlyContinue
                    if ($props.ExecutablePath) { Add-PyCand ([string]$props.ExecutablePath) }
                    $defDir = $props.'(default)'
                    if ($defDir -is [string] -and $defDir.Trim()) {
                        Add-PyCand (Join-Path $defDir.Trim() 'python.exe')
                    }
                } catch {}
            }
        }

        # 3. PATH経由（WindowsAppsのスタブは除外）
        foreach ($cmd in @('python', 'python3', 'py')) {
            $gcs = Get-Command $cmd -All -ErrorAction SilentlyContinue
            foreach ($gc in $gcs) {
                if (-not $gc.Source) { continue }
                $src = if ($gc.Source -match '\.exe$') { $gc.Source } else { (Get-Item -LiteralPath $gc.Source -ErrorAction SilentlyContinue).FullName }
                Add-PyCand $src
            }
        }

        # 4. よくあるインストール先
        $searchRoots = @(
            "$env:LOCALAPPDATA\Programs\Python",
            "$env:LOCALAPPDATA\Python",
            "$env:ProgramFiles\Python*",
            "${env:ProgramFiles(x86)}\Python*",
            "C:\Python*"
        )
        foreach ($root in $searchRoots) {
            $dirs = @(Get-Item -Path $root -ErrorAction SilentlyContinue)
            foreach ($d in $dirs) {
                Add-PyCand (Join-Path $d.FullName 'python.exe')
                Add-PyCand (Join-Path $d.FullName 'bin\python.exe')
            }
        }

        $script:PythonCandidatesForHelp = @($allCands)
        foreach ($c in $script:PythonCandidatesForHelp) {
            try {
                $ver = (& $c --version 2>&1) -join ''
                if ($ver -match 'Python\s+\d') { $script:PythonExe = $c; break }
            } catch { continue }
        }
    } catch {
        $script:PythonCandidatesForHelp = @()
    }
}
Initialize-FlickFitPythonDetection

# BPGデコーダー（Get-Command が複数返す場合は先頭のみ使用）
$script:BpgDec = @(
    'C:\Program Files\libbpg\bpgdec.exe',
    'C:\Program Files (x86)\libbpg\bpgdec.exe',
    (Join-Path $env:USERPROFILE 'bpgdec.exe'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'bpgdec.exe'),
    'bpgdec.exe'
) | Where-Object { 
    if ($_ -eq 'bpgdec.exe') { 
        $found = $null
        try {
            $c = Get-Command bpgdec.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c -and $c.Source) { $found = $c.Source }
        } catch {}
        return $found -and (Test-Path -LiteralPath $found)
    }
    Test-Path -LiteralPath $_ 
} | Select-Object -First 1

# 表紙フォルダ名（cover29 等）。メイン・VolumeContext・UI で $script:CoverFolderNameLikeRegex を参照（重複定義しない）
# Initialize-FlickFitVolumePatternOverrides が読込後に上書き（VolumePatternOverrides.json の cover_folder_name_tokens_extra を反映）
$script:CoverFolderNameLikeRegex = '^(?i)(?:cover|表紙|カバー)\d*$|^[^\-_]+[-_](0|cover)$|^0+$'

# Utils Read-HostWithEsc が参照（巻フォルダ自動処理タイマー）。未使用時は $null（Set-StrictMode 対策）
$script:FolderAutoTimer = $null

# dot-source 時に呼び出し元のスコープに変数を設定
