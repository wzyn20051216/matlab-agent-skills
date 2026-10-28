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
import base64
import json
import re
from typing import Any, Iterable, Tuple
from urllib.parse import quote

REDACTED = "<REDACTED>"
CREDENTIAL_KEYS = (
    "api[-_]?key",
    "x[-_]?api[-_]?key",
    "x[-_]?mcp[-_]?api[-_]?key",
    "authorization",
    "proxy-authorization",
    "access[-_]?token",
    "refresh[-_]?token",
    "client[-_]?secret",
    "password",
    "passwd",
    "pwd",
    "secret",
    "api[-_]?token",
    "auth[-_]?token",
    "id[-_]?token",
    "auth[-_]?key",
    "secret[-_]?access[-_]?key",
    "session[-_]?token",
    "session[-_]?key",
    "private[-_]?key",
    "token",
    "certificate",
)
_KEY = r"(?:(?:matlab|mcp|aws|azure|github|gh|openai)[_-])*(?:" + "|".join(CREDENTIAL_KEYS) + r")"
_KEY_ONLY_RE = re.compile(r"(?i)^(?:" + _KEY + r")$")
_QUOTE = r'\\*"'
_JSON_FIELD_RE = re.compile(
    r"(?i)(" + _QUOTE + r")(" + _KEY + r")(" + _QUOTE + r"\s*:\s*" + _QUOTE + r")"
    r"((?:[^\"\\]|\\.)*)(" + _QUOTE + r")"
)
_BEARER_RE = re.compile(r"(?i)\b(bearer|basic)(\s+)([A-Za-z0-9._~+/=\-]+)")
_ARGV_RE = re.compile(r"(?i)(--" + _KEY + r"(?:=|\s+))([^\s,;\"']+)")
_FIELD_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])(" + _KEY + r")(\s*[:=]\s*)(?!<REDACTED)([^\s,;\"']+)"
)
_UUID_RE = re.compile(
    r"(?<![A-Za-z0-9_\\/])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![A-Za-z0-9_\\/])"
)
_HEX_RE = re.compile(r"(?<![A-Za-z0-9_\\/])[0-9a-fA-F]{32,}(?![A-Za-z0-9_\\/])")
_RESIDUAL_RE = re.compile(r"(?i)(?<![A-Za-z0-9])" + _KEY + r"\b(?:\\*[\"'])?\s*[:=](?!\s*<REDACTED)")
_URI_AUTH_RE = re.compile(r"(?i)\b((?:https?|socks[45]?h?)://)[^/\s@]+:[^/\s@]+@")
_PUBLIC_IDENTIFIER_RE = re.compile(r"(?i)^(?:id|.*sha(?:256|384|512)?|digest|hash|.*paths?)$")
_LINE_MARKER = "<REDACTED:credential-line>"


def _token(value: str) -> str:
    digest = hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()[:12]
    return f"<REDACTED:sha256-{digest}>"


def _redact_text_line(line: str, secrets: Iterable[str], preserve_identifiers: bool = False) -> Tuple[str, int]:
    count = 0
    text = line
    for secret in secrets:
        if secret:
            variants = (secret, quote(secret, safe=""),
                        base64.b64encode(secret.encode("utf-8")).decode("ascii"),
                        base64.b64encode(secret.encode("utf-16-le")).decode("ascii"))
            for variant in variants:
                if variant in text:
                    text = text.replace(variant, REDACTED)
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

    text, uri_count = _URI_AUTH_RE.subn(r"\1<REDACTED>@", text)
    count += uri_count
    if not preserve_identifiers:
        text = _UUID_RE.sub(replace_bare, text)
        text = _HEX_RE.sub(replace_bare, text)

    if _RESIDUAL_RE.search(text):
        return _LINE_MARKER, count + 1
    return text, count


def _credential_strings(value: Any, depth: int = 0) -> set[str]:
    """仅在内存收集结构中的凭据，防止其在同一输出的普通诊断里重复出现。"""
    found: set[str] = set()
    if depth > 48:
        return found
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str) and _KEY_ONLY_RE.match(key) and isinstance(item, str):
                if item and not item.lower().startswith(('<redacted', '[redacted')):
                    found.add(item)
            else:
                found.update(_credential_strings(item, depth + 1))
    elif isinstance(value, list):
        for item in value:
            found.update(_credential_strings(item, depth + 1))
    elif isinstance(value, str) and value.lstrip().startswith(('{', '[')):
        try:
            found.update(_credential_strings(json.loads(value), depth + 1))
        except (ValueError, RecursionError):
            pass
    return found


