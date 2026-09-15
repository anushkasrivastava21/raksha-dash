"""ECG bandpass filtering + arrhythmia classification (CPU only)."""
from __future__ import annotations

import logging
from typing import Optional, Sequence

import numpy as np
from scipy.signal import butter, sosfiltfilt

from config import get_config

log = logging.getLogger(__name__)
CFG = get_config().ecg

try:
    import torch
    import torch.nn as nn

    class ECG_CNN(nn.Module):

        def __init__(self) -> None:
            super().__init__()
            self.conv1 = nn.Conv1d(1, CFG.conv_channels, kernel_size=CFG.kernel_size, stride=CFG.stride)
            self.relu = nn.ReLU()
            self.pool = nn.AdaptiveAvgPool1d(CFG.pooled_width)
            self.fc = nn.Linear(CFG.conv_channels * CFG.pooled_width, 2)

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            x = self.pool(self.relu(self.conv1(x)))
            return self.fc(torch.flatten(x, 1))

except Exception as _torch_err:
    torch = None
    nn = None
    ECG_CNN = None




_model: Optional[object] = None
_model_ready: Optional[bool] = None
_sos: Optional[np.ndarray] = None


def _get_model() -> Optional[object]:
    global _model, _model_ready
    if _model_ready is not None:
        return _model if _model_ready else None

    if torch is None or ECG_CNN is None:
        log.info("PyTorch runtime unavailable; ECG will report '%s'.", CFG.label_undetermined)
        _model_ready = False
        return None

    if not CFG.weights_path.is_file():
        log.info("No ECG weights at %s - ECG will report '%s'.",
                 CFG.weights_path, CFG.label_undetermined)
        _model_ready = False
        return None
    try:
        model = ECG_CNN()
        state = torch.load(CFG.weights_path, map_location="cpu")
        model.load_state_dict(state.get("state_dict", state))
        model.eval()
        for p in model.parameters():
            p.requires_grad_(False)
        _model, _model_ready = model, True
        log.info("Loaded ECG weights from %s", CFG.weights_path)
    except Exception as exc:
        log.error("ECG weights failed to load (%s)", exc)
        _model_ready = False
    return _model


def _get_sos() -> Optional[np.ndarray]:
    """Bandpass SOS coefficients, designed once and cached."""
    global _sos
    if _sos is None:
        high = min(CFG.bandpass_high_hz, CFG.nyquist_hz * 0.99)
        if high <= CFG.bandpass_low_hz:
            log.error("Invalid ECG band %.1f-%.1f Hz at fs=%.0f", CFG.bandpass_low_hz, high,
                      CFG.sample_rate_hz)
            return None
        _sos = butter(CFG.filter_order, [CFG.bandpass_low_hz, high],
                      btype="bandpass", fs=CFG.sample_rate_hz, output="sos")
    return _sos


def _filter(raw: np.ndarray) -> np.ndarray:
    """Zero-phase bandpass. Falls back to mean-removal on very short records."""
    sos = _get_sos()
    if sos is None:
        return raw - raw.mean()
    # sosfiltfilt needs padlen < len(signal); short ADC bursts would otherwise raise.
    padlen = min(3 * (2 * sos.shape[0] + 1), raw.size - 1)
    if padlen < 1:
        return raw - raw.mean()
    return sosfiltfilt(sos, raw, padlen=padlen)


def process_ecg(raw_ecg: Sequence[float]) -> str:
    """Return one of: label_normal / label_arrhythmia / label_undetermined.

    Never raises - a bad ECG packet must not stop the rest of triage.
    """
    if raw_ecg is None or len(raw_ecg) < CFG.min_samples:
        log.warning("ECG packet too short (%s samples)", 0 if raw_ecg is None else len(raw_ecg))
        return CFG.label_undetermined

    model = _get_model()
    if model is None:
        return CFG.label_undetermined

    try:
        # float32 throughout: half the memory of the numpy float64 default.
        signal = np.asarray(raw_ecg, dtype=np.float32)
        filtered = np.ascontiguousarray(_filter(signal), dtype=np.float32)
        del signal

        # Baseline wander / gain normalisation, done in place.
        filtered -= filtered.mean()
        scale = float(np.abs(filtered).max())
        if scale > 0:
            filtered /= scale

        # from_numpy shares the buffer instead of copying it.
        tensor = torch.from_numpy(filtered).view(1, 1, -1)
        with torch.inference_mode():
            prediction = int(torch.argmax(model(tensor), dim=1).item())
        return CFG.label_arrhythmia if prediction == 1 else CFG.label_normal
    except Exception as exc:                  # noqa: BLE001
        log.exception("ECG processing failed: %s", exc)
        return CFG.label_undetermined


if __name__ == "__main__":
    print(process_ecg([464, 448, 416, 422, 424, 485, 444, 566, 592, 426]))
