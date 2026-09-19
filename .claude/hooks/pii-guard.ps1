<#
.SYNOPSIS
    UserPromptSubmit-Hook: blockiert Prompts mit personenbezogenen Daten (PII).

.DESCRIPTION
    Setzt GR-T3 (Prompt-Hygiene) technisch durch. Das Skript liest die Hook-Eingabe
    als JSON von stdin, prueft den Prompt-Text gegen PII-Muster und blockiert den
    Prompt, BEVOR er an das Modell gesendet wird.

    Erkannt werden:
      - E-Mail-Adressen (mit Ausnahmeliste fuer offensichtliche Platzhalter)
      - IP-Adressen v4/v6 (validiert ueber System.Net.IPAddress, ohne Loopback,
        Multicast, Link-Local, 0.0.0.0/8 und Subnetzmasken)
      - Telefonnummern (deutsche Formate) und IBAN (mit Mod-97-Pruefsumme)
      - Deutsche Sozialversicherungsnummern und Kreditkarten (mit Luhn-Pruefung)

    NICHT erkannt werden Namen - dafuer gibt es kein zuverlaessiges Muster.
    Der Hook prueft ausserdem ausschliesslich den getippten Prompt, nicht die
    Dateien oder Tool-Ausgaben, die Claude spaeter liest.

.NOTES
    Escape-Hatch: enthaelt der Prompt das Schluesselwort #pii-geprueft, wird er
    durchgelassen und der Vorgang in ~/.claude/pii-guard.log protokolliert
    (nur Metadaten, niemals Prompt-Inhalte).

    Verhalten im Fehlerfall: fail-closed. Ein defektes Skript blockiert, statt
    ungeprueft durchzulassen.
#>

$ErrorActionPreference = 'Stop'

$BypassToken = '#pii-geprueft'
$LogFile     = Join-Path $HOME '.claude/pii-guard.log'

# --- Ausgabe-Helfer ----------------------------------------------------------

