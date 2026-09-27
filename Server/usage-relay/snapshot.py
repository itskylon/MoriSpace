"""Small allowlist codec shared by relay persistence and HTTP boundaries.

Matches CalendarWidgetShared/UsageWidgetData.swift version 1. This module has no
Codex, account, credential, network or collector dependencies.
"""
import json
import math
import unicodedata

MAX_BYTES = 65_536
MAX_WINDOWS = 64
MAX_TIMESTAMP = 253_402_300_799
ROOT_KEYS = {"version", "fetchedAt", "validUntil", "status", "windows"}
WINDOW_KEYS = {"id", "label", "usedPercent", "windowMinutes", "resetsAt"}


class InvalidSnapshot(ValueError):
    pass


def number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def timestamp(value):
    if not number(value) or not 0 < value <= MAX_TIMESTAMP:
        raise InvalidSnapshot("invalid-snapshot")
    return value


def text(value, maximum):
    if (not isinstance(value, str) or not value.strip() or len(value) > maximum
            or any(unicodedata.category(c) in {"Cc", "Cf", "Cs"} for c in value)):
        raise InvalidSnapshot("invalid-snapshot")
    return value


def validate(value, now):
    if not isinstance(value, dict) or set(value) != ROOT_KEYS:
        raise InvalidSnapshot("invalid-snapshot")
    if value["version"] != 1 or isinstance(value["version"], bool):
        raise InvalidSnapshot("invalid-snapshot")
    fetched = timestamp(value["fetchedAt"])
    until = timestamp(value["validUntil"])
    if fetched > now or not fetched <= until <= fetched + 900:
        raise InvalidSnapshot("invalid-snapshot")
    status = value["status"]
    if not isinstance(status, str) or status not in {"ready", "notConnected", "unavailable"}:
        raise InvalidSnapshot("invalid-snapshot")
    source = value["windows"]
    if not isinstance(source, list) or len(source) > MAX_WINDOWS or (status != "ready" and source):
        raise InvalidSnapshot("invalid-snapshot")
    windows, seen = [], set()
    for item in source:
        if not isinstance(item, dict) or not {"id", "label"}.issubset(item) or not set(item).issubset(WINDOW_KEYS):
            raise InvalidSnapshot("invalid-snapshot")
        identifier = text(item["id"], 160)
        label = text(item["label"], 120)
        if identifier in seen:
            raise InvalidSnapshot("invalid-snapshot")
        seen.add(identifier)
        used, minutes, reset = item.get("usedPercent"), item.get("windowMinutes"), item.get("resetsAt")
        if used is not None and (not number(used) or not 0 <= used <= 100):
            raise InvalidSnapshot("invalid-snapshot")
        if minutes is not None and (not isinstance(minutes, int) or isinstance(minutes, bool) or not 0 < minutes <= 2**63 - 1):
            raise InvalidSnapshot("invalid-snapshot")
        if reset is not None:
            timestamp(reset)
        windows.append({"id": identifier, "label": label, "usedPercent": used, "windowMinutes": minutes, "resetsAt": reset})
    return {"version": 1, "fetchedAt": fetched, "validUntil": until, "status": status, "windows": windows}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidSnapshot("invalid-snapshot")
        result[key] = value
    return result


def invalid_constant(_value):
    raise InvalidSnapshot("invalid-snapshot")


def decode(data, now):
    if not isinstance(data, bytes) or not 0 < len(data) <= MAX_BYTES:
        raise InvalidSnapshot("invalid-snapshot")
    try:
        value = json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid_constant)
        return validate(value, now)
    except (ValueError, TypeError, UnicodeError, RecursionError, OverflowError):
        raise InvalidSnapshot("invalid-snapshot") from None


def encode(value, now):
    validated = validate(value, now)
    data = json.dumps(validated, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_BYTES:
        raise InvalidSnapshot("invalid-snapshot")
    return data
