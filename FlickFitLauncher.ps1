#Requires -Version 5.1
# FlickFit Launcher v1.0.0 — 最小ランチャー（WinForms）。メインは別コンソールの PowerShell で起動する。
#
# 【メイン終了後にランチャーも落ちる問題の要点】旧来の「親から子 pwsh を直接 Process.Start」では子終了で親ランチャーが巻き込まれることがあった。
# 対策: 非表示 cmd を watcher とし、一時 .cmd 内で start "" /wait pwsh …（.cmd は UTF-8 BOM + 先頭 chcp 65001、日本語パス・引用符）。
# 完了検知: System.Windows.Forms.Timer の Poll（watcher の HasExited）のみ。次は使わない（.NET 別スレッドで PowerShell の
#   scriptblock が動き TLS が無い → PSInvalidOperation / ScriptBlock.GetContextFromTLS でホストが落ちうる）:
#   Process.add_Exited(scriptblock)・System.Threading.Timer(scriptblock)
# FlickFit-Core の -LauncherPid は Resolve-FileLock の保護用 PID（ランチャー停止のためではない）。
# 冗長トレース: 本ファイル内 $script:FlickFitLauncherTraceWatcherCmdBody / TraceWatcherDoneUiState / TracePostRestoreHeartbeat を $true。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Win32（フォーム復元・コンソール非表示。MainWindow ではなく GetConsoleWindow: ホスト conhost 用 HWND が取れる）
function Ensure-FlickFitLauncherWin32 {
    if (-not ([System.Management.Automation.PSTypeName]'FlickFitLauncherWin32').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FlickFitLauncherWin32 {
    public const int SW_HIDE = 0;
    public const int SW_RESTORE = 9;
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@ -ErrorAction Stop
    }
}

function Hide-FlickFitLauncherConsole {
    try {
        Ensure-FlickFitLauncherWin32
        $hwnd = [FlickFitLauncherWin32]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][FlickFitLauncherWin32]::ShowWindow($hwnd, [FlickFitLauncherWin32]::SW_HIDE)
        }
    } catch { }
}

# 起動直後に最速でコンソールを隠す。BAT の start 一瞬＋-WindowStyle Hidden より前倒し。取れなければ Shown で再試行
try { Hide-FlickFitLauncherConsole } catch { }

$script:RootDir = $PSScriptRoot
$script:LauncherTracePath = Join-Path $script:RootDir 'launcher_trace.log'
$script:EnginePs1 = Join-Path $script:RootDir 'FlickFit-Core.ps1'
$script:EngineProcess = $null
$script:EngineWatcherTempCmd = $null
$script:EngineWatcherTempDummyPs1 = $null
$script:EngineWatcherPollTimer = $null
$script:EngineWatcherCompletionDone = $false
$script:PostRestoreHeartbeatTimer = $null
$script:PostRestoreHeartbeatCount = 0
# $true: WatcherDone 後の Show / Activate / BringToFront / TopMost を行わない（前面復帰がクローズ原因かの切入り分け）
$script:FlickFitLauncherSkipPostRestoreForeground = $false
# $true: 完了後も一時 .cmd を削除しない（デバッグで中身を確認する用。パスはログ [WatcherCmd] file= に出る）
$script:FlickFitLauncherKeepWatcherCmdOnDisk = $false
# $true: launcher_trace に一時 .cmd の全行を出す（exitCode 切り分け用）。配布時は $false 推奨。
$script:FlickFitLauncherTraceWatcherCmdBody = $false
# $true: WatcherDone 直後に各コントロールの Enabled/Visible をトレース（切り分け用）
$script:FlickFitLauncherTraceWatcherDoneUiState = $false
# $true: メイン完了後に WinForms 心拍 tick 1〜10 をトレース（切り分け用）
$script:FlickFitLauncherTracePostRestoreHeartbeat = $false
# $true: Core 子プロセスにのみ -NoExit を付け、起動直後エラーをコンソールに残す。原因判明後は false。
$script:FlickFitLauncherDebugCoreChildNoExit = $false
# $true: ダミー子のみ起動（切り分け用）。通常は $false で Core を起動。
$script:FlickFitLauncherDebugDummyChild = $false

function Write-FlickFitLauncherTrace {
    param([string]$Message)
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $Message"
        Add-Content -LiteralPath $script:LauncherTracePath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
}

# グレー化・参照ボタン消失の切り分け用（コントロール参照はスクリプトスコープの $form / $txtFolder 等）
function Write-FlickFitLauncherTraceMainUiState {
    param([string]$Tag = 'UIState')
    $fmt = {
        param($Control, [string]$Name)
        if ($null -eq $Control) { return "$Name=<null>" }
        try {
            if ($Control.IsDisposed) { return "$Name=<disposed>" }
            return "$Name en=$($Control.Enabled) vis=$($Control.Visible)"
        } catch {
            return "$Name=<err $($_.Exception.Message)>"
        }
    }
    try {
        if ($null -eq $form) {
            Write-FlickFitLauncherTrace "[$Tag] form=<null>"
        } elseif ($form.IsDisposed) {
            Write-FlickFitLauncherTrace "[$Tag] form=<disposed>"
        } else {
            Write-FlickFitLauncherTrace "[$Tag] form en=$($form.Enabled) vis=$($form.Visible) state=$($form.WindowState)"
        }
        Write-FlickFitLauncherTrace "[$Tag] $( & $fmt $txtFolder 'txtFolder')"
        Write-FlickFitLauncherTrace "[$Tag] $( & $fmt $btnBrowse 'btnBrowse')"
        Write-FlickFitLauncherTrace "[$Tag] $( & $fmt $btnRun 'btnRun')"
        Write-FlickFitLauncherTrace "[$Tag] $( & $fmt $btnCheck 'btnCheck')"
        Write-FlickFitLauncherTrace "[$Tag] $( & $fmt $chkCleanupWorkingFolders 'chkCleanupWorkingFolders')"
        Write-FlickFitLauncherTrace "[$Tag] $( & $fmt $chkDeleteSourceArchives 'chkDeleteSourceArchives')"
    } catch { }
}

try {
    Write-FlickFitLauncherTrace "[Trace] path=$script:LauncherTracePath pid=$PID script=$PSCommandPath"
    Write-Host "launcher_trace.log: $script:LauncherTracePath"
} catch { }

function Open-FlickFitVolumeRuleLocalInEditor {
    $p = Join-Path $script:RootDir 'VolumePatternRules.local.txt'
    if (-not (Test-Path -LiteralPath $p)) {
        $base = Join-Path $script:RootDir 'VolumePatternRules.txt'
        if (Test-Path -LiteralPath $base) {
            try {
                Copy-Item -LiteralPath $base -Destination $p
            } catch { }
        }
        if (-not (Test-Path -LiteralPath $p)) {
            $t = @'
# VolumePatternRules.local.txt 個人向け。プロジェクトの VolumePatternRules.txt の次にマージされます。
# [ignore] / [replace] など。説明は VolumePatternRules.txt を参照。

'@
            try {
                [System.IO.File]::WriteAllText($p, $t, [System.Text.UTF8Encoding]::new($false))
            } catch { }
        }
    }
    if (-not (Test-Path -LiteralPath $p)) {
        [System.Windows.Forms.MessageBox]::Show(
            "ルール用ファイルの作成に失敗しました: $p",
            'FlickFit', 'OK', 'Error'
        )
        return
    }
    try {
        # ArgumentList を 1 要素に（空白を含むパス対策）
        Start-Process -FilePath (Join-Path $env:windir 'notepad.exe') -ArgumentList @($p)
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "メモ帳の起動に失敗: $($_.Exception.Message)",
            'FlickFit', 'OK', 'Error'
        )
    }
}

