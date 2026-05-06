#Requires -Version 5.1
<#
.SYNOPSIS
    FlickFit - 圧縮（ZIP/RAR）
.DESCRIPTION
    フォルダをZIPまたはRARで圧縮する
#>

function Test-WinRARArchive {
    param(
        [Parameter(Mandatory)]
        [string]$WinRARPath,
        [Parameter(Mandatory)]
        [string]$ArchivePath
    )

    try {
        # WinRAR の `t` は整合性チェック（CRC等）を行い、失敗時は ExitCode != 0 になります
        $p = Start-Process -FilePath $WinRARPath -ArgumentList "t -idq `"$ArchivePath`"" -Wait -NoNewWindow -PassThru -ErrorAction Stop
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Remove-PartialArchiveParts {
    param(
        [Parameter(Mandatory)]
        [string]$OutputFolder,
        [Parameter(Mandatory)]
        [string]$BaseName,
        [Parameter(Mandatory)]
        [ValidateSet('CBZ','ZIP','RAR')]
        [string]$Format
    )

    $escapedBase = [regex]::Escape($BaseName)
    $nameRegex = switch ($Format) {
        'RAR' { "^$escapedBase\.(rar|r\d{2,3})$" }
        default { "^$escapedBase\.(cbz|zip|z\d{2,3})$" }
    }

    try {
        Get-ChildItem -LiteralPath $OutputFolder -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match $nameRegex) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        # クリーニング失敗は圧縮リトライ側で吸収するため無視
    }
}

function Invoke-CompressFolder {
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath,
        [Parameter(Mandatory)]
        [string]$OutputFolder,
        [ValidateSet('CBZ','ZIP','RAR')]
        [string]$Format = 'CBZ',
        [string]$WinRARPath = $null,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySec = 2,
        [bool]$VerifyAfterCreate = $true
    )

    $baseName = Split-Path $FolderPath -Leaf
    if (Get-Command Convert-FlickFitSafeOutputBasename -ErrorAction SilentlyContinue) {
        $baseName = Convert-FlickFitSafeOutputBasename -LeafName $baseName
    }
    $archiveExt = if ($Format -eq 'CBZ') { '.cbz' } elseif ($Format -eq 'ZIP') { '.zip' } else { '.rar' }
    $archiveFileName = $baseName + $archiveExt
    $archiveOutPath = Join-Path $OutputFolder $archiveFileName

    # 空フォルダだと「0byteのアーカイブ」等ができてしまうことがあるため、先に弾く
    try {
        $firstAnyFile = Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $firstAnyFile) {
            Write-FlickFitHost "  [スキップ]: 空フォルダ" -ForegroundColor Yellow
            return $null
        }
    } catch {
        # 念のため続行（圧縮自体は WinRAR/Compress-Archive に任せる）
    }

    $attempt = 0
    $lastFailure = $null
    while ($attempt -lt $MaxRetries) {
        $attempt++

        if ($attempt -gt 1) {
            Write-FlickFitHost "  [リトライ $attempt/$MaxRetries]: $baseName" -ForegroundColor DarkGray
            Remove-PartialArchiveParts -OutputFolder $OutputFolder -BaseName $baseName -Format $Format
            Start-Sleep -Seconds $RetryDelaySec
        }

        if ($Format -eq 'CBZ' -or $Format -eq 'ZIP') {
            if ($WinRARPath -and (Test-Path -LiteralPath $WinRARPath)) {
                Write-FlickFitHost "  [圧縮中]: $baseName (WinRAR) 試行 $attempt/$MaxRetries" -ForegroundColor Gray
                $winRARArgs = "a -afzip -m3 -r -idq -ep1 -y `"$archiveOutPath`" `"$FolderPath`""
                $p = Start-Process -FilePath $WinRARPath -ArgumentList $winRARArgs -Wait -NoNewWindow -PassThru
                $exitCode = $p.ExitCode

                if (-not (Test-Path -LiteralPath $archiveOutPath)) {
                    $lastFailure = "WinRAR create failed (no output file). ExitCode=$exitCode"
                    continue
                }
                $outLen = (Get-Item -LiteralPath $archiveOutPath -ErrorAction SilentlyContinue).Length
                if (-not $outLen -or $outLen -le 0) {
                    $lastFailure = "WinRAR create failed (0 bytes). ExitCode=$exitCode"
                    continue
                }

                if ($VerifyAfterCreate) {
                    if (-not (Test-WinRARArchive -WinRARPath $WinRARPath -ArchivePath $archiveOutPath)) {
                        $lastFailure = "WinRAR integrity test failed. ExitCode=$exitCode"
                        continue
                    }
                }

                Write-FlickFitHost "    -> 完了: $archiveFileName" -ForegroundColor Green
                return $archiveOutPath
            } else {
                # WinRAR無し: ZIP/CBZは Compress-Archive にフォールバック
                Write-FlickFitHost "  [圧縮中]: $baseName 試行 $attempt/$MaxRetries" -ForegroundColor Gray
                try {
                    $items = @(Get-ChildItem -LiteralPath $FolderPath -Force -ErrorAction Stop)
                    if ($items.Count -eq 0) {
                        Write-FlickFitHost "    -> スキップ: 空フォルダ" -ForegroundColor Yellow
                        return $null
                    }
                    $pathsToArchive = $items | ForEach-Object { $_.FullName }
                    $compressDest = if ($Format -eq 'CBZ') { (Join-Path $OutputFolder ($baseName + '.zip')) } else { $archiveOutPath }

                    Compress-Archive -LiteralPath $pathsToArchive -DestinationPath $compressDest -CompressionLevel Optimal -Force
                    if ($Format -eq 'CBZ' -and (Test-Path -LiteralPath $compressDest)) {
                        Move-Item -LiteralPath $compressDest -Destination $archiveOutPath -Force
                    }

                    if (-not (Test-Path -LiteralPath $archiveOutPath)) {
                        $lastFailure = "Compress-Archive create failed (no output file)"
                        continue
                    }
                    $outLen = (Get-Item -LiteralPath $archiveOutPath -ErrorAction SilentlyContinue).Length
                    if (-not $outLen -or $outLen -le 0) {
                        $lastFailure = "Compress-Archive create failed (0 bytes)"
                        continue
                    }

                    Write-FlickFitHost "    -> 完了: $archiveFileName" -ForegroundColor Green
                    return $archiveOutPath
                } catch {
                    $lastFailure = "Compress-Archive error: $($_.Exception.Message)"
                    continue
                }
            }
        } else {
            # RAR（WinRAR必須）
            if (-not $WinRARPath -or -not (Test-Path -LiteralPath $WinRARPath)) {
                Write-FlickFitHost "  [スキップ]: WinRAR が見つかりません" -ForegroundColor Yellow
                return $null
            }

            Write-FlickFitHost "  [圧縮中]: $baseName (WinRAR) 試行 $attempt/$MaxRetries" -ForegroundColor Gray
            $winRARArgs = "a -m3 -afrar -r -idq -ep1 -y `"$archiveOutPath`" `"$FolderPath`""
            $p = Start-Process -FilePath $WinRARPath -ArgumentList $winRARArgs -Wait -NoNewWindow -PassThru
            $exitCode = $p.ExitCode

            if (-not (Test-Path -LiteralPath $archiveOutPath)) {
                $lastFailure = "WinRAR create failed (no output file). ExitCode=$exitCode"
                continue
            }
            $outLen = (Get-Item -LiteralPath $archiveOutPath -ErrorAction SilentlyContinue).Length
            if (-not $outLen -or $outLen -le 0) {
                $lastFailure = "WinRAR create failed (0 bytes). ExitCode=$exitCode"
                continue
            }

            if ($VerifyAfterCreate) {
                if (-not (Test-WinRARArchive -WinRARPath $WinRARPath -ArchivePath $archiveOutPath)) {
                    $lastFailure = "WinRAR integrity test failed. ExitCode=$exitCode"
                    continue
                }
            }

            Write-FlickFitHost "    -> 完了: $archiveFileName" -ForegroundColor Green
            return $archiveOutPath
        }
    }

    $msg = if ($lastFailure) { $lastFailure } else { "Compression failed (unknown reason)" }
    throw "Compression failed: $baseName - $msg"
}
