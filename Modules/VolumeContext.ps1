#Requires -Version 5.1
<#
.SYNOPSIS
    漫画整理ツール - 巻数・話数判定モジュール
.DESCRIPTION
    Get-VolContext, Get-VolFromParentName, Get-ChapterNumber など
    事前に Utils.ps1 を dot-source すること
#>

# 末尾（N）相当: notmatch 条件と regex の成否を Verbose し、戻り値で分岐再現に使う
function Get-FlickFitTokutoGateState {
    param(
        [string]$Label,
        [string]$InStr,
        [string]$P,
        [string]$Extra = ''
    )
    if ($null -eq $P) { $P = '' }
    $mA = $P -notmatch '第\s*0*(\d{1,3})\s*巻'
    $mB = $P -notmatch '(?i)^(?:vol\.?\s*|v)0*(\d{1,3})(?!\d)'
    $mC = $P -notmatch '(?i)(?:^|[\s\-_])(?:v|vol\.?)\s*0*(\d{1,3})[sSwWbB]?(?:\D|$)'
    $rxT = '[（(]\s*([0-9０-９]{1,3})\s*[）)]\s*相\s*当\s*$'
    $mOk = $P -match $rxT
    $g1 = if ($mOk) { $Matches[1] } else { $null }
    $exS = if ($Extra) { " ($Extra)" } else { '' }
    Write-Verbose "[FlickFit-Tokuto] $Label$exS in='$InStr' p='$P' nm巻=$mA nm^v=$mB nmBndV=$mC tokutoMatch=$mOk m1='$g1'"
    return [pscustomobject]@{
        Nm1  = $mA
        Nm2  = $mB
        Nm3  = $mC
        Ok   = $mOk
        G1   = $g1
    }
}

function Get-VolFromParentName {
    param([string]$ParentName)
    if ([string]::IsNullOrWhiteSpace($ParentName)) { return $null }
    $raw = $ParentName.Trim()
    if (Get-Command Apply-FlickFitUserVolumeTextRules -ErrorAction SilentlyContinue) {
        $raw = Apply-FlickFitUserVolumeTextRules -Text $raw
    }
    $p = Convert-ZenToHan $raw
    Write-Verbose "[FlickFit-Tokuto] Get-VolFromParentName.enter raw='$raw' p='$p'"
    $rng = [char]0xFF5E + [char]0x30FC
    if ($p -match ("第\s*0*(\d{1,3})\s*[-~" + $rng + "]\s*0*(\d{1,3})\s*巻")) { return @{ Start=[int]$Matches[1]; End=[int]$Matches[2]; IsParent=$true } }
    if ($p -match '第\s*0*(\d{1,3})\s*巻') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    if ($p -match '0*(\d{1,3})\s*巻') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    if ($p -match 'その\s*0*(\d{1,3})(?:\s|　|\[|$|\))') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    if ($p -match ("^0*(\d{1,3})\s*[-~" + $rng + "]\s*0*(\d{1,3})[sS]?$")) { return @{ Start=[int]$Matches[1]; End=[int]$Matches[2]; IsParent=$true } }
    if ($p -match ("(?i)(?:vol\.?\s*|vol\s+)0*(\d{1,3})\s*[-~" + $rng + "]\s*0*(\d{1,3})[sS]?")) { return @{ Start=[int]$Matches[1]; End=[int]$Matches[2]; IsParent=$true } }
    # v03b-04 形式: 開始番号直後の s/w/b を許容（範囲パターンは単一巻より先に評価すること）
    if ($p -match ("(?i)(?:^|[\s\-_])(?:v|vol\.?)\s*0*(\d{1,3})[sSwWbB]?\s*[-~" + $rng + "]\s*0*(\d{1,3})[sSwWbB]?")) { return @{ Start=[int]$Matches[1]; End=[int]$Matches[2]; IsParent=$true } }
    # 05s / 5s など（数字＋末尾s/w/b）を単一巻として扱う
    if ($p -match '^0*(\d{1,3})[sSwWbB]?$') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    if ($p -match '^0*(\d{1,3})$') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    if ($p -match '(?i)^(?:vol\.?\s*|v)0*(\d{1,3})(?!\d)') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    if ($p -match '(?i)(?:^|[\s\-_])(?:v|vol\.?)\s*0*(\d{1,3})[sSwWbB]?(?:\D|$)') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    if ($p -match '[（\(]\s*0*(\d{1,3})\s*[）\)]') {
        Write-Verbose "[FlickFit-Tokuto] Get-VolFromParentName.return genericParen(相当より先) p='$p' vol=$([int]$Matches[1])"
        return @{ Vol=[int]$Matches[1]; IsParent=$true }
    }
    # 作品名。１ [メタ情報] 形式（句点の直後の巻番号。Convert-ZenToHan で全角数字は半角になっている）
    if ($p -match '[。．]\s*0*(\d{1,3})(?:\s*\[|\s*$)') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    # 作品名N ～サブタイトル～ 形式（例：作品名1 ～サブタイトル～）
    if ($p -match '[ぁ-んァ-ヶ一-龯]0*(\d{1,3})\s+[～〜]') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    # サブタイトル～N [メタ]（～直後が巻番号の形式）
    if ($p -match '[～〜~]\s*0*(\d{1,3})(?:\s*\[|\s*$)') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    # 作品名 N 形式（[作者] 作品名 13 等。先に日本語1文字→非数字→スペース+数字で巻と誤認しにくくする）
    if ($p -match '[ぁ-んァ-ヶ一-龯々ー][^\d]*\s+0*(\d{1,3})\s*$') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    # 末尾 01f / 12f 形式（単行本巻）
    if ($p -match '\s+0*(\d{1,3})[fF]\s*$') { return @{ Vol=[int]$Matches[1]; IsParent=$true } }
    # フォールバック: 文字列末付近の（N）相当 / (N)相当。第N巻・行頭/境界の v・vol 単独が取れない場合のみ 1 回（汎用括弧等より下位。誤解釈を許容）
    Write-Verbose "[FlickFit-Tokuto] Get-VolFromParentName.atTokutoBranch p='$p' (unreachable if genericParen 等で return 済)"
    $tgP = Get-FlickFitTokutoGateState -Label 'Get-VolFromParentName' -InStr $raw -P $p
    if ($tgP.Nm1 -and $tgP.Nm2 -and $tgP.Nm3 -and $tgP.Ok) {
        $tokutoN = [int](Convert-ZenToHan $tgP.G1.Trim())
        if ($tokutoN -ge 1) {
            Write-Verbose "[FlickFit-Tokuto] Get-VolFromParentName.tokutoReturn vol=$tokutoN"
            return @{ Vol = $tokutoN; IsParent = $true }
        }
        Write-Verbose "[FlickFit-Tokuto] Get-VolFromParentName.tokutoNoReturn tokutoN=$tokutoN (lt1)"
    }
    else {
        Write-Verbose "[FlickFit-Tokuto] Get-VolFromParentName.tokutoNoReturn gateFail nm123=$($tgP.Nm1),$($tgP.Nm2),$($tgP.Nm3) ok=$($tgP.Ok) m1=$($tgP.G1)"
    }
    return $null
}