function Write-Audit {
    param([string]$EventName, [string[]]$Kinds, [string]$SessionId)
    # Protokolliert nur Metadaten. Prompt-Inhalte werden bewusst NIE geschrieben,
    # sonst landet genau die PII auf der Platte, die der Hook verhindern soll.
    try {
        $stamp = Get-Date -Format 'o'
        $kind  = ($Kinds | Sort-Object -Unique) -join ','
        Add-Content -LiteralPath $LogFile -Encoding utf8 `
            -Value "$stamp | $EventName | $kind | session=$SessionId"
    } catch { }
}

function Deny {
    param([string]$Message)
    [ordered]@{
        decision      = 'block'
        reason        = $Message
        systemMessage = $Message
        continue      = $false
        stopReason    = $Message
    } | ConvertTo-Json -Compress
    exit 0
}

# --- Validierungs-Helfer -----------------------------------------------------

function Test-Luhn {
    param([string]$Digits)
    $sum = 0
    $alt = $false
    for ($i = $Digits.Length - 1; $i -ge 0; $i--) {
        $d = [int]::Parse($Digits[$i])
        if ($alt) {
            $d *= 2
            if ($d -gt 9) { $d -= 9 }
        }
        $sum += $d
        $alt = -not $alt
    }
    return ($sum % 10) -eq 0
}

function Test-Iban {
    param([string]$Value)
    $s = ($Value -replace '[\s-]', '').ToUpperInvariant()
    if ($s.Length -lt 15 -or $s.Length -gt 34) { return $false }
    if ($s -notmatch '^[A-Z]{2}[0-9]{2}[A-Z0-9]+$') { return $false }

    # Mod-97 nach ISO 7064: Land + Pruefziffer ans Ende, Buchstaben -> Zahlen.
    $rearranged = $s.Substring(4) + $s.Substring(0, 4)
    $rem = 0
    foreach ($ch in $rearranged.ToCharArray()) {
        $chunk = if ($ch -match '[0-9]') { [string]$ch } else { [string]([int][char]$ch - 55) }
        foreach ($digit in $chunk.ToCharArray()) {
            # Stueckweise rechnen - die Gesamtzahl waere fuer [long] zu gross.
            $rem = (($rem * 10) + [int]::Parse($digit)) % 97
        }
    }
    return $rem -eq 1
}

function Test-RelevantIp {
    param([string]$Candidate)
    [System.Net.IPAddress]$ip = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($Candidate, [ref]$ip)) { return $false }
    if ([System.Net.IPAddress]::IsLoopback($ip)) { return $false }

    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $ip.GetAddressBytes()
        if ($b[0] -eq 0)   { return $false }                     # 0.0.0.0/8
        if ($b[0] -ge 224) { return $false }                     # Multicast, reserviert, Subnetzmasken
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }  # Link-Local / APIPA
        return $true
    }

    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($ip.IsIPv6LinkLocal -or $ip.IsIPv6Multicast) { return $false }
        if ($ip.Equals([System.Net.IPAddress]::IPv6Any)) { return $false }
        return $true
    }

    return $false
}

# --- Eingabe lesen -----------------------------------------------------------

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

$sessionId = 'unknown'
$text      = $raw

try {
    $obj = $raw | ConvertFrom-Json
    if ($obj.session_id) { $sessionId = [string]$obj.session_id }
    foreach ($field in 'prompt', 'user_prompt', 'message') {
        if (($obj.PSObject.Properties.Name -contains $field) -and $obj.$field) {
            $text = [string]$obj.$field
            break
        }
    }
} catch {
    # Kein verwertbares JSON: auf dem Rohtext weiterpruefen statt durchzulassen.
    $text = $raw
}

# Escape-Hatch zuerst, auf dem Rohtext - damit er auch dann greift, wenn das
# Parsen der Hook-Eingabe fehlschlaegt.
if ($raw -like "*$BypassToken*") {
    Write-Audit -EventName 'BYPASS' -Kinds @('escape-hatch') -SessionId $sessionId
    exit 0
}

# --- Erkennung ---------------------------------------------------------------

$findings = [System.Collections.Generic.List[string]]::new()

try {
    # E-Mail-Adressen ---------------------------------------------------------
    $emailAllow = @(
        '@example\.(com|org|net)$'
        '@(test|beispiel)\.(de|com|org|local)$'
        '@localhost$'
        '@domain\.(tld|com|de)$'
        '^noreply@anthropic\.com$'
        '^(max\.)?muster(mann|frau)@'
        '^(user|benutzer|foo|bar|test|mail|email|name)@'
    )
    foreach ($m in [regex]::Matches($text, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')) {
        $isPlaceholder = $false
        foreach ($pattern in $emailAllow) {
            if ($m.Value -match "(?i)$pattern") { $isPlaceholder = $true; break }
        }
        if (-not $isPlaceholder) { $findings.Add('E-Mail-Adresse'); break }
    }

    # IP-Adressen -------------------------------------------------------------
    # Lookbehind gegen die haeufigste Fehlmeldung in diesem Repo: Versionsnummern
    # wie ModuleVersion = '1.2.3.4'. \x22 = ", \x27 = '.
    $ipv4Pattern = '(?<!(?i:version)[\s=:\x22\x27]{0,4})\b\d{1,3}(?:\.\d{1,3}){3}\b'
    foreach ($m in [regex]::Matches($text, $ipv4Pattern)) {
        if (Test-RelevantIp $m.Value) { $findings.Add('IPv4-Adresse'); break }
    }
    $ipv6Pattern = '(?<![\w:])(?:[A-Fa-f0-9]{0,4}:){2,7}[A-Fa-f0-9]{0,4}(?![\w:])'
    foreach ($m in [regex]::Matches($text, $ipv6Pattern)) {
        if (Test-RelevantIp $m.Value) { $findings.Add('IPv6-Adresse'); break }
    }

    # Telefonnummern ----------------------------------------------------------
    $phonePatterns = @(
        '(?:\+49|0049)[\s\-/().]?\d[\d\s\-/().]{5,}\d'   # international
        '\b01[5-7]\d[\s\-/]?\d{6,9}\b'                   # deutsche Mobilnummern
    )
    foreach ($pattern in $phonePatterns) {
        if ($text -match $pattern) { $findings.Add('Telefonnummer'); break }
    }

    # IBAN --------------------------------------------------------------------
    foreach ($m in [regex]::Matches($text, '\b[A-Z]{2}\d{2}\s?(?:[A-Z0-9]{4}\s?){2,7}[A-Z0-9]{1,4}\b')) {
        if (Test-Iban $m.Value) { $findings.Add('IBAN'); break }
    }

    # Deutsche Sozialversicherungsnummer --------------------------------------
    # Aufbau: 2 Bereichsziffern + 6 Geburtsdatum + 1 Namensbuchstabe + 3 Ziffern.
    if ($text -match '\b\d{8}[A-Za-z]\d{3}\b') { $findings.Add('Sozialversicherungsnummer') }

    # Kreditkartennummern -----------------------------------------------------
    foreach ($m in [regex]::Matches($text, '\b(?:\d[ \-]?){12,18}\d\b')) {
        $digits = $m.Value -replace '[^\d]', ''
        if ($digits.Length -ge 13 -and $digits.Length -le 19 -and
            $digits[0] -match '[3-6]' -and (Test-Luhn $digits)) {
            $findings.Add('Kreditkartennummer')
            break
        }
    }
}
catch {
    Deny ("PII-Filter abgebrochen: $($_.Exception.Message)`n" +
          "Der Prompt wurde vorsorglich NICHT gesendet (fail-closed).`n" +
          "Skript pruefen: ~/.claude/hooks/pii-guard.ps1 - oder den Prompt mit " +
          "$BypassToken freigeben, wenn er sicher keine personenbezogenen Daten enthaelt.")
}

# --- Entscheidung ------------------------------------------------------------

if ($findings.Count -gt 0) {
    $kinds = @($findings | Sort-Object -Unique)
    Write-Audit -EventName 'BLOCKED' -Kinds $kinds -SessionId $sessionId
    Deny ("Prompt blockiert - moegliche personenbezogene Daten erkannt: " +
          ($kinds -join ', ') + ".`n`n" +
          "Guardrail GR-T3 (Prompt-Hygiene): keine PII an Claude uebermitteln. " +
          "Bitte durch synthetische oder anonymisierte Testdaten ersetzen.`n`n" +
          "Fehlalarm? Haenge $BypassToken an den Prompt an, um ihn einmalig freizugeben.")
}

exit 0