# 一時 .cmd を書き、cmd /c call で同期実行。親 cmd は非表示のまま、.cmd 内で start /wait して子 PS を別コンソールで表示する。
function Start-FlickFitEngineProcess {
    param(
        [Parameter(Mandatory)][string]$PsExe,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    function Local:QuoteBatchArg([string]$s) {
        if ($null -eq $s) { return '""' }
        # -File 等のスクリプトパスは空白がなくても .cmd 行では常に引用（将来のパス変更・トークン分割防止）
        if ($s -match '\.(?i)(ps1|psm1|cmd|bat)$') {
            return '"' + ($s -replace '"', '""') + '"'
        }
        # -TargetFolder 等、Windows パスは空白がなくても cmd の特別扱いで壊れうるので \ を含むものは常に引用
        if ($s -match '\\') {
            return '"' + ($s -replace '"', '""') + '"'
        }
        if ($s -notmatch '[\s^&|<>()%"]') { return $s }
        return '"' + ($s -replace '"', '""') + '"'
    }
    if ($script:EngineWatcherTempCmd -and (Test-Path -LiteralPath $script:EngineWatcherTempCmd) -and -not $script:FlickFitLauncherKeepWatcherCmdOnDisk) {
        try { Remove-Item -LiteralPath $script:EngineWatcherTempCmd -Force -ErrorAction SilentlyContinue } catch { }
    }
    $tempCmd = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        ('FFL_watch_{0}_{1}.cmd' -f $PID, [Guid]::NewGuid().ToString('N').Substring(0, 12)))
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('@echo off')
    # cmd は既定コードページが UTF-8 バッチと噛み合わないと日本語パス行が壊れる。UTF-8(BOM)+65001 で解釈を揃える
    [void]$lines.Add('chcp 65001 >nul 2>&1')
    [void]$lines.Add('setlocal')
    $wdQ = '"' + ($WorkingDirectory -replace '"', '""') + '"'
    [void]$lines.Add("cd /d $wdQ")
    $invokeParts = [System.Collections.Generic.List[string]]::new()
    [void]$invokeParts.Add((QuoteBatchArg $PsExe))
    foreach ($a in $Arguments) { [void]$invokeParts.Add((QuoteBatchArg $a)) }
    # 非表示 watcher cmd の子は既定で見えないため、.cmd 内だけ start /wait で別ウィンドウ化し、watcher は終了まで待つ
    [void]$lines.Add('start "" /wait ' + ($invokeParts -join ' '))
    [void]$lines.Add('exit /b %ERRORLEVEL%')
    # BOM 付き UTF-8: chcp 65001 行と整合（日本語を含む -File / -TargetFolder の行を確実に解釈させる）
    $enc = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllLines($tempCmd, $lines.ToArray(), $enc)
    $script:EngineWatcherTempCmd = $tempCmd

    try {
        Write-FlickFitLauncherTrace "[WatcherCmd] file=$tempCmd"
        if ($script:FlickFitLauncherTraceWatcherCmdBody) {
            foreach ($ln in $lines) {
                Write-FlickFitLauncherTrace "[WatcherCmd] | $ln"
            }
        }
        if ($script:FlickFitLauncherKeepWatcherCmdOnDisk) {
            Write-FlickFitLauncherTrace '[WatcherCmd] keepOnDisk=true（完了後もこの .cmd は削除されません）'
        }
    } catch { }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    # /s は /c 周りの引用符解釈を変え、call "...\.cmd" が壊れて即終了・変な errorlevel になることがあるため付けない
    $psi.Arguments = '/d /c call ' + (QuoteBatchArg $tempCmd)
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        return [System.Diagnostics.Process]::Start($psi)
    } catch {
        if (-not $script:FlickFitLauncherKeepWatcherCmdOnDisk) {
            if ($script:EngineWatcherTempCmd -and (Test-Path -LiteralPath $script:EngineWatcherTempCmd)) {
                try { Remove-Item -LiteralPath $script:EngineWatcherTempCmd -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        $script:EngineWatcherTempCmd = $null
        throw
    }
}

function Stop-FlickFitEngineWatcherTree {
    param([System.Diagnostics.Process]$Watcher)
    if ($null -eq $Watcher) { return }
    try {
        $wid = $Watcher.Id
        $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        if (Test-Path -LiteralPath $tk) {
            [void](& $tk /PID $wid /T /F 2>$null)
        }
    } catch { }
    try { if (-not $Watcher.HasExited) { $Watcher.Kill() } } catch { }
}

function Stop-FlickFitEngineWatcherPollTimer {
    if ($script:EngineWatcherPollTimer) {
        try {
            $script:EngineWatcherPollTimer.Stop()
            $script:EngineWatcherPollTimer.Dispose()
        } catch { }
        $script:EngineWatcherPollTimer = $null
    }
}

function Remove-FlickFitEngineWatcherTempCmd {
    if (-not $script:FlickFitLauncherKeepWatcherCmdOnDisk) {
        if ($script:EngineWatcherTempCmd -and (Test-Path -LiteralPath $script:EngineWatcherTempCmd)) {
            try { Remove-Item -LiteralPath $script:EngineWatcherTempCmd -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    $script:EngineWatcherTempCmd = $null
}

function Remove-FlickFitEngineWatcherTempDummyPs1 {
    if ($script:EngineWatcherTempDummyPs1 -and (Test-Path -LiteralPath $script:EngineWatcherTempDummyPs1)) {
        try { Remove-Item -LiteralPath $script:EngineWatcherTempDummyPs1 -Force -ErrorAction SilentlyContinue } catch { }
    }
    $script:EngineWatcherTempDummyPs1 = $null
}

function Stop-FlickFitPostRestoreHeartbeatTimer {
    param([string]$Reason = 'unspecified')
    $hadWin = $null -ne $script:PostRestoreHeartbeatTimer
    if ($hadWin -or $script:FlickFitLauncherTracePostRestoreHeartbeat) {
        try {
            Write-FlickFitLauncherTrace "[PostRestoreHeartbeat] Stop reason=$Reason hadWinForms=$hadWin"
        } catch { }
    }
    if ($hadWin) {
        try {
            $script:PostRestoreHeartbeatTimer.Stop()
            $script:PostRestoreHeartbeatTimer.Dispose()
        } catch { }
        $script:PostRestoreHeartbeatTimer = $null
    }
    $script:PostRestoreHeartbeatCount = 0
}

# WatcherDone->UI 直後から 1 秒間隔でログし、数秒後の異常終了が前面復帰より前か後かを切り分ける
function Start-FlickFitPostRestoreHeartbeat {
    try {
        try { Write-FlickFitLauncherTrace '[PostRestoreHeartbeat] start' } catch { }

        Stop-FlickFitPostRestoreHeartbeatTimer -Reason 'Start-clear-before-schedule'

        $script:PostRestoreHeartbeatCount = 0
        $script:PostRestoreHeartbeatTimer = New-Object System.Windows.Forms.Timer
        $script:PostRestoreHeartbeatTimer.Interval = 1000

        $script:PostRestoreHeartbeatTimer.Add_Tick({
            try {
                $script:PostRestoreHeartbeatCount++

                $disposed = $false
                $visible = $false
                $state = '<unknown>'

                try { $disposed = [bool]$form.IsDisposed } catch { }
                try { $visible = [bool]$form.Visible } catch { }
                try { $state = [string]$form.WindowState } catch { }

                Write-FlickFitLauncherTrace "[PostRestoreHeartbeat] tick=$($script:PostRestoreHeartbeatCount)/10 formDisposed=$disposed visible=$visible windowState=$state"

                if ($script:PostRestoreHeartbeatCount -ge 10 -or $disposed) {
                    Stop-FlickFitPostRestoreHeartbeatTimer -Reason 'WinForms-tick-done-or-disposed'
                    try { Write-FlickFitLauncherTrace '[PostRestoreHeartbeat] done' } catch { }
                }
            } catch {
                try {
                    Write-FlickFitLauncherTrace "[PostRestoreHeartbeat] tick error: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
                } catch { }
                Stop-FlickFitPostRestoreHeartbeatTimer -Reason 'WinForms-tick-error'
            }
        })

        try { Write-FlickFitLauncherTrace '[PostRestoreHeartbeat] calling Timer.Start()' } catch { }
        $script:PostRestoreHeartbeatTimer.Start()
        try { Write-FlickFitLauncherTrace '[PostRestoreHeartbeat] Timer.Start() returned' } catch { }
    } catch {
        try {
            Write-FlickFitLauncherTrace "[PostRestoreHeartbeat] init error: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        } catch { }
        throw
    }
}

# WinForms Timer の Poll のみで watcher(cmd) 完了を検知（Process.Exited は別スレッドで scriptblock が TLS 無しとなり落ちうるため使わない）
function Complete-FlickFitEngineWatcher {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Watcher
    )
    if ($null -eq $form) { return }
    if ($form.InvokeRequired) {
        [void]$form.BeginInvoke([System.Windows.Forms.MethodInvoker] {
            Complete-FlickFitEngineWatcher -Watcher $Watcher
        })
        return
    }
    if ($script:EngineWatcherCompletionDone) { return }
    $script:EngineWatcherCompletionDone = $true

    Stop-FlickFitEngineWatcherPollTimer
    Remove-FlickFitEngineWatcherTempCmd
    Remove-FlickFitEngineWatcherTempDummyPs1

    $code = -1
    try { $Watcher.Refresh(); $code = $Watcher.ExitCode } catch { }
    $wPid = $Watcher.Id

    try { Write-FlickFitLauncherTrace "[WatcherDone] source=Poll watcher(cmd) pid=$wPid exitCode=$code (.cmd 内 start/wait ・子は別コンソール)" } catch { }
    try {
        Add-FlickFitLogLine "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') メイン終了（待機完了・終了コード: $code） ==="
        Add-FlickFitLogLine ''
    } catch { }

    if ($script:EngineProcess -and $script:EngineProcess.Id -eq $wPid) {
        $script:EngineProcess = $null
    }
    if ($form.IsDisposed) { return }

    try {
        if ($lblRunStatus -and -not $lblRunStatus.IsDisposed) {
            $lblRunStatus.Text = "完了（終了コード: $code）次の作品を選べます"
        }
        Set-FlickFitLauncherRunMode -Running $false
        if ($script:FlickFitLauncherTraceWatcherDoneUiState) {
            try { Write-FlickFitLauncherTraceMainUiState -Tag 'UIStateAfterRunMode' } catch { }
        }

        if (-not $script:FlickFitLauncherSkipPostRestoreForeground) {
            # Activate / BringToFront / TopMost は環境によって前面状態を壊すことがあるため使わない
            if (-not $form.IsDisposed) {
                $form.Enabled = $true
                if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                }
                $form.Show()
                try {
                    $null = $form.Focus()
                    if ($txtFolder -and -not $txtFolder.IsDisposed) {
                        $form.ActiveControl = $txtFolder
                    }
                } catch { }
            }
        } else {
            try { Write-FlickFitLauncherTrace '[WatcherDone->UI] foreground restore skipped (FlickFitLauncherSkipPostRestoreForeground=true)' } catch { }
        }

        if ($script:FlickFitLauncherTraceWatcherDoneUiState) {
            try { Write-FlickFitLauncherTraceMainUiState -Tag 'UIStateAfterForegroundOrSkip' } catch { }
        }

        Write-FlickFitLauncherTrace '[WatcherDone->UI] run mode off / launcher restored'
        if ($script:FlickFitLauncherTracePostRestoreHeartbeat) {
            try { Write-FlickFitLauncherTrace '[WatcherDone->UI] invoking Start-FlickFitPostRestoreHeartbeat' } catch { }
            try {
                Start-FlickFitPostRestoreHeartbeat
            } catch {
                try { Write-FlickFitLauncherTrace "[WatcherDone->UI] Start-FlickFitPostRestoreHeartbeat failed: $($_.Exception.Message)" } catch { }
            }
        }
    } catch {
        try { Add-FlickFitLogLine "[Launcher][WatcherDone->UI] $($_.Exception.Message)" } catch { }
    }
}

function Get-FlickFitPwshPath {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $same = Join-Path $PSHOME 'pwsh.exe'
        if (Test-Path -LiteralPath $same) { return $same }
    }
    $g = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g -and $g.Source -and (Test-Path -LiteralPath $g.Source)) { return $g.Source }
    return $null
}

# ルート直下を優先し、無ければ Modules（メイン・Modules\Config.ps1 と同じ探索順）
function Get-FlickFitUserConfigPath {
    foreach ($rel in @('UserConfig.json', 'Modules\UserConfig.json')) {
        $p = Join-Path $script:RootDir $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-FlickFitUserConfigPathForWrite {
    $ex = Get-FlickFitUserConfigPath
    if ($ex) { return $ex }
    return (Join-Path $script:RootDir 'UserConfig.json')
}

function Read-FlickFitUserConfigObject {
    $p = Get-FlickFitUserConfigPath
    if (-not $p) { return $null }
    try {
        return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

function Write-FlickFitUserConfigObject {
    param(
        [Parameter(Mandatory)][psobject]$ConfigObject
    )
    $p = Get-FlickFitUserConfigPathForWrite
    $json = $ConfigObject | ConvertTo-Json -Depth 20
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($p, $json, $enc)
}

# ランチャー「詳細オプション…」等: ルートに必ず書く（Modules だけに UserConfig がある場合の上書き先を統一）
function Write-FlickFitUserConfigObjectToRoot {
    param(
        [Parameter(Mandatory)][psobject]$ConfigObject
    )
    $p = Join-Path $script:RootDir 'UserConfig.json'
    $json = $ConfigObject | ConvertTo-Json -Depth 20
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($p, $json, $enc)
}

function Get-FlickFitStep7CleanupSummaryJa {
    $j = Read-FlickFitUserConfigObject
    $w = $true
    $k = $true
    if ($j) {
        if ($null -ne $j.CleanupWorkingFolders) { $w = [bool]$j.CleanupWorkingFolders }
        if ($null -ne $j.KeepSourceArchives) { $k = [bool]$j.KeepSourceArchives }
    }
    $ws = if ($w) { '作業フォルダ削除=既定「はい」' } else { '作業フォルダ削除=既定「いいえ」' }
    # KeepSourceArchives true = 解凍元を残す
    $ks = if ($k) { '解凍元=保持' } else { '解凍元=ごみ箱へ移動可' }
    return "$ws / $ks"
}

function Save-FlickFitStep7CleanupToUserConfig {
    param([bool]$CleanupWorkingFolders, [bool]$KeepSourceArchives)
    $j = Read-FlickFitUserConfigObject
    if (-not $j) { $j = ('{}' | ConvertFrom-Json) }
    $j | Add-Member -NotePropertyName 'CleanupWorkingFolders' -NotePropertyValue $CleanupWorkingFolders -Force
    $j | Add-Member -NotePropertyName 'KeepSourceArchives' -NotePropertyValue $KeepSourceArchives -Force
    Write-FlickFitUserConfigObject -ConfigObject $j
}

function Get-FlickFitAutoJudgeSummaryJa {
    $j = Read-FlickFitUserConfigObject
    if (-not $j -or ($j.PSObject.Properties.Name -notcontains 'AutoJudge') -or -not $j.AutoJudge) { return '標準（おすすめ）' }
    $aj = $j.AutoJudge
    $pre = 'standard'
    if ($aj.PSObject.Properties.Name -contains 'Preset' -and -not [string]::IsNullOrWhiteSpace([string]$aj.Preset)) { $pre = [string]$aj.Preset.Trim() }
    switch -Regex ($pre) {
        '^(?i)lenient' { return 'やや甘め' }
        '^(?i)custom' { return 'カスタム' }
        '^(?i)standard' { return '標準（おすすめ）' }
    }
    return "標準 ($pre)"
}

function Get-FlickFitNormalizedCompressionFormat {
    param([object]$ConfigObject = $null)
    $v = 'CBZ'
    if (
        $ConfigObject -and
        ($ConfigObject.PSObject.Properties.Name -contains 'CompressionFormat') -and
        $null -ne $ConfigObject.CompressionFormat
    ) {
        $raw = [string]$ConfigObject.CompressionFormat
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $v = $raw }
    }
    $v = $v.Trim().ToUpperInvariant()
    if ($v -notin @('CBZ', 'ZIP', 'RAR')) { $v = 'CBZ' }
    return $v
}

function Get-FlickFitLoadModulesPath {
    foreach ($rel in @('Load-Modules.ps1', 'Modules\Load-Modules.ps1')) {
        $p = Join-Path $script:RootDir $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-FlickFitRelativeToRootDisplay {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
    $root = $script:RootDir.TrimEnd('\')
    $fp = $FullPath.TrimEnd('\')
    if ($fp.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $fp.Substring($root.Length).TrimStart('\')
    }
    return $FullPath
}

function Get-FlickFitUserConfigPythonExe {
    $cfgPath = Get-FlickFitUserConfigPath
    if (-not $cfgPath) { return $null }
    try {
        $j = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not ($j.PSObject.Properties.Name -contains 'PythonExe')) { return $null }
        $p = [string]$j.PythonExe
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        $p = [System.Environment]::ExpandEnvironmentVariables($p.Trim().Trim('"'))
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    return $null
}

function Get-FlickFitUserConfigPythonExeDisplay {
    $cfgPath = Get-FlickFitUserConfigPath
    if (-not $cfgPath) { return 'UserConfig.json なし — 自動検出を使用' }
    $ok = Get-FlickFitUserConfigPythonExe
    if ($ok) { return $ok }
    try {
        $j = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'PythonExe' -and $j.PythonExe -and [string]$j.PythonExe.Trim()) {
            return '記載の PythonExe が見つかりません: ' + [string]$j.PythonExe
        }
    } catch { }
    return '未指定（自動検出を使用）'
}

# Modules\Config.ps1 の Initialize-FlickFitPythonDetection と同じ考え方で候補を列挙（メインと揃える）
function Get-FlickFitPythonCandidatePaths {
    $ordered = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $x = $p.Trim().Trim('"')
        try { $x = [Environment]::ExpandEnvironmentVariables($x) } catch { }
        if (-not $x -or $x -match 'WindowsApps') { return }
        if (-not (Test-Path -LiteralPath $x)) { return }
        if ($seen.Add($x)) { [void]$ordered.Add($x) }
    }

    foreach ($evName in @('FLICKFIT_PYTHON', 'PYTHON', 'PYTHON_EXE')) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            try {
                $ev = [Environment]::GetEnvironmentVariable($evName, $scope)
                if ($ev) { & $add ([Environment]::ExpandEnvironmentVariables($ev.Trim().Trim('"'))) }
            } catch { }
        }
    }
    & $add (Get-FlickFitUserConfigPythonExe)

    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pyLauncher -and $pyLauncher.Source) {
        $src = $pyLauncher.Source
        $rawPy = Invoke-FlickFitExeWithTimeout -FilePath $src -Arguments '-3 -c "import sys; print(sys.executable)"' -TimeoutMs 6000
        if ($rawPy -and $rawPy -ne 'TIMEOUT') {
            $line = ($rawPy -split "`r?`n")[0].Trim()
            if ($line -and (Test-Path -LiteralPath $line)) { & $add $line }
        }
        & $add $src
    }

    foreach ($hive in @('HKLM', 'HKCU')) {
        $pyCore = "${hive}:\SOFTWARE\Python\PythonCore"
        if (-not (Test-Path -LiteralPath $pyCore)) { continue }
        Get-ChildItem -LiteralPath $pyCore -ErrorAction SilentlyContinue | ForEach-Object {
            $ip = Join-Path $_.PSPath 'InstallPath'
            if (Test-Path -LiteralPath $ip) {
                try {
                    $props = Get-ItemProperty -LiteralPath $ip -ErrorAction SilentlyContinue
                    if ($props.ExecutablePath) { & $add ([string]$props.ExecutablePath) }
                    $defDir = $props.'(default)'
                    if ($defDir -is [string] -and $defDir.Trim()) {
                        & $add (Join-Path $defDir.Trim() 'python.exe')
                    }
                } catch { }
            }
        }
    }

    foreach ($cmd in @('python', 'python3', 'py')) {
        $gcs = Get-Command $cmd -All -ErrorAction SilentlyContinue
        foreach ($gc in $gcs) {
            if (-not $gc.Source) { continue }
            $src = if ($gc.Source -match '\.exe$') { $gc.Source } else {
                try { (Get-Item -LiteralPath $gc.Source -ErrorAction SilentlyContinue).FullName } catch { $null }
            }
            if ($src) { & $add $src }
        }
    }

    $searchRoots = @(
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:LOCALAPPDATA\Python",
        "$env:ProgramFiles\Python*",
        "${env:ProgramFiles(x86)}\Python*",
        'C:\Python*'
    )
    foreach ($root in $searchRoots) {
        $dirs = @(Get-Item -Path $root -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            & $add (Join-Path $d.FullName 'python.exe')
            & $add (Join-Path $d.FullName 'bin\python.exe')
        }
    }

    return $ordered
}

function Invoke-FlickFitExeWithTimeout {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutMs = 4000
    )
    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    } catch { }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
    } catch {
        return $null
    }
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill($true) } catch { }
        return 'TIMEOUT'
    }
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    return ($out + $err).Trim()
}