<#
.SYNOPSIS
    祖先フォルダ名から「話」モードの手がかり（ch360-391 等のスパン、語彙）を取得する。
#>
function Get-AncestorChapterSignals {
    param([string[]]$PathPartsReversed)
    $spanLo = $null
    $spanHi = $null
    $lexChapter = 0
    $lexVolume = 0
    if (-not $PathPartsReversed -or $PathPartsReversed.Count -lt 2) {
        return [PSCustomObject]@{ SpanLo=$spanLo; SpanHi=$spanHi; LexChapter=$lexChapter; LexVolume=$lexVolume }
    }
    for ($i = 1; $i -lt $PathPartsReversed.Count; $i++) {
        $rawSeg = $PathPartsReversed[$i].Trim()
        if (Get-Command Apply-FlickFitUserVolumeTextRules -ErrorAction SilentlyContinue) {
            $rawSeg = Apply-FlickFitUserVolumeTextRules -Text $rawSeg
        }
        $seg = Convert-ZenToHan $rawSeg
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        # ch360-391 / ch 360-391 / CH360～391（波ダッシュは \u301C / \uFF5E で指定）
        if ($seg -match '(?i)ch\s*(\d{1,4})\s*(?:\-|~|\u301C|\uFF5E)\s*(\d{1,4})') {
            $spanLo = [int]$Matches[1]; $spanHi = [int]$Matches[2]
        }
        if ($seg -match '(?i)raw\s*chapter|(?i)\braw\s+ch\.?\s*\d|(?i)\bchapter\s*\d|(?i)\bchap\b|第\s*\d+\s*話|話数|episode\s*\d') { $lexChapter++ }
        if ($seg -match '(?i)(?:^|[\s\-_])v\d{1,3}(?:-\d{1,3})?[sSwWbB]?(?:\D|$)|第\s*\d+\s*巻|(?i)\bvol\.?\s*\d') { $lexVolume++ }
    }
    return [PSCustomObject]@{ SpanLo=$spanLo; SpanHi=$spanHi; LexChapter=$lexChapter; LexVolume=$lexVolume }
}

function Get-ChapterNumber {
    param([string]$Name)
    if (Get-Command Ensure-FlickFitVolumePatternRegexes -ErrorAction SilentlyContinue) { Ensure-FlickFitVolumePatternRegexes }
    if ($null -eq $script:FlickFitRegexChapterSourceNumeric) {
        $script:FlickFitRegexChapterSourceNumeric = '(?!)'
    }
    $displayName = $Name
    if (Get-Command Apply-FlickFitUserVolumeTextRules -ErrorAction SilentlyContinue) {
        $displayName = Apply-FlickFitUserVolumeTextRules -Text $Name
    }
    $normalizedName = Convert-FullWidthToHalfWidth $displayName
    if ($normalizedName -match '(?i)chapter\s*0*(\d+(?:\.\d+)?)') { return [double]$Matches[1] }
    if ($normalizedName -match '(?i)chap\s*0*(\d+(?:\.\d+)?)\s*話?') { return [double]$Matches[1] }
    if ($normalizedName -match '第\s*0*(\d+(?:\.\d+)?)\s*話') { return [double]$Matches[1] }
    if ($normalizedName -match '0*(\d+(?:\.\d+)?)\s*話') { return [double]$Matches[1] }
    if ($normalizedName -match '[-_](\d+)_files') { return [double]$Matches[1] }
    if ($normalizedName -match $script:FlickFitRegexChapterSourceNumeric) { return [double]$Matches[1] }
    if ($normalizedName -match '[-_](\d+)[-_]') { return [double]$Matches[1] }
    if ($normalizedName -match '[（\(]0*(\d+(?:\.\d+)?)[）\)]') { return [double]$Matches[1] }
    if ($normalizedName -match '(\d+)(?:\.\d+)?(?:[^0-9]*$)') { return [double]$Matches[1] }
    return 99999
}

