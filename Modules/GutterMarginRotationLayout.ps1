#Requires -Version 5.1
<#
.SYNOPSIS
    ノドGUI「回転モード」用のレイアウト幾何のみ（WinForms 非依存）。
.DESCRIPTION
    画素の回転・保存は Modules\FlickFitImageRotate.ps1。こちらはプレビュー枠・つまみ位置の座標計算のみ。
    Show-GutterMarginSetGui はメインに残す（REFACTOR_ROADMAP Phase 2 未着手）が、幾何の正本はこのファイルに寄せる。
#>

function Get-GmRotFrameGeometry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$Iw0,
        [Parameter(Mandatory = $true)][double]$Ih0,
        [Parameter(Mandatory = $true)][double]$Scale,
        [Parameter(Mandatory = $true)][double]$OffX,
        [Parameter(Mandatory = $true)][double]$OffY,
        [Parameter(Mandatory = $true)][double]$AngleDegrees
    )
    if ($Iw0 -le 1 -or $Ih0 -le 1) { return $null }
    $sc = $Scale; $ox = $OffX; $oy = $OffY
    $cx = $ox + $Iw0 * $sc / 2.0
    $cy = $oy + $Ih0 * $sc / 2.0
    $rad = $AngleDegrees * [Math]::PI / 180.0
    $cos = [Math]::Cos($rad); $sin = [Math]::Sin($rad)
    $hx = $cx + ($Ih0 / 2.0) * $sin * $sc
    $hy = $cy - ($Ih0 / 2.0) * $cos * $sc
    $corners = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in @(@(-$Iw0 / 2.0, -$Ih0 / 2.0), @($Iw0 / 2.0, -$Ih0 / 2.0), @($Iw0 / 2.0, $Ih0 / 2.0), @(-$Iw0 / 2.0, $Ih0 / 2.0))) {
        $dx = [double]$pair[0]; $dy = [double]$pair[1]
        $rx = $dx * $cos - $dy * $sin
        $ry = $dx * $sin + $dy * $cos
        [void]$corners.Add([pscustomobject]@{ X = ($cx + $rx * $sc); Y = ($cy + $ry * $sc) })
    }
    [pscustomobject]@{
        Cx = $cx; Cy = $cy; Hx = $hx; Hy = $hy; Sc = $sc; Iw = $Iw0; Ih = $Ih0; Cos = $cos; Sin = $sin; Corners = $corners
    }
}

function Get-GmRotFrameDisplayPaddingPx {
    <#
    .SYNOPSIS
        StretchImage 表示（nw×nh px）に対し、同じ矩形を AngleDegrees だけ回転したときに
        軸平行外接矩形がはみ出す分の余白（各辺）。回転GUIでキャンバスを広げオレンジ枠を切らないために使用。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$DispW,
        [Parameter(Mandatory = $true)][double]$DispH,
        [Parameter(Mandatory = $true)][double]$AngleDegrees
    )
    if ($DispW -le 1 -or $DispH -le 1) {
        return @{ PadL = 0; PadR = 0; PadT = 0; PadB = 0; PadUniform = 0 }
    }
    $rad = $AngleDegrees * [Math]::PI / 180.0
    $c = [Math]::Cos($rad); $si = [Math]::Sin($rad)
    $cx = $DispW / 2.0; $cy = $DispH / 2.0
    $minX = [double]::PositiveInfinity; $maxX = [double]::NegativeInfinity
    $minY = [double]::PositiveInfinity; $maxY = [double]::NegativeInfinity
    foreach ($pair in @(@(-$DispW / 2.0, -$DispH / 2.0), @($DispW / 2.0, -$DispH / 2.0), @($DispW / 2.0, $DispH / 2.0), @(-$DispW / 2.0, $DispH / 2.0))) {
        $dx = [double]$pair[0]; $dy = [double]$pair[1]
        $rx = $dx * $c - $dy * $si
        $ry = $dx * $si + $dy * $c
        $px = $cx + $rx; $py = $cy + $ry
        if ($px -lt $minX) { $minX = $px }
        if ($px -gt $maxX) { $maxX = $px }
        if ($py -lt $minY) { $minY = $py }
        if ($py -gt $maxY) { $maxY = $py }
    }
    $padL = [Math]::Max(0, [int][Math]::Ceiling(-$minX))
    $padR = [Math]::Max(0, [int][Math]::Ceiling($maxX - $DispW))
    $padT = [Math]::Max(0, [int][Math]::Ceiling(-$minY))
    $padB = [Math]::Max(0, [int][Math]::Ceiling($maxY - $DispH))
    $pu = [Math]::Max([Math]::Max($padL, $padR), [Math]::Max($padT, $padB))
    return @{ PadL = $padL; PadR = $padR; PadT = $padT; PadB = $padB; PadUniform = $pu }
}

function Test-GmRotHandleHit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$ClientX,
        [Parameter(Mandatory = $true)][double]$ClientY,
        [Parameter(Mandatory = $true)]$Geometry
    )
    if ($null -eq $Geometry) { return $false }
    $scH = [double]$Geometry.Sc
    if ($scH -lt 0.0001) { $scH = 0.0001 }
    $baseR = 14.0 * [Math]::Max(1.0, $scH)
    $rPx = [Math]::Max(22.0, [Math]::Min(52.0, $baseR))
    $r2 = $rPx * $rPx
    $dx0 = $ClientX - [double]$Geometry.Hx; $dy0 = $ClientY - [double]$Geometry.Hy
    if (($dx0 * $dx0 + $dy0 * $dy0) -le $r2) { return $true }
    foreach ($cp in $Geometry.Corners) {
        $dx = $ClientX - [double]$cp.X; $dy = $ClientY - [double]$cp.Y
        if (($dx * $dx + $dy * $dy) -le $r2) { return $true }
    }
    return $false
}
