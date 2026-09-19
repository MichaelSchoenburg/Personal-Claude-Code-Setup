#!/usr/bin/env python3
"""UserPromptSubmit-Hook: blockiert Prompts mit personenbezogenen Daten (PII).

Setzt GR-T3 (Prompt-Hygiene) technisch durch. Das Skript liest die Hook-Eingabe
als JSON von stdin, prueft den Prompt-Text gegen PII-Muster und blockiert den
Prompt, BEVOR er an das Modell gesendet wird. Port von pii-guard.ps1.

Erkannt werden:
  - E-Mail-Adressen (mit Ausnahmeliste fuer offensichtliche Platzhalter)
  - IP-Adressen v4/v6 (ohne Loopback, Multicast, Link-Local, 0.0.0.0/8 und
    Subnetzmasken)
  - Telefonnummern (deutsche Formate) und IBAN (mit Mod-97-Pruefsumme)
  - Deutsche Sozialversicherungsnummern und Kreditkarten (mit Luhn-Pruefung)

NICHT erkannt werden Namen - dafuer gibt es kein zuverlaessiges Muster.
Der Hook prueft ausserdem ausschliesslich den getippten Prompt, nicht die
Dateien oder Tool-Ausgaben, die Claude spaeter liest.

Escape-Hatch: enthaelt der Prompt das Schluesselwort #pii-geprueft, wird er
durchgelassen und der Vorgang in ~/.claude/pii-guard.log protokolliert
(nur Metadaten, niemals Prompt-Inhalte).

Verhalten im Fehlerfall: fail-closed. Ein defektes Skript blockiert, statt
ungeprueft durchzulassen.
"""

import ipaddress
import json
import re
import sys
from datetime import datetime
from pathlib import Path

BYPASS_TOKEN = "#pii-geprueft"
LOG_FILE = Path.home() / ".claude" / "pii-guard.log"

# --- Ausgabe-Helfer ----------------------------------------------------------


def write_audit(event, kinds, session_id):
    # Protokolliert nur Metadaten. Prompt-Inhalte werden bewusst NIE geschrieben,
    # sonst landet genau die PII auf der Platte, die der Hook verhindern soll.
    try:
        stamp = datetime.now().astimezone().isoformat()
        kind = ",".join(sorted(set(kinds)))
        session = re.sub(r"\s", "", session_id)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write("%s | %s | %s | session=%s\n" % (stamp, event, kind, session))
    except Exception:
        pass


def deny(message):
    sys.stdout.write(
        json.dumps(
            {
                "decision": "block",
                "reason": message,
                "systemMessage": message,
                "continue": False,
                "stopReason": message,
            },
            separators=(",", ":"),
        )
        + "\n"
    )
    sys.stdout.flush()
    sys.exit(0)


# --- Validierungs-Helfer -----------------------------------------------------


def test_luhn(digits):
    total = 0
    alt = False
    for ch in reversed(digits):
        d = int(ch)
        if alt:
            d *= 2
            if d > 9:
                d -= 9
        total += d
        alt = not alt
    return total % 10 == 0


def test_iban(value):
    s = re.sub(r"[\s-]", "", value).upper()
    if len(s) < 15 or len(s) > 34:
        return False
    if not re.match(r"^[A-Z]{2}[0-9]{2}[A-Z0-9]+$", s):
        return False
    # Mod-97 nach ISO 7064: Land + Pruefziffer ans Ende, Buchstaben -> Zahlen.
    rearranged = s[4:] + s[:4]
    number = "".join(str(int(ch, 36)) for ch in rearranged)
    return int(number) % 97 == 1


def is_relevant_ipv4(candidate):
    parts = [int(p) for p in candidate.split(".")]
    if len(parts) != 4 or any(p > 255 for p in parts):
        return False
    if parts[0] == 127:
        return False  # Loopback
    if parts[0] == 0:
        return False  # 0.0.0.0/8
    if parts[0] >= 224:
        return False  # Multicast, reserviert, Subnetzmasken
    if parts[0] == 169 and parts[1] == 254:
        return False  # Link-Local / APIPA
    return True


def is_relevant_ipv6(candidate):
    try:
        ip = ipaddress.IPv6Address(candidate)
    except ValueError:
        return False
    if ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified:
        return False
    return True


# --- Erkennung ---------------------------------------------------------------

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
EMAIL_ALLOW = [
    r"@example\.(com|org|net)$",
    r"@(test|beispiel)\.(de|com|org|local)$",
    r"@localhost$",
    r"@domain\.(tld|com|de)$",
    r"^noreply@anthropic\.com$",
    r"^(max\.)?muster(mann|frau)@",
    r"^(user|benutzer|foo|bar|test|mail|email|name)@",
]