function Get-AncestorVolumeHint {
    param([string[]]$PathPartsReversed)
    if (-not $PathPartsReversed -or $PathPartsReversed.Count -lt 2) { return $null }
    for ($i = 1; $i -lt $PathPartsReversed.Count; $i++) {
        $name = $PathPartsReversed[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $pv = Get-VolFromParentName $name
        if (-not $pv) { continue }
        $pvVol = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol')) { $pv['Vol'] } elseif ($pv) { try { $pv.Vol } catch { $null } } else { $null }
        $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
        $pvEnd = if ($pv -is [hashtable] -and $pv.ContainsKey('End')) { $pv['End'] } else { $null }
        if ($null -ne $pvVol) {
            return @{ Vol = $pvVol; Start = $null; End = $null }
        }
        if ($null -ne $pvStart -and $null -ne $pvEnd) {
            if ($pvStart -eq $pvEnd) {
                return @{ Vol = [int]$pvStart; Start = $null; End = $null }
            }
            return @{ Vol = $null; Start = [int]$pvStart; End = [int]$pvEnd }
        }
    }
    return $null
}

function Add-AncestorVolumeToChapterCtx {
    param(
        [PSCustomObject]$Ctx,
        [string[]]$PathPartsReversed
    )
    if ($Ctx.Type -ne 'Chapter' -and $Ctx.Type -ne 'ChapterRange') { return $Ctx }
    if ($Ctx.PSObject.Properties['Vol'] -and $null -ne $Ctx.Vol) { return $Ctx }
    if ($Ctx.PSObject.Properties['VolStart'] -and $Ctx.PSObject.Properties['VolEnd'] -and $null -ne $Ctx.VolStart -and $null -ne $Ctx.VolEnd) { return $Ctx }
    $hint = Get-AncestorVolumeHint $PathPartsReversed
    if (-not $hint) { return $Ctx }
    if ($null -ne $hint.Vol) {
        $Ctx | Add-Member -NotePropertyName 'Vol' -NotePropertyValue $hint.Vol -Force
    }
    else {
        $Ctx | Add-Member -NotePropertyName 'VolStart' -NotePropertyValue $hint.Start -Force
        $Ctx | Add-Member -NotePropertyName 'VolEnd' -NotePropertyValue $hint.End -Force
    }
    return $Ctx
}

function Get-VolContext {
    param(
        [string]$Path,
        [double]$SiblingChapterRatio = -1.0
    )
    if (Get-Command Ensure-FlickFitVolumePatternRegexes -ErrorAction SilentlyContinue) { Ensure-FlickFitVolumePatternRegexes }
    if ($null -eq $script:FlickFitRegexVolumeSourceFolderId) {
        $script:FlickFitRegexVolumeSourceFolderId = '(?!)'
    }
    $parts = $Path.Split([System.IO.Path]::DirectorySeparatorChar)
    [array]::Reverse($parts)
    $selfRaw = $parts[0].Trim()
    if (Get-Command Apply-FlickFitUserVolumeTextRules -ErrorAction SilentlyContinue) {
        $selfRaw = Apply-FlickFitUserVolumeTextRules -Text $selfRaw
    }
    $self = Convert-ZenToHan $selfRaw
    Write-Verbose "[FlickFit-Tokuto] Get-VolContext.enter path='$Path' selfRaw='$selfRaw' selfP='$self'"
    $anc = Get-AncestorChapterSignals $parts
    
    # coverフォルダは特別扱い（巻数判定から完全に除外）
    # $script:CoverFolderNameLikeRegex（Config.ps1）＋サイト由来の #cover 等
    if ($self -match $script:CoverFolderNameLikeRegex -or
        $self -match '(?i)^[^\-_]+[-_](#?cover|0)$' -or
        $self -match '(?i)#cover') {
        return [PSCustomObject]@{ Type='Cover'; Name=$self }
    }
    
    # 子フォルダ名に「第XX巻」が含まれている場合は、その番号を優先（親フォルダが範囲でも）
    if ($self -match '第\s*0*(\d{1,3})\s*巻') {
        return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self }
    }
    
    # 話数フォルダを先にチェック（親フォルダの巻判定より優先）
    # 第XX-YY話 / Chapter XX-YY 形式の話数範囲フォルダは 'ChapterRange' タイプとして返す
    if ($self -match '第\s*0*(\d+(?:\.\d+)?)\s*(?:\-|~|\u301C|\uFF5E)\s*0*(\d+(?:\.\d+)?)\s*話') {
        $vol = $null
        if ($parts.Count -ge 2) {
            $pv = Get-VolFromParentName $parts[1]
            if (-not $pv -and $parts.Count -ge 3) { $pv = Get-VolFromParentName $parts[2] }
            $pvVol   = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol'))   { $pv['Vol'] }   else { $null }
            $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
            $pvEnd   = if ($pv -is [hashtable] -and $pv.ContainsKey('End'))   { $pv['End'] }   else { $null }
            if ($null -ne $pvVol) { $vol = $pvVol }
            elseif ($null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -eq $pvEnd) { $vol = $pvStart }
        }
        $o = [PSCustomObject]@{ Type='ChapterRange'; ChStart=$Matches[1]; ChEnd=$Matches[2]; Name=$self }
        if ($null -ne $vol) { $o | Add-Member -NotePropertyName 'Vol' -NotePropertyValue $vol -Force }
        return (Add-AncestorVolumeToChapterCtx $o $parts)
    }
    if ($self -match '(?i)chapter\s*0*(\d+(?:\.\d+)?)\s*(?:\-|~|\u301C|\uFF5E)\s*0*(\d+(?:\.\d+)?)') {
        $vol = $null
        if ($parts.Count -ge 2) {
            $pv = Get-VolFromParentName $parts[1]
            if (-not $pv -and $parts.Count -ge 3) { $pv = Get-VolFromParentName $parts[2] }
            $pvVol   = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol'))   { $pv['Vol'] }   else { $null }
            $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
            $pvEnd   = if ($pv -is [hashtable] -and $pv.ContainsKey('End'))   { $pv['End'] }   else { $null }
            if ($null -ne $pvVol) { $vol = $pvVol }
            elseif ($null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -eq $pvEnd) { $vol = $pvStart }
        }
        $o = [PSCustomObject]@{ Type='ChapterRange'; ChStart=$Matches[1]; ChEnd=$Matches[2]; Name=$self }
        if ($null -ne $vol) { $o | Add-Member -NotePropertyName 'Vol' -NotePropertyValue $vol -Force }
        return (Add-AncestorVolumeToChapterCtx $o $parts)
    }
    # Chapter XX / chap XX / 第XX話 / XX話 形式の話数フォルダは 'Chapter' タイプとして返す
    if ($self -match '第\s*0*(\d+(?:\.\d+)?)\s*話') {
        $vol = $null
        if ($parts.Count -ge 2) {
            $pv = Get-VolFromParentName $parts[1]
            if (-not $pv -and $parts.Count -ge 3) { $pv = Get-VolFromParentName $parts[2] }
            $pvVol   = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol'))   { $pv['Vol'] }   else { $null }
            $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
            $pvEnd   = if ($pv -is [hashtable] -and $pv.ContainsKey('End'))   { $pv['End'] }   else { $null }
            if ($null -ne $pvVol) { $vol = $pvVol }
            elseif ($null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -eq $pvEnd) { $vol = $pvStart }
        }
        $o = [PSCustomObject]@{ Type='Chapter'; ChNum=$Matches[1]; Name=$self }
        if ($null -ne $vol) { $o | Add-Member -NotePropertyName 'Vol' -NotePropertyValue $vol -Force }
        return (Add-AncestorVolumeToChapterCtx $o $parts)
    }
    if ($self -match '(?i)chapter\s*0*(\d+(?:\.\d+)?)') {
        $vol = $null
        if ($parts.Count -ge 2) {
            $pv = Get-VolFromParentName $parts[1]
            if (-not $pv -and $parts.Count -ge 3) { $pv = Get-VolFromParentName $parts[2] }
            $pvVol   = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol'))   { $pv['Vol'] }   else { $null }
            $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
            $pvEnd   = if ($pv -is [hashtable] -and $pv.ContainsKey('End'))   { $pv['End'] }   else { $null }
            if ($null -ne $pvVol) { $vol = $pvVol }
            elseif ($null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -eq $pvEnd) { $vol = $pvStart }
        }
        $o = [PSCustomObject]@{ Type='Chapter'; ChNum=$Matches[1]; Name=$self }
        if ($null -ne $vol) { $o | Add-Member -NotePropertyName 'Vol' -NotePropertyValue $vol -Force }
        return (Add-AncestorVolumeToChapterCtx $o $parts)
    }
    if ($self -match '(?i)chap\s*0*(\d+(?:\.\d+)?)\s*話?') {
        $vol = $null
        if ($parts.Count -ge 2) {
            $pv = Get-VolFromParentName $parts[1]
            if (-not $pv -and $parts.Count -ge 3) { $pv = Get-VolFromParentName $parts[2] }
            $pvVol   = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol'))   { $pv['Vol'] }   else { $null }
            $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
            $pvEnd   = if ($pv -is [hashtable] -and $pv.ContainsKey('End'))   { $pv['End'] }   else { $null }
            if ($null -ne $pvVol) { $vol = $pvVol }
            elseif ($null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -eq $pvEnd) { $vol = $pvStart }
        }
        $o = [PSCustomObject]@{ Type='Chapter'; ChNum=$Matches[1]; Name=$self }
        if ($null -ne $vol) { $o | Add-Member -NotePropertyName 'Vol' -NotePropertyValue $vol -Force }
        return (Add-AncestorVolumeToChapterCtx $o $parts)
    }
    if ($self -match '0*(\d+(?:\.\d+)?)\s*話') {
        $vol = $null
        if ($parts.Count -ge 2) {
            $pv = Get-VolFromParentName $parts[1]
            if (-not $pv -and $parts.Count -ge 3) { $pv = Get-VolFromParentName $parts[2] }
            $pvVol   = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol'))   { $pv['Vol'] }   else { $null }
            $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
            $pvEnd   = if ($pv -is [hashtable] -and $pv.ContainsKey('End'))   { $pv['End'] }   else { $null }
            if ($null -ne $pvVol) { $vol = $pvVol }
            elseif ($null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -eq $pvEnd) { $vol = $pvStart }
        }
        $o = [PSCustomObject]@{ Type='Chapter'; ChNum=$Matches[1]; Name=$self }
        if ($null -ne $vol) { $o | Add-Member -NotePropertyName 'Vol' -NotePropertyValue $vol -Force }
        return (Add-AncestorVolumeToChapterCtx $o $parts)
    }
    
    if ($self -match '^\s*0*(\d{1,4})\s*(?:\-|~|\u301C|\uFF5E)\s*0*(\d{1,4})\s*$') {
        $ra = [int]$Matches[1]; $rb = [int]$Matches[2]
        $lo = [Math]::Min($ra, $rb); $hi = [Math]::Max($ra, $rb)
        $mag = [Math]::Max($ra, $rb)
        $preferCh = $false
        if ($null -ne $anc.SpanLo -and $null -ne $anc.SpanHi -and $lo -le $anc.SpanHi -and $hi -ge $anc.SpanLo) { $preferCh = $true }
        elseif ($mag -ge 80) { $preferCh = $true }
        elseif ($anc.LexChapter -gt $anc.LexVolume -and $mag -ge 50) { $preferCh = $true }
        elseif ($SiblingChapterRatio -ge 0.35 -and $mag -ge 40) { $preferCh = $true }
        if ($preferCh) {
            $o = [PSCustomObject]@{ Type='ChapterRange'; ChStart=$ra.ToString(); ChEnd=$rb.ToString(); Name=$self }
            if ($ra -gt $rb) { $o | Add-Member -NotePropertyName 'RangeOrderInvalid' -NotePropertyValue $true -Force }
            if ($null -ne $anc.SpanLo -and $null -ne $anc.SpanHi -and ($lo -lt $anc.SpanLo -or $hi -gt $anc.SpanHi)) {
                $o | Add-Member -NotePropertyName 'OutsideAncestorSpan' -NotePropertyValue $true -Force
            }
            return (Add-AncestorVolumeToChapterCtx $o $parts)
        }
    }
    
    if ($parts.Count -ge 2) {
        $parent = Convert-ZenToHan $parts[1]
        $parentIsCoverFolder = $parent -match $script:CoverFolderNameLikeRegex -or $parent -match '(?i)^[^\-_]+[-_](#?cover|0)$'
        if ($parentIsCoverFolder -and $parts.Count -ge 3) {
            $grandParent = Convert-ZenToHan $parts[2]
            $gpv = Get-VolFromParentName $grandParent
            $gpvVol = if ($gpv -is [hashtable] -and $gpv.ContainsKey('Vol')) { $gpv['Vol'] } elseif ($gpv) { try { $gpv.Vol } catch { $null } } else { $null }
            if ($gpv -and $null -ne $gpvVol) { return [PSCustomObject]@{ Type='Single'; Vol=$gpvVol; Name=$self } }
            $gpvStart = if ($gpv -is [hashtable] -and $gpv.ContainsKey('Start')) { $gpv['Start'] } else { $null }
            $gpvEnd   = if ($gpv -is [hashtable] -and $gpv.ContainsKey('End')) { $gpv['End'] } else { $null }
            if ($gpv -and $null -ne $gpvStart -and $null -ne $gpvEnd -and $gpvStart -eq $gpvEnd) { return [PSCustomObject]@{ Type='Single'; Vol=$gpvStart; Name=$self } }
        }
        # 子フォルダ名の「そのX」を優先（親のレベル99等より巻数として正しい）
        if ($self -match 'その\s*0*(\d{1,3})(?:\s|　|\[|$|\))') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        $pv = Get-VolFromParentName $parent
        if (-not $pv -and $parts.Count -ge 3) { $pv = Get-VolFromParentName $parts[2] }
        $pvVol = if ($pv -is [hashtable] -and $pv.ContainsKey('Vol')) { $pv['Vol'] } elseif ($pv) { try { $pv.Vol } catch { $null } } else { $null }
        if ($pv -and $null -ne $pvVol) {
            # サイト由来のID形式: 親の巻を継承（子の数字を巻と誤認しない）
            if ($self -match $script:FlickFitRegexVolumeSourceFolderId) {
                return [PSCustomObject]@{ Type='Single'; Vol=$pvVol; Name=$self }
            }
            if ($self -match '^(\d+(?:\.\d+)?)_[a-zA-Z]' -or $self -match '[-_](\d+(?:\.\d+)?)_files$') {
                $chNum = if ($self -match '^(\d+(?:\.\d+)?)_') { $Matches[1] } else { $Matches[1] }
                $co = [PSCustomObject]@{ Type='Chapter'; Vol=$pvVol; ChNum=$chNum; Name=$self }
                return (Add-AncestorVolumeToChapterCtx $co $parts)
            }
            if ($self -match '^\s*0*(\d{1,4})\s*$') {
                $chDigits = $Matches[1]
                $n = [int]$chDigits
                if ($n -ne $pvVol) {
                    $parentScan = $parent -match '(?i)v\d{1,3}[sSwW](?:\D|$)'
                    $likelyCh = $false
                    if ($n -ge 100) { $likelyCh = $true }
                    elseif ($parentScan -and $n -gt 50) { $likelyCh = $true }
                    elseif ($n -gt $pvVol + 45) { $likelyCh = $true }
                    elseif ($null -ne $anc.SpanLo -and $null -ne $anc.SpanHi -and $n -ge $anc.SpanLo -and $n -le $anc.SpanHi) { $likelyCh = $true }
                    elseif ($SiblingChapterRatio -ge 0.35 -and $n -ge 30) { $likelyCh = $true }
                    if ($likelyCh) {
                        $co = [PSCustomObject]@{ Type='Chapter'; Vol=$pvVol; ChNum=$chDigits; Name=$self }
                        return (Add-AncestorVolumeToChapterCtx $co $parts)
                    }
                }
            }
            return [PSCustomObject]@{ Type='Single'; Vol=$pvVol; Name=$self }
        }
        $pvStart = if ($pv -is [hashtable] -and $pv.ContainsKey('Start')) { $pv['Start'] } else { $null }
        $pvEnd   = if ($pv -is [hashtable] -and $pv.ContainsKey('End')) { $pv['End'] } else { $null }
        if ($pv -and $null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -eq $pvEnd) { return [PSCustomObject]@{ Type='Single'; Vol=$pvStart; Name=$self } }
        if ($pv -and $null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -ne $pvEnd) {
            # 親が範囲の場合: 子の 第N巻 / v・vol 単独のあと、（N）相当はフォールバック 1 回、それ以外は先頭側の (N) を試す
            $tokutoSkipChild = $self -match '第\s*0*(\d{1,3})\s*巻' -or
                $self -match '(?i)^(?:vol\.?\s*|v)0*(\d{1,3})(?!\d)' -or
                $self -match '(?i)(?:^|[\s\-_])(?:v|vol\.?)\s*0*(\d{1,3})[sSwWbB]?(?:\D|$)'
            $tgK = Get-FlickFitTokutoGateState -Label 'Get-VolContext.parentRange' -InStr $selfRaw -P $self -Extra "skipCh=$tokutoSkipChild"
            if (-not $tokutoSkipChild -and $tgK.Nm1 -and $tgK.Nm2 -and $tgK.Nm3 -and $tgK.Ok) {
                $volInParen = [int](Convert-ZenToHan $tgK.G1.Trim())
                if ($volInParen -ge $pvStart -and $volInParen -le $pvEnd) {
                    Write-Verbose "[FlickFit-Tokuto] Get-VolContext.parentRange return tokuto vol=$volInParen in=[$pvStart..$pvEnd]"
                    return [PSCustomObject]@{ Type='Single'; Vol=$volInParen; Name=$self }
                }
                Write-Verbose "[FlickFit-Tokuto] Get-VolContext.parentRange tokutoDropped vol=$volInParen notIn=[$pvStart..$pvEnd]"
            }
            if ($self -match '[（\(]\s*0*(\d{1,3})\s*[）\)]') {
                $volInParen = [int]$Matches[1]
                if ($volInParen -ge $pvStart -and $volInParen -le $pvEnd) {
                    return [PSCustomObject]@{ Type='Single'; Vol=$volInParen; Name=$self }
                }
            }
            if ($self -match '[-_]([ぁ-んァ-ヶ一-龯々ー]{2,})[-_\s]*(?:\([^)]*\))?\s*$') {
                $suffix = $Matches[1].Trim()
                if ($suffix -and $suffix -notmatch '^(cover|表紙|カバー|raw|おまけ)') {
                    return [PSCustomObject]@{ Type='Special'; Suffix=$suffix; Name=$self }
                }
            }
        }
        # 親フォルダが巻範囲 (v01-03 / vol 05-10 等) を示す場合、子名末尾の数字を巻候補として解釈
        if ($pv -and $null -ne $pvStart -and $null -ne $pvEnd -and $pvStart -lt $pvEnd) {
            $childVol = $null
            if ($self -match '^\s*0*(\d{1,3})\s*[wWsSbBfF]?\s*$') { $childVol = [int]$Matches[1] }
            elseif ($self -match '.*?0*(\d{1,3})\s*[wWsSbBfF]?\s*$') { $childVol = [int]$Matches[1] }
            if ($null -ne $childVol -and $childVol -ge $pvStart -and $childVol -le $pvEnd) {
                return [PSCustomObject]@{ Type='Single'; Vol=$childVol; Name=$self }
            }
        }
    }
    
    $isSpecial = $self -match '(?i)^(chapter|chap|ch\d|episode|ep\d|raw|おまけ)'
    $rng = [char]0xFF5E + [char]0x30FC
    if (-not $isSpecial) {
        # フォルダ名末尾の v04s / v04 を最優先（親が範囲 v03-05s でも子の v04s を第4巻にする）
        if ($self -match '(?i)\bv0*(\d{1,3})[sSwWbBfF]?\s*$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match ("(?i)(?:第|vol\.?\s*|v)\s*0*(\d{1,3})\s*[-~" + $rng + "]\s*0*(\d{1,3})")) { return [PSCustomObject]@{ Type='Range'; Start=[int]$Matches[1]; End=[int]$Matches[2]; Name=$self } }
        # vol / 第（巻含む上段で未処理の単独巻）を、括弧列・（N）相当より先に
        if ($self -match ("(?i)(?:vol\.?\s*|v(?=\d))\s*0*(\d{1,3})(?![-~" + $rng + "]|\s*話)")) { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match ("(?i)第\s*0*(\d{1,3})(?![-~" + $rng + "]|\s*話)(?!特別|[大小中]隊|連隊|師団|旅団|部隊|軍|章|期|編|幕|話|巻)")) { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        # （N）/ (N) はコミックタイトル末尾の巻表記で多い → 最後の一致を優先（先頭に現れる「第○○…」形式より末尾の括弧を優先）
        $parenVolMs = [regex]::Matches($self, '[（\(]\s*0*(\d{1,3})\s*[）\)]')
        if ($parenVolMs.Count -gt 0) {
            $pvParen = [int]$parenVolMs[$parenVolMs.Count - 1].Groups[1].Value
            if ($pvParen -ge 1) { return [PSCustomObject]@{ Type='Single'; Vol=$pvParen; Name=$self } }
        }
        if ($self -match '(?i)[_\-]v0*(\d{1,3})[wWsSbBfF]?$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[_\-]0*(\d{1,3})[wWsSbBfF]?$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[：:][\s　]*0*(\d{1,3})\s*(?:[（\(][^）\)]*[）\)])?\s*$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '(?<![：:\d])\s+0*(\d{1,3})[fF]\s*$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '(?<![：:\d])\s+0*(\d{1,3})\s*[wWsSbBfF]?\s*(?:[（\(][^）\)]*[）\)])?\s*$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match 'その\s*0*(\d{1,3})(?:\s|　|\[|$|\))') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '0*(\d{1,3})\s*巻') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[ぁ-んァ-ヶ一-龯]\s+0*(\d{1,3})\s+[ぁ-んァ-ヶ一-龯]') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[\]）\)]\s*[^\[\]]+\s+0*(\d{1,3})\s*\[') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '\p{L}0*(\d{1,3})\s*\[') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '\]\s*[^[\]]+?\s+0*(\d{1,3})\s+\[') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[!！]\s*0*(\d{1,3})\s*$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[～〜~]\s*0*(\d{1,3})(?:\s*\[|\s*$)') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[ぁ-んァ-ヶ一-龯]0*(\d{1,3})\s+[～〜]') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[ぁ-んァ-ヶ一-龯]0*(\d{1,3})\s*$') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        if ($self -match '[。．]\s*0*(\d{1,3})(?:\s*\[|\s*$)') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        $tgS = Get-FlickFitTokutoGateState -Label 'Get-VolContext.self' -InStr $selfRaw -P $self
        if ($tgS.Nm1 -and $tgS.Nm2 -and $tgS.Nm3 -and $tgS.Ok) {
            $tv = [int](Convert-ZenToHan $tgS.G1.Trim())
            if ($tv -ge 1) {
                Write-Verbose "[FlickFit-Tokuto] Get-VolContext.self return tokuto vol=$tv"
                return [PSCustomObject]@{ Type = 'Single'; Vol = $tv; Name = $self }
            }
            Write-Verbose "[FlickFit-Tokuto] Get-VolContext.self tokutoNoReturn tv=$tv (lt1)"
        }
        else {
            Write-Verbose "[FlickFit-Tokuto] Get-VolContext.self tokutoGate skip nm=$($tgS.Nm1),$($tgS.Nm2),$($tgS.Nm3) ok=$($tgS.Ok)"
        }
    }
    if ($parts.Count -gt 1) {
        $parent = Convert-ZenToHan $parts[1]
        if ($parent -notmatch '(?i)(chapter|chap|ch|episode|ep|raw|cover|表紙|おまけ)') {
            if ($parent -match ("(?i)(?:vol\.?\s*|v(?=\d))\s*0*(\d{1,3})(?![-~" + $rng + "])")) { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
            if ($parent -match ("(?i)第\s*0*(\d{1,3})(?![-~" + $rng + "])(?!特別|[大小中]隊|連隊|師団|旅団|部隊|軍|章|期|編|幕|話|巻)")) { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
            $prRaw = if ($null -ne $parts[1]) { $parts[1].Trim() } else { '' }
            $tgPr = Get-FlickFitTokutoGateState -Label 'Get-VolContext.parent' -InStr $prRaw -P $parent
            if ($tgPr.Nm1 -and $tgPr.Nm2 -and $tgPr.Nm3 -and $tgPr.Ok) {
                $pvTok = [int](Convert-ZenToHan $tgPr.G1.Trim())
                if ($pvTok -ge 1) {
                    Write-Verbose "[FlickFit-Tokuto] Get-VolContext.parentFallback return tokuto vol=$pvTok in='$prRaw' p='$parent'"
                    return [PSCustomObject]@{ Type = 'Single'; Vol = $pvTok; Name = $self }
                }
                Write-Verbose "[FlickFit-Tokuto] Get-VolContext.parentFallback tokutoNoReturn pvTok=$pvTok (lt1)"
            }
            else {
                Write-Verbose "[FlickFit-Tokuto] Get-VolContext.parentFallback tokutoGate skip nm=$($tgPr.Nm1),$($tgPr.Nm2),$($tgPr.Nm3) ok=$($tgPr.Ok)"
            }
            if ($parent -match '[（\(]\s*0*(\d{1,3})\s*[）\)]') { return [PSCustomObject]@{ Type='Single'; Vol=[int]$Matches[1]; Name=$self } }
        }
    }
    # フラット構造: 作品名 日本語サブタイトル（巻数なし）→ 特別巻
    if ($self -match '[\s\-_]([ぁ-んァ-ヶ一-龯々ー]{2,})\s*$') {
        $suffix = $Matches[1].Trim()
        if ($suffix -and $suffix -notmatch '^(cover|表紙|カバー|raw|おまけ)$' -and $suffix -notmatch '\d.*巻|巻|第\d') {
            return [PSCustomObject]@{ Type='Special'; Suffix=$suffix; Name=$self }
        }
    }
    if ($self -match $script:FlickFitRegexVolCtxCoverLine1 -or $self -match $script:FlickFitRegexVolCtxCoverLine2) {
        return [PSCustomObject]@{ Type='Cover'; Name=$self }
    }
    return [PSCustomObject]@{ Type='Unknown'; Name=$parts[0] }
}

function Get-RealRoot {
    param([string]$Path)
    $curr = $Path
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    while ($visited.Add($curr)) {
        try {
            $dirs = @(Get-ChildItem -LiteralPath $curr -Directory -ErrorAction SilentlyContinue)
            # 作業用・出力先は「中身の1階層だけ」として潜らない（再開時に _unpacked 内へ realRoot が固定されるのを防ぐ）
            $dirs = @($dirs | Where-Object {
                    $_.Name -notmatch '^(?i)_unpacked$' -and $_.Name -notmatch '^(?i)_output$'
                })
            $imgs = @(Get-ChildItem -LiteralPath $curr -File -ErrorAction SilentlyContinue | Where-Object { $script:ImageExtensions -contains $_.Extension.ToLower() })
            if ($imgs.Count -eq 0 -and $dirs.Count -eq 1) { $curr = $dirs[0].FullName } else { break }
        } catch {
            Write-FlickFitHost "    [警告]: フォルダアクセスエラー: $curr" -ForegroundColor Yellow; break
        }
    }
    return $curr
}

# リーフ走査から除外（再開時に _unpacked 内の EPUB 構造や、_output 内を巻候補に混ぜない）
function Test-FlickFitExcludedLeafScanPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $true
    }
    if ($full -match '(?i)[\\/]_unpacked([\\/]|$)') { return $true }
    if ($full -match '(?i)[\\/]_output([\\/]|$)') { return $true }
    return $false
}

