#!/bin/bash
# Claude Code Statusline (macOS/Linux) - Port von statusline.ps1
# Benoetigt: jq, git (optional)

input=$(cat)

# Alle benoetigten Felder in einem jq-Aufruf; Trenner \x1f, damit leere Felder erhalten bleiben.
IFS=$'\x1f' read -r model effort used_pct cwd \
    h5_pct h5_reset d7_pct d7_reset sp_pct sp_reset < <(
    printf '%s' "$input" | jq -r '
        [ .model.display_name,
          .effort.level,
          .context_window.used_percentage,
          (.workspace.current_dir // .cwd),
          .rate_limits.five_hour.used_percentage,
          .rate_limits.five_hour.resets_at,
          .rate_limits.seven_day.used_percentage,
          .rate_limits.seven_day.resets_at,
          .rate_limits.spend_limit.used_percentage,
          .rate_limits.spend_limit.resets_at
        ] | map(. // "") | join("")' 2>/dev/null
)

reset=$'\033[0m'
cyan=$'\033[36m'
yellow=$'\033[33m'
green=$'\033[32m'
magenta=$'\033[35m'
blue=$'\033[34m'
red=$'\033[31m'
bold=$'\033[1m'

parts=()

[ -n "$model" ]  && parts+=("${cyan}${model}${reset}")
[ -n "$effort" ] && parts+=("${yellow}${effort}${reset}")
[ -n "$used_pct" ] && parts+=("${green}$(printf '%.0f' "$used_pct")% ctx${reset}")

# Verbleibende Zeit bis zum Reset: 2d3h / 4h05m / 12m
format_remaining() {
    local s=$1 d h m
    (( s <= 0 )) && return
    d=$(( s / 86400 ))
    h=$(( s % 86400 / 3600 ))
    m=$(( s % 3600 / 60 ))
    if   (( d >= 1 )); then printf '%dd%dh' "$d" "$h"
    elif (( s >= 3600 )); then printf '%dh%02dm' $(( s / 3600 )) "$m"
    else printf '%dm' $(( s / 60 ))
    fi
}

# Usage-Limits des Abos (nur bei Subscription-Auth vorhanden; sonst still ausgelassen)
format_limit() {
    local label=$1 pct=$2 resets=$3 color text left now
    [ -z "$pct" ] && return
    pct=$(printf '%.0f' "$pct")
    if   (( pct >= 85 )); then color=$red
    elif (( pct >= 60 )); then color=$yellow
    else color=$green
    fi
    text="${pct}%"
    if [ -n "$resets" ]; then
        now=$(date +%s)
        left=$(format_remaining $(( ${resets%.*} - now )))
        [ -n "$left" ] && text="${text}/${left}"
    fi
    parts+=("${bold}${label}:${reset} ${color}${text}${reset}")
}

format_limit '5h'    "$h5_pct" "$h5_reset"
format_limit '7d'    "$d7_pct" "$d7_reset"
format_limit 'spend' "$sp_pct" "$sp_reset"

# Projektordner (Blatt von cwd)
[ -n "$cwd" ] && parts+=("${magenta}$(basename "$cwd")${reset}")

# Git-Branch, nur innerhalb eines Repos; ohne optionale Locks; sonst still ausgelassen
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    branch=$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)
    [ -n "$branch" ] && parts+=("${blue}${branch}${reset}")
fi

# Mit " | " verbinden
out=""
for p in "${parts[@]}"; do
    out+="${out:+ | }${p}"
done
printf '%s\n' "$out"
