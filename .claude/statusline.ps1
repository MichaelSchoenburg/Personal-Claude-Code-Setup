$ErrorActionPreference = 'SilentlyContinue'

$stdin = [Console]::In.ReadToEnd()
$data = $stdin | ConvertFrom-Json

$modelName = $data.model.display_name
$effort = $data.effort.level
$usedPct = $data.context_window.used_percentage

$cwdPath = $data.workspace.current_dir
if (-not $cwdPath) { $cwdPath = $data.cwd }

$esc = [char]27
$reset = "$esc[0m"
$cyan = "$esc[36m"
$yellow = "$esc[33m"
$green = "$esc[32m"
$magenta = "$esc[35m"
$blue = "$esc[34m"
$red = "$esc[31m"
$bold = "$esc[1m"

$parts = New-Object System.Collections.Generic.List[string]

if ($modelName) {
    $parts.Add("$cyan$modelName$reset")
}

if ($effort) {
    $parts.Add("$yellow$effort$reset")
}

# Kontext-Farbe nach ABSOLUTER Tokenzahl (Qualitaetsverlust haengt an der Laenge,
# nicht am Prozentwert des Fensters; Schwellen sind Faustwerte, keine belegten Grenzen).
# Gruen bis CTX_WARN_K, dann Verlauf ueber gelb (CTX_YELLOW_K) nach rot (ab CTX_RED_K).
# 256-Farben-Wuerfel (16 + 36*r + 6*g + b): gruen (0,5,0) -> gelb (5,5,0) -> rot (5,0,0)
$ctxWarnK = 100
$ctxYellowK = 200
$ctxRedK = 400

function Get-ContextColor {
    param([double] $Tokens)
    $k = [Math]::Floor($Tokens / 1000)
    if ($k -lt $ctxWarnK) { return $green }
    if ($k -lt $ctxYellowK) { $step = [int][Math]::Floor(($k - $ctxWarnK) * 5 / ($ctxYellowK - $ctxWarnK)) }          # 0..4
    elseif ($k -lt $ctxRedK) { $step = 5 + [int][Math]::Floor(($k - $ctxYellowK) * 5 / ($ctxRedK - $ctxYellowK)) }   # 5..9
    else { $step = 10 }
    if ($step -le 5) { $r = $step; $g = 5 } else { $r = 5; $g = 10 - $step }
    return "$esc[38;5;$(16 + 36 * $r + 6 * $g)m"
}

if ($null -ne $usedPct) {
    $ctxStr = "{0:N0}% ctx" -f [double]$usedPct
    # total_input_tokens kann kurz 0 sein (z.B. nach /compact); dann aus Prozent x Fenstergroesse ableiten
    $tokens = [double]$data.context_window.total_input_tokens
    if ($tokens -le 0 -and $data.context_window.context_window_size) {
        $tokens = [double]$usedPct * [double]$data.context_window.context_window_size / 100
    }
    $parts.Add("$(Get-ContextColor $tokens)$ctxStr$reset")
}

# Usage-Limits des Abos: liefert Claude Code als rate_limits mit (nur bei
# Subscription-Auth; bei API-Key/Bedrock/Vertex fehlt der Block und die
# Anzeige entfaellt still). used_percentage = 0..100, resets_at = Unix-Sekunden.
function Format-Remaining {
    param([double] $Seconds)
    if ($Seconds -le 0) { return $null }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalDays -ge 1) { return ("{0}d{1}h" -f [int]$ts.TotalDays, $ts.Hours) }
    if ($ts.TotalHours -ge 1) { return ("{0}h{1:00}m" -f [int]$ts.TotalHours, $ts.Minutes) }
    return ("{0}m" -f [int]$ts.TotalMinutes)
}

function Format-Limit {
    param([string] $Label, $Limit)
    if ($null -eq $Limit -or $null -eq $Limit.used_percentage) { return $null }
    $pct = [double]$Limit.used_percentage
    if ($pct -ge 85) { $color = $red } elseif ($pct -ge 60) { $color = $yellow } else { $color = $green }
    $text = "{0:N0}%" -f $pct
    if ($Limit.resets_at) {
        $secs = [double]$Limit.resets_at - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $left = Format-Remaining -Seconds $secs
        if ($left) { $text = "$text/$left" }
    }
    return "${bold}${Label}:${reset} ${color}${text}${reset}"
}

foreach ($limit in @(
    (Format-Limit -Label '5h' -Limit $data.rate_limits.five_hour),
    (Format-Limit -Label '7d' -Limit $data.rate_limits.seven_day),
    (Format-Limit -Label 'spend' -Limit $data.rate_limits.spend_limit)
)) {
    if ($limit) { $parts.Add($limit) }
}

# Project folder name (leaf of cwd)
$projectName = $null
if ($cwdPath) {
    try {
        $projectName = [System.IO.Path]::GetFileName($cwdPath.TrimEnd('\', '/'))
    } catch {
        $projectName = $null
    }
}
if ($projectName) {
    $parts.Add("$magenta$projectName$reset")
}

# Git branch, only if cwd is inside a git repo; skip optional locks; omit silently otherwise
$branch = $null
if ($cwdPath -and (Test-Path -LiteralPath $cwdPath)) {
    try {
        $gitCheck = git --no-optional-locks -C "$cwdPath" rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitCheck -eq 'true') {
            $branchOutput = git --no-optional-locks -C "$cwdPath" branch --show-current 2>$null
            if ($LASTEXITCODE -eq 0 -and $branchOutput) {
                $branch = $branchOutput.Trim()
            }
        }
    } catch {
        $branch = $null
    }
}
if ($branch) {
    $parts.Add("$blue$branch$reset")
}

$line = [string]::Join(" | ", $parts)
Write-Output $line
