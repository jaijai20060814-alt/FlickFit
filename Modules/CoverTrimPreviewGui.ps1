#Requires -Version 5.1
<#
.SYNOPSIS
    表紙トリミング結果の WinForms プレビュー（フォト等の既定アプリに依存しない）
    開いた時点でトリム後画像の四辺にガイド線を表示（Zoom 表示と一致）
#>

function Show-CoverTrimPreviewGui {
    param([string]$PreviewPath)
    if (-not $PreviewPath -or -not (Test-Path -LiteralPath $PreviewPath)) { return $null }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop | Out-Null
    } catch { return $null }

    $sel = [ordered]@{ Choice = "1" }
    $st = @{ ClosedByButton = $false }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "表紙トリミング結果の確認"
    $form.Size = New-Object System.Drawing.Size(980, 760)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MinimizeBox = $false

    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $pb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $pb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    try {
        $img = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $PreviewPath))
        $pb.Image = $img
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "画像を読み込めませんでした。`r`n" + $PreviewPath,
            "表紙確認",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        $form.Dispose()
        return $null
    }

    # Zoom と同じ縮尺で画像矩形を求め、四辺にガイド線（最初の表示から常時オン）
    $pb.Add_Paint({
        param($sender, $e)
        $im = $sender.Image
        if ($null -eq $im) { return }
        $cw = [int]$sender.ClientSize.Width
        $ch = [int]$sender.ClientSize.Height
        if ($cw -lt 2 -or $ch -lt 2) { return }
        $iw = [double]$im.Width
        $ih = [double]$im.Height
        if ($iw -lt 1 -or $ih -lt 1) { return }
        $ratio = [Math]::Min([double]$cw / $iw, [double]$ch / $ih)
        $dw = [int][Math]::Round($iw * $ratio)
        $dh = [int][Math]::Round($ih * $ratio)
        $dw = [Math]::Max(1, $dw)
        $dh = [Math]::Max(1, $dh)
        $ox = [int]([Math]::Floor(([double]$cw - $dw) / 2.0))
        $oy = [int]([Math]::Floor(([double]$ch - $dh) / 2.0))
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        try {
            $penL = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 220, 80), 2)
            $penR = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(100, 180, 255), 2)
            $penT = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 220, 120), 2)
            $penB = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 220, 120), 2)
            try {
                $g.DrawLine($penL, $ox, $oy, $ox, $oy + $dh - 1)
                $g.DrawLine($penR, $ox + $dw - 1, $oy, $ox + $dw - 1, $oy + $dh - 1)
                $g.DrawLine($penT, $ox, $oy, $ox + $dw - 1, $oy)
                $g.DrawLine($penB, $ox, $oy + $dh - 1, $ox + $dw - 1, $oy + $dh - 1)
            } finally {
                $penL.Dispose(); $penR.Dispose(); $penT.Dispose(); $penB.Dispose()
            }
        } catch { }
    })

    $pnl = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnl.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $pnl.Height = 56
    $pnl.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)
    $pnl.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $pnl.WrapContents = $false

    # Tag に選択値を入れ、クリック時は $sender.Tag を参照（$vCopy のスコープ／未設定エラーを避ける）
    $mkBtn = {
        param([string]$Label, [string]$Val)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Label
        $b.AutoSize = $true
        $b.Margin = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
        $b.Tag = $Val
        $b.Add_Click({
            param($sender, $e)
            $sel.Choice = [string]$sender.Tag
            $st.ClosedByButton = $true
            $form.Close()
        })
        return $b
    }

    $btnAdopt = & $mkBtn "採用 (1/Enter)" "1"
    $btnNext = & $mkBtn "次の画像 (2)" "2"
    $btnSplit = & $mkBtn "通常分割 (S)" "S"
    $btnDel = & $mkBtn "削除 (D)" "D"
    $btnCancel = & $mkBtn "キャンセル (N)" "N"

    [void]$pnl.Controls.Add($btnAdopt)
    [void]$pnl.Controls.Add($btnNext)
    [void]$pnl.Controls.Add($btnSplit)
    [void]$pnl.Controls.Add($btnDel)
    [void]$pnl.Controls.Add($btnCancel)

    $form.AcceptButton = $btnAdopt
    $form.CancelButton = $btnCancel

    $form.Add_FormClosing({
        param($_, $ev)
        if (-not $st.ClosedByButton) { $sel.Choice = "N" }
    })

    $form.Controls.Add($pb)
    $form.Controls.Add($pnl)

    $form.Add_Shown({
        param($_, $e)
        $pb.Invalidate()
    })

    try {
        [void]$form.ShowDialog()
        return [string]$sel.Choice
    } finally {
        if ($null -ne $pb.Image) {
            $pb.Image.Dispose()
            $pb.Image = $null
        }
        $form.Dispose()
    }
}