function Test-FlickFitPythonAvailable {
    foreach ($exe in @(Get-FlickFitPythonCandidatePaths)) {
        $arg = '--version'
        if ($exe -match '[\\/]py\.exe$') { $arg = '-3 --version' }
        $raw = Invoke-FlickFitExeWithTimeout -FilePath $exe -Arguments $arg -TimeoutMs 4500
        if ($raw -eq 'TIMEOUT') { continue }
        if ($raw -and $raw -match 'Python\s+\d') {
            $line = ($raw -split "`r?`n")[0].Trim()
            return @{ Ok = $true; Detail = $line; Path = $exe }
        }
    }
    return @{
        Ok     = $false
        Detail = @(
            'Python を検出できませんでした（Modules\Config.ps1 と同様の候補を試しました）。',
            '対処: (1) python.org からインストール',
            '(2) UserConfig.json（ルート直下または Modules）の "PythonExe" に python.exe のフルパス',
            '(3) 環境変数 FLICKFIT_PYTHON',
            '※ WindowsApps のスタブのみの場合は実体の python.exe を上記で指定してください。'
        ) -join [Environment]::NewLine
        Path   = $null
    }
}

function Test-FlickFitWinRARAvailable {
    foreach ($p in @(
            'C:\Program Files\WinRAR\WinRAR.exe',
            'C:\Program Files (x86)\WinRAR\WinRAR.exe'
        )) {
        if (Test-Path -LiteralPath $p) { return @{ Ok = $true; Detail = $p } }
    }
    try {
        $wc = Get-Command WinRAR.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wc -and $wc.Source -and (Test-Path -LiteralPath $wc.Source)) {
            return @{ Ok = $true; Detail = $wc.Source }
        }
    } catch { }
    return @{ Ok = $false; Detail = 'WinRAR が見つかりません（圧縮出力に必要）' }
}

