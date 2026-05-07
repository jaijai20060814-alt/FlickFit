#Requires -Version 5.1
<#
.SYNOPSIS
    公開・共有時のログ・表示・出力ファイル名の安全化（UserConfig.PublicMode / NgWords）
.DESCRIPTION
    内部のパス比較・判定には使わず、Write-Host 直前やアーカイブ出力名にだけ適用する。
#>

$script:FlickFitPublicMode = $false
$script:FlickFitNgWordList = [string[]]@()

function Initialize-FlickFitPublicMode {
    $script:FlickFitPublicMode = $false
    $script:FlickFitNgWordList = @()
    if ($null -eq $script:UserConfig) { return }
    try {
        if ($null -ne $script:UserConfig.PublicMode) {
            $script:FlickFitPublicMode = [bool]$script:UserConfig.PublicMode
        }
    } catch { $script:FlickFitPublicMode = $false }
    $raw = $null
    try {
        if ($null -ne $script:UserConfig.NgWords) { $raw = $script:UserConfig.NgWords }
    } catch { $raw = $null }
    if ($null -eq $raw) { return }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($w in @($raw)) {
        $s = [string]$w
        if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$list.Add($s.Trim()) }
    }
    $script:FlickFitNgWordList = @($list)
}

# 文字列に NG ワードが含まれるか（部分一致・大文字小文字区別なし）
function Test-FlickFitNgWord {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $tl = $Text.ToLowerInvariant()
    foreach ($w in $script:FlickFitNgWordList) {
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        if ($tl.Contains($w.ToLowerInvariant())) { return $true }
    }
    return $false
}

# ファイル名・フォルダ名の表示・出力用（NG ワードを安全な文字に置換）
function Convert-FlickFitSafeName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    if (-not $script:FlickFitPublicMode) { return $Name }
    $n = $Name
    foreach ($w in $script:FlickFitNgWordList) {
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        try {
            $n = [regex]::Replace($n, [regex]::Escape($w), '_', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        } catch {
            $n = $n.Replace($w, '_')
        }
    }
    return $n
}

# 圧縮出力のベース名（巻フォルダ名）用。PublicMode 時のみ Convert-FlickFitSafeName を適用
function Convert-FlickFitSafeOutputBasename {
    param([string]$LeafName)
    if ([string]::IsNullOrEmpty($LeafName)) { return $LeafName }
    if (-not $script:FlickFitPublicMode) { return $LeafName }
    return (Convert-FlickFitSafeName -Name $LeafName)
}

# コンソールログ 1 行分: フルパス短縮・ユーザー名マスク
function Format-FlickFitPublicLogString {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if (-not $script:FlickFitPublicMode) { return $Text }
    $t = $Text
    $userProfilePath = [string]$env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($userProfilePath)) {
        try { $t = $t.Replace($userProfilePath, '~') } catch {}
    }
    foreach ($w in $script:FlickFitNgWordList) {
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        try {
            $t = [regex]::Replace($t, [regex]::Escape($w), '***', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        } catch {}
    }
    # UNC / Windows ドライブの絶対パスを伏せる（公開モード時のみ・内部判定には使わない）
    $maskToken = '[パス]'
    if (-not [string]::IsNullOrEmpty($t)) {
        try {
            # UNC は先頭が \\（\\nas01\share\…）。単一引用符では '\\' が regex に渡ると \ が1個なので、'\\\\' で「入力側の \\」にマッチする。
            $t = [regex]::Replace($t, '(?<![\w/\\])\\\\[^\s\r\n]+', $maskToken)
            # ドライブパスは →（U+2192）や行末まで。貪欲すぎると「パス → 続き」を続きごと消すので → 手前で切る。
            $t = [regex]::Replace($t, '(?<![\w/])[A-Za-z]:\\[^\r\n→]+', $maskToken)
        } catch {}
    }
    return $t
}