IPV4_RE = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
# Gegen die haeufigste Fehlmeldung: Versionsnummern wie ModuleVersion = '1.2.3.4'.
# (Python kennt keinen Lookbehind variabler Laenge - daher separat vor dem Treffer.)
VERSION_BEFORE_RE = re.compile(r"""version[\s=:"']{0,4}$""", re.IGNORECASE)
IPV6_RE = re.compile(r"(?<![\w:])(?:[A-Fa-f0-9]{0,4}:){2,7}[A-Fa-f0-9]{0,4}(?![\w:])")

PHONE_RES = [
    re.compile(r"(?:\+49|0049)[\s\-/().]?\d[\d\s\-/().]{5,}\d"),  # international
    re.compile(r"\b01[5-7]\d[\s\-/]?\d{6,9}\b"),  # deutsche Mobilnummern
]

IBAN_RE = re.compile(r"\b[A-Z]{2}\d{2}\s?(?:[A-Z0-9]{4}\s?){2,7}[A-Z0-9]{1,4}\b")

# Aufbau: 2 Bereichsziffern + 6 Geburtsdatum + 1 Namensbuchstabe + 3 Ziffern.
SVN_RE = re.compile(r"\b\d{8}[A-Za-z]\d{3}\b")

CARD_RE = re.compile(r"\b(?:\d[ \-]?){12,18}\d\b")


def detect(text):
    findings = set()

    for m in EMAIL_RE.finditer(text):
        if not any(re.search(p, m.group(0), re.IGNORECASE) for p in EMAIL_ALLOW):
            findings.add("E-Mail-Adresse")
            break

    for m in IPV4_RE.finditer(text):
        if VERSION_BEFORE_RE.search(text[: m.start()]):
            continue
        if is_relevant_ipv4(m.group(0)):
            findings.add("IPv4-Adresse")
            break

    for m in IPV6_RE.finditer(text):
        if is_relevant_ipv6(m.group(0)):
            findings.add("IPv6-Adresse")
            break

    if any(p.search(text) for p in PHONE_RES):
        findings.add("Telefonnummer")

    for m in IBAN_RE.finditer(text):
        if test_iban(m.group(0)):
            findings.add("IBAN")
            break

    if SVN_RE.search(text):
        findings.add("Sozialversicherungsnummer")

    for m in CARD_RE.finditer(text):
        digits = re.sub(r"\D", "", m.group(0))
        if 13 <= len(digits) <= 19 and digits[0] in "3456" and test_luhn(digits):
            findings.add("Kreditkartennummer")
            break

    return sorted(findings)


# --- Hauptablauf -------------------------------------------------------------


def main():
    raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    if not raw.strip():
        return

    session_id = "unknown"
    text = raw
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            if obj.get("session_id"):
                session_id = str(obj["session_id"])
            for field in ("prompt", "user_prompt", "message"):
                if obj.get(field):
                    text = str(obj[field])
                    break
    except ValueError:
        # Kein verwertbares JSON: auf dem Rohtext weiterpruefen statt durchzulassen.
        text = raw

    # Escape-Hatch zuerst, auf dem Rohtext - damit er auch dann greift, wenn das
    # Parsen der Hook-Eingabe fehlschlaegt.
    if BYPASS_TOKEN.lower() in raw.lower():
        write_audit("BYPASS", ["escape-hatch"], session_id)
        return

    try:
        kinds = detect(text)
    except Exception as exc:
        deny(
            "PII-Filter abgebrochen: %s\n"
            "Der Prompt wurde vorsorglich NICHT gesendet (fail-closed).\n"
            "Skript pruefen: ~/.claude/hooks/pii-guard.py - oder den Prompt mit "
            "%s freigeben, wenn er sicher keine personenbezogenen Daten enthaelt."
            % (exc, BYPASS_TOKEN)
        )

    if kinds:
        write_audit("BLOCKED", kinds, session_id)
        deny(
            "Prompt blockiert - moegliche personenbezogene Daten erkannt: %s.\n\n"
            "Guardrail GR-T3 (Prompt-Hygiene): keine PII an Claude uebermitteln. "
            "Bitte durch synthetische oder anonymisierte Testdaten ersetzen.\n\n"
            "Fehlalarm? Haenge %s an den Prompt an, um ihn einmalig freizugeben."
            % (", ".join(kinds), BYPASS_TOKEN)
        )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        deny(
            "PII-Filter abgebrochen: %s\n"
            "Der Prompt wurde vorsorglich NICHT gesendet (fail-closed)." % exc
        )