def sanitize_text(text: str, secrets: Iterable[str] = (), *, preserve_identifiers: bool = False,
                  _depth: int = 0) -> Tuple[str, int]:
    """Return (sanitized_text, replacement_count)."""
    if not text:
        return text, 0
    if _depth > 48:
        return "<REDACTED:depth-limit>", 1
    secrets = tuple(s for s in secrets if isinstance(s, str) and s)
    if text.lstrip().startswith(("{", "[", '"')):
        try:
            parsed = json.loads(text)
        except (ValueError, RecursionError):
            pass
        else:
            secrets += tuple(_credential_strings(parsed))
            safe, count = sanitize_value(parsed, secrets=secrets,
                                         _preserve_identifiers=preserve_identifiers, _depth=_depth + 1)
            if safe == parsed:
                return text, 0
            return json.dumps(safe, ensure_ascii=False, separators=(",", ":")), count
    lines = text.splitlines(keepends=True)
    total = 0
    output = []
    for line in lines:
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        clean, count = _redact_text_line(body, secrets, preserve_identifiers)
        output.append(clean + ending)
        total += count
    return "".join(output), total


def sanitize_value(value: Any, secrets: Iterable[str] = (), *, _preserve_identifiers: bool = False,
                   _depth: int = 0) -> Tuple[Any, int]:
    """Recursively redact credential-named keys in a parsed JSON value."""
    if _depth > 48:
        return "<REDACTED:depth-limit>", 1
    secrets = tuple(secrets)
    if _depth == 0:
        secrets += tuple(_credential_strings(value))
    if isinstance(value, dict):
        result = {}
        total = 0
        for key, item in value.items():
            if isinstance(key, str) and _KEY_ONLY_RE.match(key):
                if value[key] is None or value[key] == "" or (
                        isinstance(item, str) and item.lower().startswith(("<redacted", "[redacted"))):
                    result[key] = item
                    continue
                result[key] = _token(item) if isinstance(item, str) and item else REDACTED
                total += 1
                continue
            keep_identifier = _preserve_identifiers or bool(isinstance(key, str) and _PUBLIC_IDENTIFIER_RE.match(key))
            safe, count = sanitize_value(item, secrets=secrets,
                                         _preserve_identifiers=keep_identifier, _depth=_depth + 1)
            result[key] = safe
            total += count
        return result, total
    if isinstance(value, list):
        items = []
        total = 0
        for item in value:
            safe, count = sanitize_value(item, secrets=secrets,
                                         _preserve_identifiers=_preserve_identifiers, _depth=_depth + 1)
            items.append(safe)
            total += count
        return items, total
    if isinstance(value, str):
        return sanitize_text(value, secrets=secrets, preserve_identifiers=_preserve_identifiers, _depth=_depth + 1)
    return value, 0


def sanitize_jsonl(text: str, secrets: Iterable[str] = ()) -> Tuple[str, int]:
    """Sanitize each JSONL line; unparseable lines are scrubbed as plain text."""
    if not text:
        return text, 0
    secrets = tuple(secrets)
    output = []
    total = 0
    for raw_line in text.splitlines(keepends=True):
        line = raw_line.rstrip("\r\n")
        ending = raw_line[len(line):]
        if not line.strip():
            output.append(raw_line)
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            clean, count = sanitize_text(line, secrets)
        else:
            safe, count = sanitize_value(parsed, secrets=secrets)
            clean = json.dumps(safe, ensure_ascii=False, separators=(",", ":"))
        output.append(clean + ending)
        total += count
    return "".join(output), total
