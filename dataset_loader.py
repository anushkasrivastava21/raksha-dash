"""Fetch mock ESP32 payloads from a remote endpoint instead of hardcoding them."""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Any, Dict, Iterator, List, Optional

import requests

from config import get_config

log = logging.getLogger(__name__)
CFG = get_config().dataset


class DatasetUnavailable(RuntimeError):
    """Raised when the dataset can be reached neither remotely nor from cache."""


def _headers() -> Dict[str, str]:
    headers = {"Accept": "application/json"}
    token = os.environ.get(CFG.auth_token_env)
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def _normalise(doc: Any) -> List[Dict[str, Any]]:
    """Accept a bare list, {"payloads": [...]} or a single payload object."""
    if isinstance(doc, list):
        return [p for p in doc if isinstance(p, dict)]
    if isinstance(doc, dict):
        for key in ("payloads", "data", "results", "items"):
            if isinstance(doc.get(key), list):
                return [p for p in doc[key] if isinstance(p, dict)]
        if "device_id" in doc or "status" in doc:
            return [doc]
    raise DatasetUnavailable("Unrecognised dataset shape")


def _download(url: str) -> List[Dict[str, Any]]:
    last_exc: Optional[Exception] = None
    for attempt in range(1, CFG.retries + 1):
        try:
            with requests.get(url, headers=_headers(), timeout=CFG.timeout_s, stream=True) as resp:
                resp.raise_for_status()
                declared = int(resp.headers.get("Content-Length") or 0)
                if declared > CFG.max_bytes:
                    raise DatasetUnavailable(f"Dataset too large: {declared} bytes")
                body = resp.raw.read(CFG.max_bytes + 1, decode_content=True)
                if len(body) > CFG.max_bytes:
                    raise DatasetUnavailable("Dataset exceeded max_bytes while streaming")
            payloads = _normalise(json.loads(body.decode("utf-8")))
            log.info("Fetched %d payload(s) from %s", len(payloads), url)
            _write_cache(body)
            return payloads
        except Exception as exc:                          # noqa: BLE001
            last_exc = exc
            wait = CFG.backoff_s * attempt
            log.warning("Dataset fetch attempt %d/%d failed (%s)", attempt, CFG.retries, exc)
            if attempt < CFG.retries:
                time.sleep(wait)
    raise DatasetUnavailable(str(last_exc))


def _write_cache(body: bytes) -> None:
    if not CFG.use_cache:
        return
    try:
        CFG.cache_path.parent.mkdir(parents=True, exist_ok=True)
        CFG.cache_path.write_bytes(body)
    except OSError as exc:
        log.debug("Could not cache dataset: %s", exc)


def _read_cache() -> List[Dict[str, Any]]:
    if not (CFG.use_cache and CFG.cache_path.is_file()):
        raise DatasetUnavailable("No cached dataset available")
    log.warning("Serving payloads from cache %s", CFG.cache_path)
    return _normalise(json.loads(CFG.cache_path.read_text(encoding="utf-8")))


def fetch_payloads(url: Optional[str] = None) -> List[Dict[str, Any]]:
    """Return mock ESP32 payloads, falling back to the local cache if offline."""
    try:
        return _download(url or CFG.url)
    except DatasetUnavailable:
        return _read_cache()


def iter_payloads(url: Optional[str] = None) -> Iterator[Dict[str, Any]]:
    """Generator form - lets the test harness stream without holding every packet."""
    yield from fetch_payloads(url)