function Test-FlickFitTargetFolder {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ Ok = $false; Detail = 'フォルダが空です' }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Ok = $false; Detail = 'パスが存在しません' }
    }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            return @{ Ok = $false; Detail = 'フォルダではなくファイルです' }
        }
    } catch {
        return @{ Ok = $false; Detail = "アクセスできません: $($_.Exception.Message)" }
    }
    return @{ Ok = $true; Detail = 'OK' }
}

function Get-FlickFitEnvReport {
    $py = Test-FlickFitPythonAvailable
    $wr = Test-FlickFitWinRARAvailable
    $pwsh = Get-FlickFitPwshPath
    $lmPath = Get-FlickFitLoadModulesPath
    $lmDisp = if ($lmPath) {
        'あり — ' + (Get-FlickFitRelativeToRootDisplay $lmPath)
    } else {
        'なし（メイン内フォールバック）'
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('=== 初回チェック / 環境 ===')
    [void]$lines.Add(('起動用 PowerShell: {0}' -f $(if ($pwsh) { $pwsh } else { 'pwsh 未検出（Windows PowerShell で起動します）' })))
    [void]$lines.Add(('PythonExe 設定: {0}' -f (Get-FlickFitUserConfigPythonExeDisplay)))
    [void]$lines.Add(('Python 実行: {0} — {1}' -f ($(if ($py.Ok) { 'OK' } else { '要対応' })), ($py.Detail -replace "`r`n", ' / ')))
    [void]$lines.Add(('WinRAR: {0} — {1}' -f ($(if ($wr.Ok) { 'OK' } else { '要対応' })), $wr.Detail))
    [void]$lines.Add(('Load-Modules.ps1: {0}' -f $lmDisp))
    [void]$lines.Add('')
    [void]$lines.Add('メインスクリプト: ' + $(if (Test-Path -LiteralPath $script:EnginePs1) { '見つかりました' } else { '見つかりません（配置を確認）' }))
    [void]$lines.Add(('STEP7 既定: {0}' -f (Get-FlickFitStep7CleanupSummaryJa)))
    return ($lines -join [Environment]::NewLine)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# UI スレッドの未処理例外でプロセスごと落ちるのを防ぐ（子プロセス終了後の Invoke など）
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException
    )
    [System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
        param($sender, $ev)
        try { Write-FlickFitLauncherTrace "[ThreadException] $($ev.Exception.ToString())" } catch { }
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "予期しないエラーが発生しました。`n`n$($ev.Exception.Message)",
                'FlickFit',
                'OK',
                'Error')
        } catch { }
    })
} catch { }

try {
    [AppDomain]::CurrentDomain.add_UnhandledException([System.UnhandledExceptionEventHandler]{
        param($sender, $ev)
        try {
            $ex = $ev.ExceptionObject
            $msg = if ($ex -is [Exception]) { $ex.ToString() } else { [string]$ex }
            Write-FlickFitLauncherTrace "[UnhandledException] terminating=$($ev.IsTerminating) $msg"
        } catch { }
    })
} catch { }