# 再開時（STEP1 以外からの継続）に、STEP4 済みの巻フォルダをリーフ候補から外す（重複誤検知防止）
# 判定は Convert-ZenToHan 後の名前に対し、巻サフィックス表現＋ Get-VolFromParentName（短い名前のみ）で揃える
function Test-FlickFitResumeExcludeVolumeOutputLeafName {
    param([string]$FolderName)
    if (-not (Get-Variable -Name ResumeFromStep -Scope Script -ErrorAction SilentlyContinue)) { return $false }
    try {
        $rs = [int]$script:ResumeFromStep
    } catch {
        return $false
    }
    if ($rs -le 1) { return $false }
    if ([string]::IsNullOrWhiteSpace($FolderName)) { return $false }
    $n = if (Get-Command Convert-ZenToHan -ErrorAction SilentlyContinue) {
        Convert-ZenToHan $FolderName.Trim()
    } else {
        $FolderName.Trim()
    }

    $bracketed = $n -match '^\[[^\]]+\]\s*.+$'

    if ($bracketed) {
        if ($n -match '第\s*0*\d{1,3}\s*巻\s*$') { return $true }
        if ($n -match '(?i)vol\.?\s*0*\d{1,3}\s*$') { return $true }
        if ($n -match '(?i)vol\s+0*\d{1,3}\s*$') { return $true }
        if ($n -match '(?i)(?:[\s\-_]|^)v\s*0*\d{1,3}\s*$') { return $true }
    }

    if ($n -match '^第\s*0*\d{1,3}\s*巻\s*$') { return $true }
    if ($n -match '^0*\d{1,3}\s*巻\s*$') { return $true }
    if ($n -match '(?i)^vol\.?\s*0*\d{1,3}\s*$') { return $true }
    if ($n -match '(?i)^vol\s+0*\d{1,3}\s*$') { return $true }
    if ($n -match '(?i)^v\s*0*\d{1,3}\s*$') { return $true }

    # 上記パターンに当たらないが、Get-VolFromParentName が「単一巻」だけ取れ、名前全体がその巻表記に一致する場合
    $vc = Get-VolFromParentName $n
    if ($null -eq $vc -or -not $vc.IsParent) { return $false }
    if ($vc.ContainsKey('Start')) { return $false }
    if (-not $vc.ContainsKey('Vol') -or $null -eq $vc['Vol']) { return $false }
    $vNum = [int]$vc['Vol']
    if ($n.Length -gt 48) {
        Write-FlickFitHost "      [再開・除外判定スキップ] 48文字超のため Get-VolFromParentName フォールバック照合を省略: $FolderName" -ForegroundColor DarkGray
        return $false
    }

    if ($n -match '^第\s*0*(\d{1,3})\s*巻\s*$' -and [int]$Matches[1] -eq $vNum) { return $true }
    if ($n -match '^0*(\d{1,3})\s*巻\s*$' -and [int]$Matches[1] -eq $vNum) { return $true }
    if ($n -match '(?i)^vol\.?\s*0*(\d{1,3})\s*$' -and [int]$Matches[1] -eq $vNum) { return $true }
    if ($n -match '(?i)^vol\s+0*(\d{1,3})\s*$' -and [int]$Matches[1] -eq $vNum) { return $true }
    if ($n -match '(?i)^v\s*0*(\d{1,3})\s*$' -and [int]$Matches[1] -eq $vNum) { return $true }
    return $false
}

