"""Credential scrubbing for archived client transcripts.

The Phase 5.8 leak was an agent-owned command that read MATLAB's
`sessionDetails.json`; the client transcript then contained the key inside an
escaped JSON string, and the probe archived stdout/stderr verbatim. This module
removes credential material before any client output is persisted.

Covered shapes: plain JSON fields, escaped/nested JSON fields, `x-api-key`,
`Authorization: Bearer|Basic`, `--api-key value|=value`, env-style assignments,
bare UUIDs, and bare hex tokens >= 32 chars. A residual keyword/value pattern
drops the whole line as a last resort.

Redaction is deterministic: the replacement embeds the first 12 hex characters
of the value's SHA-256 so distinct leaks remain distinguishable without
revealing the value.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Iterable, Tuple

REDACTED = "<REDACTED>"
CREDENTIAL_KEYS = (
    "api[-_]?key",
    "x-api-key",
    "authorization",
    "proxy-authorization",
    "access[-_]?token",
    "refresh[-_]?token",
    "client[-_]?secret",
    "password",
    "token",
    "certificate",
)
_KEY_ONLY_RE = re.compile(r"(?i)^(?:" + "|".join(CREDENTIAL_KEYS) + r")$")
_QUOTE = r'\\*"'
_KEY = r"(?:" + "|".join(CREDENTIAL_KEYS) + r")"
_JSON_FIELD_RE = re.compile(
    r"(?i)(" + _QUOTE + r")(" + _KEY + r")(" + _QUOTE + r"\s*:\s*" + _QUOTE + r")"
    r"((?:[^\"\\]|\\.)*)(" + _QUOTE + r")"
)
_BEARER_RE = re.compile(r"(?i)\b(bearer|basic)(\s+)([A-Za-z0-9._~+/=\-]{8,})")
_ARGV_RE = re.compile(r"(?i)(--api[-_]?key(?:=|\s+))([^\s,;\"']+)")
_FIELD_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])(" + _KEY + r")(\s*[:=]\s*)(?!<REDACTED)([^\s,;\"']+)"
)
_UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
_HEX_RE = re.compile(r"\b[0-9a-fA-F]{32,}\b")
_RESIDUAL_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:" + "|".join(CREDENTIAL_KEYS) + r")\b\s*[:=](?!\s*<REDACTED)"
)
_LINE_MARKER = "<REDACTED:credential-line>"


def _token(value: str) -> str:
    digest = hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()[:12]
    return f"<REDACTED:sha256-{digest}>"


def _redact_text_line(line: str, secrets: Iterable[str]) -> Tuple[str, int]:
    count = 0
    text = line
    for secret in secrets:
        if secret and len(secret) >= 4 and secret in text:
            text = text.replace(secret, REDACTED)
            count += 1

    def replace(match: re.Match) -> str:
        nonlocal count
        count += 1
        return match.group(1) + match.group(2) + match.group(3) + _token(match.group(4)) + match.group(5)

    text = _JSON_FIELD_RE.sub(replace, text)

    def replace_bearer(match: re.Match) -> str:
        nonlocal count
        count += 1
        return match.group(1) + match.group(2) + _token(match.group(3))

    text = _BEARER_RE.sub(replace_bearer, text)

    def replace_argv(match: re.Match) -> str:
        nonlocal count
        count += 1
        return match.group(1) + _token(match.group(2))

    text = _ARGV_RE.sub(replace_argv, text)

    def replace_field(match: re.Match) -> str:
        nonlocal count
        count += 1
        return match.group(1) + match.group(2) + _token(match.group(3))

    text = _FIELD_RE.sub(replace_field, text)

    def replace_bare(match: re.Match) -> str:
        nonlocal count
        count += 1
        return _token(match.group(0))

    text = _UUID_RE.sub(replace_bare, text)
    text = _HEX_RE.sub(replace_bare, text)

    if _RESIDUAL_RE.search(text):
        return _LINE_MARKER, count + 1
    return text, count


def sanitize_text(text: str, secrets: Iterable[str] = ()) -> Tuple[str, int]:
    """Return (sanitized_text, replacement_count)."""
    if not text:
        return text, 0
    secrets = tuple(s for s in secrets if isinstance(s, str) and len(s) >= 4)
    lines = text.splitlines()
    total = 0
    output = []
    for line in lines:
        clean, count = _redact_text_line(line, secrets)
        output.append(clean)
        total += count
    result = "\n".join(output)
    if text.endswith(("\n", "\r")):
        result += "\n"
    return result, total


def sanitize_value(value: Any) -> Tuple[Any, int]:
    """Recursively redact credential-named keys in a parsed JSON value."""
    if isinstance(value, dict):
        result = {}
        total = 0
        for key, item in value.items():
            if isinstance(key, str) and _KEY_ONLY_RE.match(key):
                result[key] = _token(item) if isinstance(item, str) and item else REDACTED
                total += 1
                continue
            safe, count = sanitize_value(item)
            result[key] = safe
            total += count
        return result, total
    if isinstance(value, list):
        items = []
        total = 0
        for item in value:
            safe, count = sanitize_value(item)
            items.append(safe)
            total += count
        return items, total
    if isinstance(value, str):
        return sanitize_text(value)
    return value, 0


def sanitize_jsonl(text: str, secrets: Iterable[str] = ()) -> Tuple[str, int]:
    """Sanitize each JSONL line; unparseable lines are scrubbed as plain text."""
    if not text:
        return text, 0
    secrets = tuple(secrets)
    output = []
    total = 0
    for line in text.splitlines():
        if not line.strip():
            output.append(line)
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            clean, count = sanitize_text(line, secrets)
        else:
            safe, count = sanitize_value(parsed)
            clean = json.dumps(safe, ensure_ascii=False, separators=(",", ":"))
        output.append(clean)
        total += count
    result = "\n".join(output)
    if text.endswith(("\n", "\r")):
        result += "\n"
    return result, total