function Show-FlickFitAutoJudgeSettingsDialog {
    param(
        [System.Windows.Forms.Form]$Owner = $null
    )
    $d = [System.Windows.Forms.Form]::new()
    $d.Text = '自動判定・出力形式（STEP5）'
    $d.ClientSize = [System.Drawing.Size]::new(456, 568)
    $d.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'
    $d.ShowInTaskbar = $false
    $d.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $j = Read-FlickFitUserConfigObject
    if (-not $j) { $j = ('{}' | ConvertFrom-Json) }
    $ajIn = $null
    if ($j.PSObject.Properties.Name -contains 'AutoJudge' -and $j.AutoJudge) { $ajIn = $j.AutoJudge }
    $curPreset = 'standard'
    $csr = $false
    $cstf = $false
    $aml = 768
    if ($ajIn) {
        if ($ajIn.PSObject.Properties.Name -contains 'Preset' -and $ajIn.Preset) { $curPreset = [string]$ajIn.Preset }
        if ($ajIn.PSObject.Properties.Name -contains 'DisableCenterSplitRisk') { $csr = [bool]$ajIn.DisableCenterSplitRisk }
        if ($ajIn.PSObject.Properties.Name -contains 'DisableCenteredSingleTrimProfile') { $cstf = [bool]$ajIn.DisableCenteredSingleTrimProfile }
        if ($ajIn.PSObject.Properties.Name -contains 'AnalyzeMaxLong') { try { $aml = [int]$ajIn.AnalyzeMaxLong } catch { } }
    }

    $desc = [System.Windows.Forms.Label]::new()
    $desc.Location = [System.Drawing.Point]::new(12, 10)
    $desc.Size = [System.Drawing.Size]::new(424, 60)
    $desc.Text = "見開き分割の自動判定（STEP5）の強さを選びます。`n「中央1ページ風」などの扱いを調整できます。`nSTEP6 の圧縮出力形式（CBZ / ZIP / RAR）もここで選べます。保存先はルートの UserConfig.json です。"

    $lblCmb = [System.Windows.Forms.Label]::new()
    $lblCmb.Location = [System.Drawing.Point]::new(12, 78)
    $lblCmb.Size = [System.Drawing.Size]::new(120, 20)
    $lblCmb.Text = 'プリセット'
    $cmb = [System.Windows.Forms.ComboBox]::new()
    $cmb.Location = [System.Drawing.Point]::new(130, 74)
    $cmb.Size = [System.Drawing.Size]::new(306, 24)
    $cmb.DropDownStyle = 'DropDownList'
    [void]$cmb.Items.AddRange(@('標準（おすすめ）', 'やや甘め', 'カスタム（上級）'))
    if ($curPreset -match '^(?i)lenient') { $cmb.SelectedIndex = 1 }
    elseif ($curPreset -match '^(?i)custom') { $cmb.SelectedIndex = 2 }
    else { $cmb.SelectedIndex = 0 }

    $lblPresetHint = [System.Windows.Forms.Label]::new()
    $lblPresetHint.Location = [System.Drawing.Point]::new(12, 106)
    $lblPresetHint.Size = [System.Drawing.Size]::new(424, 56)
    $lblPresetHint.Text = ''
    $lblPresetHint.ForeColor = [System.Drawing.Color]::FromArgb(35, 35, 45)

    function Set-FlickFitAutoJudgePresetHintText {
        param([int]$Index)
        switch ($Index) {
            0 { $lblPresetHint.Text = "標準（おすすめ）`n多くの場合に適した推奨設定です。" }
            1 { $lblPresetHint.Text = "やや甘め`n自動判定を少し緩め、見開きを分割しやすくします（誤分割の可能性は少し上がります）。" }
            2 { $lblPresetHint.Text = "カスタム（上級）`n詳細設定を自分で調整したい場合のみ使用してください。" }
            default { $lblPresetHint.Text = '' }
        }
    }

    $lblCompFmt = [System.Windows.Forms.Label]::new()
    $lblCompFmt.Location = [System.Drawing.Point]::new(12, 172)
    $lblCompFmt.Size = [System.Drawing.Size]::new(150, 22)
    $lblCompFmt.Text = '作成する圧縮形式'
    $cmbCompFmt = [System.Windows.Forms.ComboBox]::new()
    $cmbCompFmt.Location = [System.Drawing.Point]::new(168, 168)
    $cmbCompFmt.Size = [System.Drawing.Size]::new(100, 24)
    $cmbCompFmt.DropDownStyle = 'DropDownList'
    [void]$cmbCompFmt.Items.AddRange(@('CBZ', 'ZIP', 'RAR'))
    $initCf = Get-FlickFitNormalizedCompressionFormat -ConfigObject $j
    switch ($initCf) {
        'ZIP' { $cmbCompFmt.SelectedIndex = 1 }
        'RAR' { $cmbCompFmt.SelectedIndex = 2 }
        default { $cmbCompFmt.SelectedIndex = 0 }
    }
    $lblCompRarWarn = [System.Windows.Forms.Label]::new()
    $lblCompRarWarn.Location = [System.Drawing.Point]::new(12, 198)
    $lblCompRarWarn.Size = [System.Drawing.Size]::new(424, 40)
    $lblCompRarWarn.ForeColor = [System.Drawing.Color]::FromArgb(180, 90, 0)
    $lblCompRarWarn.Visible = $false

    function Update-FlickFitCompressionFormatWarnUi {
        $wrOk = (Test-FlickFitWinRARAvailable).Ok
        $sel = [string]$cmbCompFmt.SelectedItem
        if ($sel -eq 'RAR' -and -not $wrOk) {
            $lblCompRarWarn.Text = 'RAR 出力には WinRAR が必要です。未検出ですが選択は可能です。ZIP/CBZ は WinRAR なしで作成できます。UserConfig の WinRAR に exe パスを指定することもできます。'
            $lblCompRarWarn.Visible = $true
        } else {
            $lblCompRarWarn.Visible = $false
        }
    }
    $cmbCompFmt.Add_SelectedIndexChanged({ Update-FlickFitCompressionFormatWarnUi })
    Update-FlickFitCompressionFormatWarnUi

    $pnl = [System.Windows.Forms.Panel]::new()
    $pnl.Location = [System.Drawing.Point]::new(8, 246)
    $pnl.Size = [System.Drawing.Size]::new(432, 220)
    $pnl.BorderStyle = 'FixedSingle'
    $lblP = [System.Windows.Forms.Label]::new()
    $lblP.Location = [System.Drawing.Point]::new(4, 6)
    $lblP.Size = [System.Drawing.Size]::new(420, 36)
    $lblP.Text = 'カスタム時のみ。チェックと数値は UserConfig.json の AutoJudge に保存されます。'
    $chk1 = [System.Windows.Forms.CheckBox]::new()
    $chk1.Location = [System.Drawing.Point]::new(8, 48)
    $chk1.Size = [System.Drawing.Size]::new(404, 36)
    $chk1.Text = "中央1ページ風の判定を無効にする`n（分割を優先）"
    $chk1.Checked = $csr
    $chk2 = [System.Windows.Forms.CheckBox]::new()
    $chk2.Location = [System.Drawing.Point]::new(8, 88)
    $chk2.Size = [System.Drawing.Size]::new(404, 36)
    $chk2.Text = "中央1ページ扱い時の`n自動トリムを無効にする"
    $chk2.Checked = $cstf
    $lblN = [System.Windows.Forms.Label]::new()
    $lblN.Location = [System.Drawing.Point]::new(8, 132)
    $lblN.Size = [System.Drawing.Size]::new(280, 20)
    $lblN.Text = '解析サイズ（長辺px）'
    $nud = [System.Windows.Forms.NumericUpDown]::new()
    $nud.Location = [System.Drawing.Point]::new(300, 128)
    $nud.Size = [System.Drawing.Size]::new(80, 24)
    $nud.Minimum = 0
    $nud.Maximum = 4096
    $nud.Increment = 32
    if ($aml -ge 0 -and $aml -le 4096) { $nud.Value = [decimal]$aml } else { $nud.Value = 768 }
    $nud2 = [System.Windows.Forms.Label]::new()
    $nud2.Location = [System.Drawing.Point]::new(8, 160)
    $nud2.Size = [System.Drawing.Size]::new(400, 44)
    $nud2.Text = "0 = 既定値（通常はそのままでOK）`n0 以外のとき、本体起動前に上記の値が使われます。（FLICK_FIT_ANALYZE_MAX_LONG）"
    $nud2.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $pnl.Controls.AddRange(@($lblP, $chk1, $chk2, $lblN, $nud, $nud2))

    function Update-AutoJudgeDialogPresetUi {
        $on = ($cmb.SelectedIndex -eq 2)
        $pnl.Visible = $on
        Set-FlickFitAutoJudgePresetHintText -Index $cmb.SelectedIndex
    }
    $cmb.Add_SelectedIndexChanged({ Update-AutoJudgeDialogPresetUi })
    Update-AutoJudgeDialogPresetUi

    $btnOk = [System.Windows.Forms.Button]::new()
    $btnOk.Text = 'OK'
    $btnOk.DialogResult = 'OK'
    $btnOk.Location = [System.Drawing.Point]::new(256, 478)
    $btnOk.Size = [System.Drawing.Size]::new(90, 28)
    $btnOk.TabIndex = 0
    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = 'キャンセル'
    $btnCancel.DialogResult = 'Cancel'
    $btnCancel.Location = [System.Drawing.Point]::new(352, 478)
    $btnCancel.Size = [System.Drawing.Size]::new(90, 28)
    $btnCancel.TabIndex = 1
    $btnReset = [System.Windows.Forms.Button]::new()
    $btnReset.Text = '初期設定に戻す'
    $btnReset.Location = [System.Drawing.Point]::new(12, 474)
    $btnReset.Size = [System.Drawing.Size]::new(150, 28)
    $lblResetHint = [System.Windows.Forms.Label]::new()
    $lblResetHint.Location = [System.Drawing.Point]::new(12, 506)
    $lblResetHint.Size = [System.Drawing.Size]::new(432, 40)
    $lblResetHint.Text = "「AutoJudge」のみを削除して既定（標準）に戻し、ルート UserConfig.json に即保存します。`n圧縮形式はこのボタンでは変わりません（Combo の変更は OK で保存）。他キーはそのままです。"
    $lblResetHint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
    $btnReset.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show(
                "「AutoJudge」のみを UserConfig.json から削除し、見開き自動判定を既定（標準）に戻します。`nCompressionFormat など他のキーはそのままです。よろしいですか？",
                'FlickFit',
                'YesNo',
                'Question'
            ) -ne 'Yes') { return }
        $jr = Read-FlickFitUserConfigObject
        if ($jr -and $jr.PSObject.Properties.Name -contains 'AutoJudge') {
            [void]$jr.PSObject.Properties.Remove('AutoJudge')
        }
        if ($jr) { Write-FlickFitUserConfigObjectToRoot -ConfigObject $jr }
        $cmb.SelectedIndex = 0
        $chk1.Checked = $false
        $chk2.Checked = $false
        $nud.Value = 768
        Set-FlickFitAutoJudgePresetHintText -Index 0
        Update-FlickFitCompressionFormatWarnUi
    })

    $d.AcceptButton = $btnOk
    $d.CancelButton = $btnCancel
    $d.Controls.AddRange(@($desc, $lblCmb, $cmb, $lblPresetHint, $lblCompFmt, $cmbCompFmt, $lblCompRarWarn, $pnl, $btnOk, $btnCancel, $btnReset, $lblResetHint))
    $dr = if ($Owner -and -not $Owner.IsDisposed) { $d.ShowDialog($Owner) } else { $d.ShowDialog() }
    if ($dr -ne [System.Windows.Forms.DialogResult]::OK) { return $false }

    $j2 = Read-FlickFitUserConfigObject
    if (-not $j2) { $j2 = ('{}' | ConvertFrom-Json) }
    if ($j2.PSObject.Properties.Name -contains 'AutoJudge') { [void]$j2.PSObject.Properties.Remove('AutoJudge') }
    if ($cmb.SelectedIndex -eq 0) {
        # 標準: キー省略（=既定）。残りの UserConfig はそのまま
    } elseif ($cmb.SelectedIndex -eq 1) {
        $j2 | Add-Member -NotePropertyName 'AutoJudge' -NotePropertyValue ([pscustomobject]@{ Preset = 'lenient' }) -Force
    } else {
        $g = [ordered]@{
            Preset = 'custom'
            DisableCenterSplitRisk = $chk1.Checked
            DisableCenteredSingleTrimProfile = $chk2.Checked
        }
        $av = [int]$nud.Value
        if ($av -ge 0) { $g['AnalyzeMaxLong'] = $av }
        $j2 | Add-Member -NotePropertyName 'AutoJudge' -NotePropertyValue ([pscustomobject]$g) -Force
    }
    $cfOut = [string]$cmbCompFmt.SelectedItem
    if ([string]::IsNullOrWhiteSpace($cfOut)) { $cfOut = 'CBZ' }
    $j2 | Add-Member -NotePropertyName 'CompressionFormat' -NotePropertyValue $cfOut.Trim().ToUpperInvariant() -Force
    Write-FlickFitUserConfigObjectToRoot -ConfigObject $j2
    return $true
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'FlickFit v1.0.0'
# Size ではなく ClientSize（描画領域）を指定。高さ不足だと下部のヒントが見切れる
$form.ClientSize = [System.Drawing.Size]::new(700, 732)
$form.MinimumSize = [System.Drawing.Size]::new(620, 622)
$form.StartPosition = 'CenterScreen'
$form.MinimizeBox = $true
$form.MaximizeBox = $true
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.WindowState = [System.Windows.Forms.FormWindowState]::Normal

