"""Colorimetric urine strip reading -> discrete clinical severity score."""
from __future__ import annotations

import logging
from typing import Optional, Sequence

import torch
import torch.nn as nn

from config import get_config

log = logging.getLogger(__name__)
CFG = get_config().urine


class Urine_CNN(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.net = nn.Sequential(nn.Linear(3, 16), nn.ReLU(), nn.Linear(16, 2))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


_model: Optional[Urine_CNN] = None
_model_ready: Optional[bool] = None


def _get_model() -> Optional[Urine_CNN]:
    global _model, _model_ready
    if _model_ready is not None:
        return _model if _model_ready else None

    if not CFG.weights_path.is_file():
        log.warning("No urine weights at %s - using deterministic colorimetric rules.",
                    CFG.weights_path)
        _model_ready = False
        return None
    try:
        model = Urine_CNN()
        state = torch.load(CFG.weights_path, map_location="cpu")
        model.load_state_dict(state.get("state_dict", state))
        model.eval()
        for p in model.parameters():
            p.requires_grad_(False)
        _model, _model_ready = model, True
    except Exception as exc:                  # noqa: BLE001
        log.error("Urine weights failed to load (%s); using rules instead.", exc)
        _model_ready = False
    return _model


def normalise_rgb(rgb: Sequence[float]) -> list:
    """Scale raw ADC counts (0..adc_max) to the 0..rgb_max range the model expects."""
    r, g, b = (float(v) for v in rgb[:3])
    if max(r, g, b) > CFG.rgb_max:
        k = CFG.rgb_max / CFG.adc_max
        r, g, b = r * k, g * k, b * k
    return [r, g, b]


def _rule_based_severity(r: float, g: float, b: float) -> int:
    """Fallback mapping used until a labelled colorimeter dataset is trained.

    Two coarse indicators only, both documented rather than tuned:
      * low overall luminance  -> dark amber, dehydration / concentrated sample
      * red channel dominance  -> possible hematuria
    """
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    red_ratio = r / max((g + b) / 2.0, 1e-6)
    if luma < CFG.dark_amber_luma or red_ratio > CFG.hematuria_red_ratio:
        return CFG.severity_abnormal
    return CFG.severity_normal


def process_urine(urine_rgb: Sequence[float]) -> int:
    """Return the discrete severity class consumed as XGBoost feature 6."""
    if not urine_rgb or len(urine_rgb) < 3:
        return CFG.severity_normal
    try:
        r, g, b = normalise_rgb(urine_rgb)
        model = _get_model()
        if model is None:
            return _rule_based_severity(r, g, b)
        with torch.inference_mode():
            logits = model(torch.tensor([r, g, b], dtype=torch.float32))
            return int(torch.argmax(logits).item())
    except Exception as exc:                  # noqa: BLE001
        log.error("Urine processing failed (%s); defaulting to normal.", exc)
        return CFG.severity_normal