function Get-LeafFolders {
    <#
      再開候補専用は -ResumeInputCandidateFilter（_unpacked / _output を除外、単ページ以外は従来どおり除外）。
      初回の STEP2 構造解析では付けない（_unpacked 内の巻を拾う必要があるため両モード要存続）。
    #>
    param(
        [string]$Path,
        # 再開時の重複候補・フォールバック列挙専用。初回 STEP2 の構造解析では指定しない（EPUB 解凍先 _unpacked 内の画像を拾うため）
        [switch]$ResumeInputCandidateFilter
    )
    $results = [System.Collections.Generic.List[PSObject]]::new()
    if ($ResumeInputCandidateFilter -and (Test-FlickFitExcludedLeafScanPath -Path $Path)) { return $results }
    try {
        $subDirs = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue)
        # 「単ページ」は見開き分割用のため巻のリーフとして扱わない
        if ($ResumeInputCandidateFilter) {
            $subDirs = @($subDirs | Where-Object {
                    $_.Name -ne '単ページ' -and
                    $_.Name -notmatch '^(?i)_unpacked$' -and
                    $_.Name -notmatch '^(?i)_output$'
                })
        } else {
            $subDirs = @($subDirs | Where-Object { $_.Name -ne '単ページ' })
        }
        $imgs = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue | Where-Object { $script:ImageExtensions -contains $_.Extension.ToLower() })
        if ($subDirs.Count -eq 0) {
            if ($imgs.Count -gt 0) {
                $ln = Split-Path $Path -Leaf
                $skipLeaf = $ResumeInputCandidateFilter -and (Test-FlickFitResumeExcludeVolumeOutputLeafName -FolderName $ln)
                if (-not $skipLeaf) {
                    $results.Add([PSCustomObject]@{ Path=$Path; Name=$ln })
                }
            }
        } else {
            foreach ($sd in $subDirs) {
                foreach ($leaf in (Get-LeafFolders -Path $sd.FullName -ResumeInputCandidateFilter:$ResumeInputCandidateFilter)) { $results.Add($leaf) }
            }
            if ($imgs.Count -gt 0) {
                $ln = Split-Path $Path -Leaf
                $skipLeaf = $ResumeInputCandidateFilter -and (Test-FlickFitResumeExcludeVolumeOutputLeafName -FolderName $ln)
                if (-not $skipLeaf) {
                    $results.Add([PSCustomObject]@{ Path=$Path; Name=$ln })
                }
            }
        }
    } catch { Write-FlickFitHost "    [警告]: フォルダ走査エラー: $Path" -ForegroundColor Yellow }
    return $results
}