$topPanel = [System.Windows.Forms.Panel]::new()
$topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
# 末尾は STEP7 補足行（〜約320）まで
$topPanel.Height = 320

$lblTitle = [System.Windows.Forms.Label]::new()
$lblTitle.Location = [System.Drawing.Point]::new(12, 8)
$lblTitle.Size = [System.Drawing.Size]::new(600, 36)
$lblTitle.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblTitle.Text = '漫画画像の見開き分割・余白調整（FlickFit）'

$lblFolder = [System.Windows.Forms.Label]::new()
$lblFolder.Location = [System.Drawing.Point]::new(12, 46)
$lblFolder.Size = [System.Drawing.Size]::new(560, 20)
$lblFolder.Anchor = 'Top, Left, Right'
$lblFolder.Text = '作品フォルダ（解凍済み・この中を処理します）'

# テキストを Left+Right アンカーにすると右端まで伸びて「参照」ボタンを覆うため、行専用パネルで Dock 配置する
$folderRowPanel = [System.Windows.Forms.Panel]::new()
$folderRowPanel.Location = [System.Drawing.Point]::new(12, 68)
$folderRowPanel.Height = 28
$folderRowPanel.Width = 676
$folderRowPanel.Anchor = 'Top, Left, Right'

$txtFolder = [System.Windows.Forms.TextBox]::new()
$txtFolder.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtFolder.TabIndex = 0

$btnBrowse = [System.Windows.Forms.Button]::new()
$btnBrowse.Text = '参照...'
$btnBrowse.Dock = [System.Windows.Forms.DockStyle]::Right
$btnBrowse.Width = 108
$btnBrowse.TabIndex = 1

# Right を先に置いてから Fill（テキスト）で残り幅を使う
$folderRowPanel.Controls.Add($btnBrowse)
$folderRowPanel.Controls.Add($txtFolder)

$btnCheck = [System.Windows.Forms.Button]::new()
$btnCheck.Text = '環境を確認'
$btnCheck.Location = [System.Drawing.Point]::new(12, 104)
$btnCheck.Size = [System.Drawing.Size]::new(120, 30)
$btnCheck.TabIndex = 2

$btnRun = [System.Windows.Forms.Button]::new()
$btnRun.Text = '実行'
$btnRun.Location = [System.Drawing.Point]::new(140, 100)
$btnRun.Size = [System.Drawing.Size]::new(120, 36)
$btnRun.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnRun.TabIndex = 3

$lblRunStatus = [System.Windows.Forms.Label]::new()
$lblRunStatus.Location = [System.Drawing.Point]::new(268, 106)
# 右列ボタン（X≈500）に被らないよう幅を抑える。長文は省略表示
$lblRunStatus.Size = [System.Drawing.Size]::new(220, 28)
$lblRunStatus.AutoSize = $false
$lblRunStatus.AutoEllipsis = $true
$lblRunStatus.Text = '待機中'
$lblRunStatus.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)

# 上段: 環境/実行(〜136) と右列2ボタン(〜162)。下段: 自動判定の青文字のみ（右列と重ならないY）
$lblAutoPreset = [System.Windows.Forms.Label]::new()
$lblAutoPreset.Location = [System.Drawing.Point]::new(12, 168)
$lblAutoPreset.Size = [System.Drawing.Size]::new(480, 32)
$lblAutoPreset.Text = "自動判定: $(Get-FlickFitAutoJudgeSummaryJa)"
$lblAutoPreset.ForeColor = [System.Drawing.Color]::FromArgb(50, 80, 120)

$btnAutoJudge = [System.Windows.Forms.Button]::new()
$btnAutoJudge.Text = '詳細オプション…'
$btnAutoJudge.Location = [System.Drawing.Point]::new(500, 100)
$btnAutoJudge.Size = [System.Drawing.Size]::new(168, 30)
$btnAutoJudge.TabIndex = 4

$btnVolumeRules = [System.Windows.Forms.Button]::new()
$btnVolumeRules.Text = '巻数ルールを開く…'
$btnVolumeRules.Location = [System.Drawing.Point]::new(500, 132)
$btnVolumeRules.Size = [System.Drawing.Size]::new(168, 30)
$btnVolumeRules.TabIndex = 5

$lblStep7Cleanup = [System.Windows.Forms.Label]::new()
$lblStep7Cleanup.Location = [System.Drawing.Point]::new(12, 202)
$lblStep7Cleanup.Size = [System.Drawing.Size]::new(660, 18)
$lblStep7Cleanup.Anchor = 'Top, Left, Right'
$lblStep7Cleanup.Text = '完了時クリーンアップ（STEP7）の既定 ― UserConfig.json に保存'

$chkCleanupWorkingFolders = [System.Windows.Forms.CheckBox]::new()
$chkCleanupWorkingFolders.Location = [System.Drawing.Point]::new(12, 224)
$chkCleanupWorkingFolders.Size = [System.Drawing.Size]::new(660, 24)
$chkCleanupWorkingFolders.Anchor = 'Top, Left, Right'
$chkCleanupWorkingFolders.TabIndex = 6
$chkCleanupWorkingFolders.Text = '作業フォルダ（_unpacked 含む）を削除する'

# ON＝解凍元をごみ箱へ移動する旨の確認で既定「はい」。UserConfig.KeepSourceArchives は OFF と逆相関
$chkDeleteSourceArchives = [System.Windows.Forms.CheckBox]::new()
$chkDeleteSourceArchives.Location = [System.Drawing.Point]::new(12, 252)
$chkDeleteSourceArchives.Size = [System.Drawing.Size]::new(660, 24)
$chkDeleteSourceArchives.Anchor = 'Top, Left, Right'
$chkDeleteSourceArchives.TabIndex = 7
$chkDeleteSourceArchives.Text = '解凍元アーカイブを削除する（ごみ箱へ）'

$lblStep7Hint = [System.Windows.Forms.Label]::new()
$lblStep7Hint.Location = [System.Drawing.Point]::new(12, 282)
$lblStep7Hint.Size = [System.Drawing.Size]::new(660, 36)
$lblStep7Hint.Anchor = 'Top, Left, Right'
$lblStep7Hint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$lblStep7Hint.Text = "※ 実際の削除は処理の最後（STEP7）で確認してから行われます。`r`n※ 解凍元の移動は Windows のごみ箱です。"

$topPanel.Controls.AddRange(@(
    $lblTitle, $lblFolder, $folderRowPanel, $btnCheck, $btnRun, $lblRunStatus, $lblAutoPreset,
    $btnAutoJudge, $btnVolumeRules, $lblStep7Cleanup, $chkCleanupWorkingFolders, $chkDeleteSourceArchives, $lblStep7Hint
))

$txtLog = [System.Windows.Forms.TextBox]::new()
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtLog.Font = [System.Drawing.Font]::new('Consolas', 9)
# フォーカス時に全文が青い選択状態になるのを抑える（ReadOnly 多行の癖）
$txtLog.TabIndex = 40
$txtLog.HideSelection = $true

$lblHint = [System.Windows.Forms.Label]::new()
$lblHint.Dock = [System.Windows.Forms.DockStyle]::Fill
$lblHint.AutoSize = $false
$lblHint.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$lblHint.Padding = [System.Windows.Forms.Padding]::new(12, 10, 12, 10)
$lblHint.Text = "「実行」でメイン処理が別の PowerShell ウィンドウで始まります（通常表示）。詳細ログはそのウィンドウで確認してください。`r`n将来、ログファイルを監視してこの欄に表示する方式を追加予定です。"

$bottomPanel = [System.Windows.Forms.Panel]::new()
$bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$bottomPanel.Height = 88
$bottomPanel.Controls.Add($lblHint)

# Dock: 中央 Fill → 下 Bottom → 上 Top の順で追加すると、ログとヒントが重ならない
$form.Controls.Add($txtLog)
$form.Controls.Add($bottomPanel)
$form.Controls.Add($topPanel)

# ウィンドウ表示後に Get-FlickFitEnvReport で上書き（起動をブロックしないよう軽い文言のみ）
$txtLog.Text = "起動しました。初回チェックを実行しています…`r`n（数秒〜十数秒かかることがあります）"

