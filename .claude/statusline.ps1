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

if ($null -ne $usedPct) {
    $ctxStr = "{0:N0}% ctx" -f [double]$usedPct
    $parts.Add("$green$ctxStr$reset")
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
