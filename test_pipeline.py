
from triage_engine import analyze_patient

log = logging.getLogger("test_pipeline")

OUTPUT_FIELDS = ("triage", "confidence", "ecg_result", "symptoms")


def validate(result: Dict[str, Any]) -> Tuple[bool, str]:
    """Assert the locked output contract rather than eyeballing printed dicts."""
    cfg = get_config()
    missing = [f for f in OUTPUT_FIELDS if f not in result]
    if missing:
        return False, f"missing fields: {missing}"
    if result["triage"] not in cfg.triage.class_labels:
        return False, f"bad triage label: {result['triage']!r}"
    if not 0.0 <= float(result["confidence"]) <= 1.0:
        return False, f"confidence out of range: {result['confidence']}"
    allowed = {cfg.ecg.label_normal, cfg.ecg.label_arrhythmia, cfg.ecg.label_undetermined}
    if result["ecg_result"] not in allowed:
        return False, f"bad ecg_result: {result['ecg_result']!r}"
    if not isinstance(result["symptoms"], list):
        return False, "symptoms must be a list"
    return True, "ok"


def main() -> int:
    parser = argparse.ArgumentParser(description="Raksha-Sim end-to-end pipeline test")
    parser.add_argument("--url", default=None, help="override the mock dataset endpoint")
    parser.add_argument("--limit", type=int, default=0, help="stop after N payloads")
    parser.add_argument("--json", action="store_true", help="emit machine-readable results")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s [%(name)s] %(message)s")

    passed = failed = 0
    try:
        # Generator: one payload is held in memory at a time.
        for index, packet in enumerate(iter_payloads(args.url), start=1):
            if args.limit and index > args.limit:
                break
            device = packet.get("device_id", f"payload_{index}")
            try:
                result = analyze_patient(packet)
            except Exception as exc:                      # noqa: BLE001
                failed += 1
                log.error("%s CRASHED: %s", device, exc)
                continue
            ok, reason = validate(result)
            passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
            if args.json:
                print(json.dumps({"device_id": device, "ok": ok, "result": result}))
            else:
                status = "PASS" if ok else f"FAIL ({reason})"
                print(f"[{status}] {device}: {result['triage']} "
                      f"@ {result['confidence']} | {result['ecg_result']} | {result['symptoms']}")
    except DatasetUnavailable as exc:
        log.error("Could not load mock dataset: %s", exc)
        log.error("Set RAKSHA_DATASET_URL, or seed the cache at %s",
                  get_config().dataset.cache_path)
        return 2

    print(f"\n{passed} passed, {failed} failed")
    return 0 if failed == 0 and passed else 1


if __name__ == "__main__":
    sys.exit(main())
"""End-to-end integration test. Terminal only, no GUI, no hardcoded payloads.

    python test_pipeline.py
    python test_pipeline.py --url https://example.org/payloads.json
    RAKSHA_DATASET_URL=... python test_pipeline.py
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from typing import Any, Dict, Tuple

from config import get_config
from dataset_loader import DatasetUnavailable, iter_payloads