function Clear-FlickFitLogSelection {
    $txtLog.SelectionLength = 0
    $txtLog.SelectionStart = $txtLog.Text.Length
}

# 環境レポート追記やプロセス終了コールバック等、UI 以外から呼ぶ可能性があるため BeginInvoke でログ欄を更新する
function Add-FlickFitLogLine {
    param([string]$Text)
    try {
        if ($null -eq $txtLog -or $txtLog.IsDisposed -or $form.IsDisposed) { return }
        $line = if ($null -eq $Text) { '' } elseif ($Text -match '\r?\n$') { $Text } else { $Text + [Environment]::NewLine }
        $appendAction = [System.Windows.Forms.MethodInvoker]{
            if ($null -eq $txtLog -or $txtLog.IsDisposed) { return }
            $txtLog.AppendText($line)
            $txtLog.SelectionStart = $txtLog.TextLength
            $txtLog.ScrollToCaret()
        }
        if ($txtLog.InvokeRequired) {
            try {
                [void]$txtLog.BeginInvoke($appendAction)
            } catch {
                # フォーム終了中など
            }
        } else {
            try {
                [void]$appendAction.Invoke()
            } catch { }
        }
    } catch { }
}

function Set-FlickFitLauncherRunMode {
    param([bool]$Running)
    # メインは別プロセス。二重起動防止のため実行中だけ「フォルダ変更・再実行」をオフ。
    # 環境チェック／STEP7 等はオンに保ち、長時間実行中でも「固まって見える」体感を抑える。
    $folderEditable = -not $Running
    if ($txtFolder -and -not $txtFolder.IsDisposed) { $txtFolder.Enabled = $folderEditable }
    if ($btnBrowse -and -not $btnBrowse.IsDisposed) { $btnBrowse.Enabled = $folderEditable }
    if ($btnRun -and -not $btnRun.IsDisposed) { $btnRun.Enabled = $folderEditable }
    if ($btnCheck -and -not $btnCheck.IsDisposed) { $btnCheck.Enabled = $true }
    if ($btnAutoJudge -and -not $btnAutoJudge.IsDisposed) { $btnAutoJudge.Enabled = $true }
    if ($btnVolumeRules -and -not $btnVolumeRules.IsDisposed) { $btnVolumeRules.Enabled = $true }
    if ($chkCleanupWorkingFolders -and -not $chkCleanupWorkingFolders.IsDisposed) {
        $chkCleanupWorkingFolders.Enabled = $true
    }
    if ($chkDeleteSourceArchives -and -not $chkDeleteSourceArchives.IsDisposed) {
        $chkDeleteSourceArchives.Enabled = $true
    }
}

Clear-FlickFitLogSelection

$script:FlickFitStep7UiLoading = $false
$form.Add_Load({
    $folderRowPanel.Width = [Math]::Max(200, $topPanel.ClientSize.Width - 24)
    $script:FlickFitStep7UiLoading = $true
    try {
        $jInit = Read-FlickFitUserConfigObject
        $wInit = $true
        $kInit = $true
        if ($jInit) {
            if ($null -ne $jInit.CleanupWorkingFolders) { $wInit = [bool]$jInit.CleanupWorkingFolders }
            if ($null -ne $jInit.KeepSourceArchives) { $kInit = [bool]$jInit.KeepSourceArchives }
        }
        $chkCleanupWorkingFolders.Checked = $wInit
        $chkDeleteSourceArchives.Checked = -not $kInit
    } finally {
        $script:FlickFitStep7UiLoading = $false
    }
    $form.ActiveControl = $txtFolder
    Clear-FlickFitLogSelection
})

$chkCleanupWorkingFolders.Add_CheckedChanged({
    if ($script:FlickFitStep7UiLoading) { return }
    try {
        $keepSrc = -not $chkDeleteSourceArchives.Checked
        Save-FlickFitStep7CleanupToUserConfig -CleanupWorkingFolders $chkCleanupWorkingFolders.Checked -KeepSourceArchives $keepSrc
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "UserConfig の保存に失敗しました: $($_.Exception.Message)",
            'FlickFit', 'OK', 'Error')
    }
})
$chkDeleteSourceArchives.Add_CheckedChanged({
    if ($script:FlickFitStep7UiLoading) { return }
    try {
        $keepSrc = -not $chkDeleteSourceArchives.Checked
        Save-FlickFitStep7CleanupToUserConfig -CleanupWorkingFolders $chkCleanupWorkingFolders.Checked -KeepSourceArchives $keepSrc
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "UserConfig の保存に失敗しました: $($_.Exception.Message)",
            'FlickFit', 'OK', 'Error')
    }
})

$form.Add_Shown({
    try {
        Ensure-FlickFitLauncherWin32
    } catch { }
    # -WindowStyle Hidden 等で起動するとフォームが最小化扱いになることがあるため明示的に復元する
    try {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $fh = $form.Handle
        if ($fh -ne [IntPtr]::Zero -and ([System.Management.Automation.PSTypeName]'FlickFitLauncherWin32').Type) {
            [void][FlickFitLauncherWin32]::ShowWindow($fh, [FlickFitLauncherWin32]::SW_RESTORE)
            [void][FlickFitLauncherWin32]::SetForegroundWindow($fh)
        }
        [void]$form.Activate()
        [void]$form.BringToFront()
    } catch { }
    [void]$txtFolder.Focus()
    Clear-FlickFitLogSelection
    # Shown 内で Get-FlickFitEnvReport を直実行すると初回描画が数十秒ブロックすることがあるため、
    # ウィンドウを先に出してから非同期でログを埋める。
    $envReportAction = [System.Windows.Forms.MethodInvoker]{
        try {
            $txtLog.Text = Get-FlickFitEnvReport
        } catch {
            $txtLog.Text = "環境チェックでエラー: $($_.Exception.Message)"
        }
        Clear-FlickFitLogSelection
    }
    try {
        [void]$form.BeginInvoke($envReportAction)
    } catch {
        try {
            [void]$envReportAction.Invoke()
        } catch { }
    }
    # 先頭の Hide より後に conhost が付く環境用の二段目
    try {
        Hide-FlickFitLauncherConsole
    } catch { }
})

# ログ欄を初めてクリックしたときだけ「全文選択」を解除（コピー用の選択はその後は維持）
$script:FlickFitLogSuppressSelectAll = $true
$txtLog.Add_GotFocus({
    if ($script:FlickFitLogSuppressSelectAll) {
        $script:FlickFitLogSuppressSelectAll = $false
        Clear-FlickFitLogSelection
    }
})

$btnBrowse.Add_Click({
    $d = [System.Windows.Forms.FolderBrowserDialog]::new()
    $d.Description = '作品フォルダを選択'
    if ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text)) {
        try { $d.SelectedPath = (Resolve-Path -LiteralPath $txtFolder.Text).Path } catch { }
    }
    if ($d.ShowDialog() -eq 'OK') {
        $txtFolder.Text = $d.SelectedPath
    }
})

$btnCheck.Add_Click({
    $txtLog.Text = Get-FlickFitEnvReport
    Clear-FlickFitLogSelection
})

$btnAutoJudge.Add_Click({
    try {
        $r = Show-FlickFitAutoJudgeSettingsDialog -Owner $form
        if ($r -and $lblAutoPreset -and -not $lblAutoPreset.IsDisposed) {
            $lblAutoPreset.Text = "自動判定: $(Get-FlickFitAutoJudgeSummaryJa)"
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "設定の保存でエラー: $($_.Exception.Message)",
            'FlickFit',
            'OK',
            'Error')
    }
})

$btnVolumeRules.Add_Click({
    try { Open-FlickFitVolumeRuleLocalInEditor } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "ルール用ファイルを開けません: $($_.Exception.Message)",
            'FlickFit', 'OK', 'Error'
        )
    }
})

# クリック内の未捕捉例外でホストごと終了しうるため、本体はすべて try/catch で保護する
$btnRun.Add_Click({
    try {
        if (-not $script:FlickFitLauncherDebugDummyChild) {
            if (-not (Test-Path -LiteralPath $script:EnginePs1)) {
                [System.Windows.Forms.MessageBox]::Show(
                    "メインスクリプトが見つかりません:`n$($script:EnginePs1)",
                    'FlickFit',
                    'OK',
                    'Error')
                return
            }
            $fold = $txtFolder.Text.Trim()
            $chk = Test-FlickFitTargetFolder -Path $fold
            if (-not $chk.Ok) {
                [System.Windows.Forms.MessageBox]::Show("フォルダ: $($chk.Detail)", 'FlickFit', 'OK', 'Warning')
                return
            }
            $py = Test-FlickFitPythonAvailable
            if (-not $py.Ok) {
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "Python を検出できませんでした。画像処理は使えません。続行しますか？`n`n$($py.Detail)",
                    'FlickFit',
                    'YesNo',
                    'Warning')
                if ($r -ne 'Yes') { return }
            }
            $wr = Test-FlickFitWinRARAvailable
            if (-not $wr.Ok) {
                $r2 = [System.Windows.Forms.MessageBox]::Show(
                    "WinRAR が見つかりません。圧縮に失敗する可能性があります。続行しますか？`n$($wr.Detail)",
                    'FlickFit',
                    'YesNo',
                    'Warning')
                if ($r2 -ne 'Yes') { return }
            }
        }

        if ($script:EngineProcess -and -not $script:EngineProcess.HasExited) {
            [System.Windows.Forms.MessageBox]::Show(
                '処理が実行中です。完了を待ってから再度「実行」してください。',
                'FlickFit',
                'OK',
                'Information')
            return
        }

        $pwsh = Get-FlickFitPwshPath
        $psExe = if ($pwsh) { $pwsh } else { (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
        $useSta = $psExe -match '(?i)[\\/]powershell\.exe$'

        $argList = [System.Collections.Generic.List[string]]::new()
        if ($script:FlickFitLauncherDebugDummyChild) {
            try { Write-FlickFitLauncherTrace '[RunClick] DEBUG mode=dummy child (Core 未使用・一時 .ps1 + -File)' } catch { }
            if ($script:EngineWatcherTempDummyPs1 -and (Test-Path -LiteralPath $script:EngineWatcherTempDummyPs1)) {
                try { Remove-Item -LiteralPath $script:EngineWatcherTempDummyPs1 -Force -ErrorAction SilentlyContinue } catch { }
            }
            $dummyPs1 = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('FFL_dummy_{0}_{1}.ps1' -f $PID, [Guid]::NewGuid().ToString('N').Substring(0, 12)))
            $dummyScript = @'
Write-Host 'dummy child'
Start-Sleep 3
Read-Host 'Enterで終了'
'@
            $encDummy = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($dummyPs1, $dummyScript, $encDummy)
            $script:EngineWatcherTempDummyPs1 = $dummyPs1
            try { Write-FlickFitLauncherTrace "[WatcherDummy] file=$dummyPs1" } catch { }

            foreach ($x in @('-NoProfile', '-ExecutionPolicy', 'Bypass')) { [void]$argList.Add($x) }
            if ($useSta) { [void]$argList.Add('-Sta') }
            foreach ($x in @('-File', $dummyPs1)) { [void]$argList.Add($x) }
        } else {
            $fold = $txtFolder.Text.Trim()
            foreach ($x in @('-NoProfile', '-ExecutionPolicy', 'Bypass')) { [void]$argList.Add($x) }
            if ($useSta) { [void]$argList.Add('-Sta') }
            if ($script:FlickFitLauncherDebugCoreChildNoExit) {
                [void]$argList.Add('-NoExit')
                try { Write-FlickFitLauncherTrace '[RunClick] DEBUG FlickFitLauncherDebugCoreChildNoExit: -NoExit を付与（エラー確認後は false に）' } catch { }
            }
            foreach ($x in @('-File', $script:EnginePs1, '-TargetFolder', $fold, '-LauncherPid', [string]$PID)) {
                [void]$argList.Add($x)
            }
        }

        Add-FlickFitLogLine ''
        if ($script:FlickFitLauncherDebugDummyChild) {
            Add-FlickFitLogLine "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ダミー子 PowerShell 起動（切り分け・Core なし） ==="
        } else {
            Add-FlickFitLogLine "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') メイン起動（別ウィンドウ・通常表示） ==="
        }
        Add-FlickFitLogLine "[Launcher] root=$($script:RootDir)"
        Add-FlickFitLogLine "[Launcher] psExe=$psExe"
        if (-not $script:FlickFitLauncherDebugDummyChild) {
            Add-FlickFitLogLine "[Launcher] folder=$fold"
        }
        for ($ai = 0; $ai -lt $argList.Count; $ai++) {
            Add-FlickFitLogLine ("[Launcher] argv[{0}]={1}" -f $ai, $argList[$ai])
        }

        if ($lblRunStatus -and -not $lblRunStatus.IsDisposed) {
            $lblRunStatus.Text = '実行中…（メインは別の PowerShell ウィンドウで実行中）'
        }

        try { Write-FlickFitLauncherTrace '[RunClick] before Start-FlickFitEngineProcess (temp .cmd + cmd /c call)' } catch { }
        $script:EngineWatcherCompletionDone = $false
        $proc = Start-FlickFitEngineProcess -PsExe $psExe -WorkingDirectory $script:RootDir -Arguments $argList.ToArray()

        if (-not $proc) {
            try { Set-FlickFitLauncherRunMode -Running $false } catch { }
            if ($lblRunStatus -and -not $lblRunStatus.IsDisposed) { $lblRunStatus.Text = '待機中' }
            Remove-FlickFitEngineWatcherTempCmd
            Remove-FlickFitEngineWatcherTempDummyPs1
            [System.Windows.Forms.MessageBox]::Show(
                'メイン処理の起動に失敗しました（子プロセスを取得できませんでした）。',
                'FlickFit',
                'OK',
                'Error')
            return
        }

        try { Write-FlickFitLauncherTrace "[RunClick] watcher started (cmd /c call .cmd) pid=$($proc.Id)" } catch { }

        $script:EngineProcess = $proc

        $pollT = [System.Windows.Forms.Timer]::new()
        $pollT.Interval = 1000
        $pollT.add_Tick({
            if ($script:EngineWatcherCompletionDone) { return }
            if (-not $script:EngineProcess) { return }
            try {
                $script:EngineProcess.Refresh()
                if ($script:EngineProcess.HasExited) {
                    $pp = $script:EngineProcess
                    Complete-FlickFitEngineWatcher -Watcher $pp
                }
            } catch { }
        })
        $script:EngineWatcherPollTimer = $pollT
        $pollT.Start()

        Set-FlickFitLauncherRunMode -Running $true
    } catch {
        try { Set-FlickFitLauncherRunMode -Running $false } catch { }
        if ($lblRunStatus -and -not $lblRunStatus.IsDisposed) { $lblRunStatus.Text = '待機中' }
        Stop-FlickFitEngineWatcherPollTimer
        Stop-FlickFitPostRestoreHeartbeatTimer -Reason 'RunClick-catch'
        Remove-FlickFitEngineWatcherTempCmd
        Remove-FlickFitEngineWatcherTempDummyPs1
        $script:EngineProcess = $null
        try { Add-FlickFitLogLine "[Launcher][RunClick] $($_.Exception.Message)" } catch { }
        [System.Windows.Forms.MessageBox]::Show(
            "実行開始処理でエラーが発生しました。`n`n$($_.Exception.Message)",
            'FlickFit',
            'OK',
            'Error')
    }
})

$form.Add_FormClosing({
    param($srcForm, $evArgs)
    try { Stop-FlickFitPostRestoreHeartbeatTimer -Reason 'FormClosing' } catch { }
    try {
        $pidText = '<none>'
        $hasExitedText = '<none>'
        if ($script:EngineProcess) {
            $pidText = [string]$script:EngineProcess.Id
            try { $hasExitedText = [string]$script:EngineProcess.HasExited } catch { }
        }
        Write-FlickFitLauncherTrace "[FormClosing] reason=$($evArgs.CloseReason) watcherPid=$pidText hasExited=$hasExitedText"
    } catch { }
    if ($script:EngineProcess -and -not $script:EngineProcess.HasExited) {
        Write-FlickFitLauncherTrace "[FormClosing] watcher 待機中 pid=$($script:EngineProcess.Id) → 確認ダイアログ"
        $r = [System.Windows.Forms.MessageBox]::Show(
            "メイン処理が実行中です。`nウィンドウを閉じると処理が中止されます。閉じますか？",
            'FlickFit',
            'YesNo',
            'Warning')
        if ($r -ne 'Yes') {
            try { Write-FlickFitLauncherTrace "[FormClosing] cancel=true" } catch { }
            $evArgs.Cancel = $true
            return
        }
        try { Write-FlickFitLauncherTrace "[FormClosing] kill watcher tree (taskkill /T)" } catch { }
        try { Stop-FlickFitEngineWatcherTree -Watcher $script:EngineProcess } catch { }
        Stop-FlickFitEngineWatcherPollTimer
        Remove-FlickFitEngineWatcherTempCmd
        Remove-FlickFitEngineWatcherTempDummyPs1
        Stop-FlickFitPostRestoreHeartbeatTimer -Reason 'FormClosing-user-confirmed-watcher-kill'
        $script:EngineWatcherCompletionDone = $true
        $script:EngineProcess = $null
    } else {
        Write-FlickFitLauncherTrace "[FormClosing] engine なし／既に終了 → そのまま閉じる（メイン終了では閉じない）"
    }
})

$form.Add_FormClosed({
    param($srcForm, $evArgs)
    try {
        Write-FlickFitLauncherTrace "[FormClosed] reason=$($evArgs.CloseReason)"
    } catch { }
})

[System.Windows.Forms.Application]::add_ApplicationExit([System.EventHandler]{
    param($sender, $ev)
    try { Write-FlickFitLauncherTrace "[ApplicationExit]" } catch { }
})

# メイン watcher 完了ではフォームを閉じない（Poll 検知のみ・Process.Exited は使わない）。
# ランチャーごと消えるときは親 pwsh のコンソールを閉じていないか確認（同一プロセスのため）。
try {
    Write-FlickFitLauncherTrace "==== Launcher session start pid=$PID time=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===="
} catch { }
try { Write-FlickFitLauncherTrace "[Trace] path=$script:LauncherTracePath script=$PSCommandPath" } catch { }
try { Write-FlickFitLauncherTrace '[ApplicationRun] before' } catch { }
[System.Windows.Forms.Application]::Run($form)
try { Write-FlickFitLauncherTrace "[ApplicationRun] after" } catch { }
