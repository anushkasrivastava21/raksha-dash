
from __future__ import annotations

import csv
import os
import sys
from pathlib import Path

import numpy as np

os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
MODELS_DIR = BASE_DIR / "models"


# ============================================================================ #
# 1. XGBoost Triage Model (4 features -> Green / Yellow / Red)
# ============================================================================ #
def train_triage_model():
    """Train XGBoost multi-class classifier on the 4-feature triage dataset."""
    import xgboost as xgb

    csv_path = DATA_DIR / "triage_training_data.csv"
    if not csv_path.is_file():
        print(f"ERROR: Training data not found at {csv_path}")
        print("       Run 'python generate_datasets.py' first.")
        return False

    # Load CSV
    features = []
    labels = []
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            features.append([
                float(row["ecg_hr"]),
                float(row["spo2"]),
                float(row["temperature"]),
                float(row["urine_severity"]),
            ])
            labels.append(int(row["label"]))

    X = np.array(features, dtype=np.float32)
    y = np.array(labels, dtype=np.int32)

    n_train = int(len(X) * 0.8)
    indices = np.arange(len(X))
    rng = np.random.default_rng(42)
    rng.shuffle(indices)
    train_idx, test_idx = indices[:n_train], indices[n_train:]

    feature_names = ["ecg_hr", "spo2", "temperature", "urine_severity"]
    dtrain = xgb.DMatrix(X[train_idx], label=y[train_idx], feature_names=feature_names)
    dtest = xgb.DMatrix(X[test_idx], label=y[test_idx], feature_names=feature_names)

    params = {
        "objective": "multi:softprob",
        "num_class": 3,
        "max_depth": 4,
        "eta": 0.15,
        "eval_metric": "mlogloss",
        "seed": 42,
        "nthread": 1,
    }

    print("Training XGBoost triage model...")
    print(f"  Train samples: {n_train}, Test samples: {len(X) - n_train}")
    print(f"  Features: {feature_names}")

    booster = xgb.train(
        params, dtrain,
        num_boost_round=30,
        evals=[(dtrain, "train"), (dtest, "test")],
        verbose_eval=10,
    )

    # Evaluate accuracy
    preds = booster.predict(dtest)
    pred_labels = np.argmax(preds, axis=1)
    accuracy = float(np.mean(pred_labels == y[test_idx]))
    print(f"  Test accuracy: {accuracy:.2%}")

    # Feature importance
    fscore = booster.get_score(importance_type="weight")
    print(f"  Feature importance: {fscore}")

    # Save model
    out_path = BASE_DIR / "triage_xgboost.json"
    booster.save_model(str(out_path))
    print(f"  Saved to: {out_path}")
    return True


# ============================================================================ #
# 2. ECG CNN Model (1D waveform -> Normal / Arrhythmia)
# ============================================================================ #
def train_ecg_model():
    """Train the ECG arrhythmia classifier CNN on synthetic waveforms."""
    import torch
    import torch.nn as nn
    import torch.optim as optim
    from torch.utils.data import DataLoader, TensorDataset

    from config import get_config
    cfg = get_config().ecg

    npz_path = DATA_DIR / "ecg_training_data.npz"
    if not npz_path.is_file():
        print(f"ERROR: Training data not found at {npz_path}")
        print("       Run 'python generate_datasets.py' first.")
        return False

    # Load data
    data = np.load(npz_path)
    signals = data["signals"]  # (N, signal_length)
    labels = data["labels"]    # (N,)

    # Normalise each signal: zero-mean, unit-scale
    signals = signals - signals.mean(axis=1, keepdims=True)
    scales = np.abs(signals).max(axis=1, keepdims=True)
    scales[scales == 0] = 1.0
    signals = signals / scales
    # Apply the same bandpass filter and normalisation as ecg_processor.process_ecg
    from ecg_processor import _filter
    filtered_list = []
    for sig in signals:
        f = _filter(sig)
        f = f - f.mean()
        scale = float(np.abs(f).max())
        if scale > 0:
            f = f / scale
        filtered_list.append(f)
    signals = np.array(filtered_list, dtype=np.float32)

    # Convert to tensors: (N, 1, signal_length)
    X = torch.from_numpy(signals).unsqueeze(1).float()
    y = torch.from_numpy(labels).long()

    # 80/20 split
    n = len(X)
    n_train = int(n * 0.8)
    perm = torch.randperm(n, generator=torch.Generator().manual_seed(42))
    train_ds = TensorDataset(X[perm[:n_train]], y[perm[:n_train]])
    test_ds = TensorDataset(X[perm[n_train:]], y[perm[n_train:]])

    train_loader = DataLoader(train_ds, batch_size=32, shuffle=True)
    test_loader = DataLoader(test_ds, batch_size=64)

    # Build model (same architecture as ecg_processor.ECG_CNN)
    class ECG_CNN(nn.Module):
        def __init__(self):
            super().__init__()
            self.conv1 = nn.Conv1d(1, cfg.conv_channels,
                                   kernel_size=cfg.kernel_size, stride=cfg.stride)
            self.relu = nn.ReLU()
            self.pool = nn.AdaptiveAvgPool1d(cfg.pooled_width)
            self.fc = nn.Linear(cfg.conv_channels * cfg.pooled_width, 2)

        def forward(self, x):
            x = self.pool(self.relu(self.conv1(x)))
            return self.fc(torch.flatten(x, 1))

    model = ECG_CNN()
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.Adam(model.parameters(), lr=0.001)

    print("Training ECG CNN model...")
    print(f"  Train samples: {n_train}, Test samples: {n - n_train}")
    print(f"  Architecture: Conv1d(1->{cfg.conv_channels}, k={cfg.kernel_size}, s={cfg.stride})"
          f" -> ReLU -> AdaptiveAvgPool({cfg.pooled_width})"
          f" -> Linear({cfg.conv_channels * cfg.pooled_width}, 2)")

    epochs = 25
    for epoch in range(1, epochs + 1):
        model.train()
        total_loss = 0.0
        for batch_x, batch_y in train_loader:
            optimizer.zero_grad()
            logits = model(batch_x)
            loss = criterion(logits, batch_y)
            loss.backward()
            optimizer.step()
            total_loss += loss.item() * batch_x.size(0)
        avg_loss = total_loss / n_train

        if epoch % 5 == 0 or epoch == 1:
            # Evaluate
            model.eval()
            correct = 0
            total = 0
            with torch.inference_mode():
                for batch_x, batch_y in test_loader:
                    preds = torch.argmax(model(batch_x), dim=1)
                    correct += (preds == batch_y).sum().item()
                    total += batch_y.size(0)
            print(f"  Epoch {epoch:3d}/{epochs}: loss={avg_loss:.4f}, "
                  f"test_acc={correct / total:.2%}")

    # Final accuracy
    model.eval()
    correct = 0
    total = 0
    with torch.inference_mode():
        for batch_x, batch_y in test_loader:
            preds = torch.argmax(model(batch_x), dim=1)
            correct += (preds == batch_y).sum().item()
            total += batch_y.size(0)
    print(f"  Final test accuracy: {correct / total:.2%}")

    # Save
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = MODELS_DIR / "ecg_cnn.pt"
    torch.save({"state_dict": model.state_dict()}, out_path)
    print(f"  Saved to: {out_path}")
    return True


# ============================================================================ #
# 3. Urine CNN Model (RGB -> Normal / Abnormal)
# ============================================================================ #
def train_urine_model():
    """Train the urine colorimeter severity MLP on synthetic RGB data."""
    import torch
    import torch.nn as nn
    import torch.optim as optim
    from torch.utils.data import DataLoader, TensorDataset

    csv_path = DATA_DIR / "urine_training_data.csv"
    if not csv_path.is_file():
        print(f"ERROR: Training data not found at {csv_path}")
        print("       Run 'python generate_datasets.py' first.")
        return False

    # Load CSV
    features = []
    labels = []
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            features.append([float(row["red"]), float(row["green"]), float(row["blue"])])
            labels.append(int(row["severity"]))

    X = torch.tensor(features, dtype=torch.float32)
    y = torch.tensor(labels, dtype=torch.long)

    # 80/20 split
    n = len(X)
    n_train = int(n * 0.8)
    perm = torch.randperm(n, generator=torch.Generator().manual_seed(42))
    train_ds = TensorDataset(X[perm[:n_train]], y[perm[:n_train]])
    test_ds = TensorDataset(X[perm[n_train:]], y[perm[n_train:]])

    train_loader = DataLoader(train_ds, batch_size=32, shuffle=True)
    test_loader = DataLoader(test_ds, batch_size=64)

    # Build model (same architecture as urine_processor.Urine_CNN)
    class Urine_CNN(nn.Module):
        def __init__(self):
            super().__init__()
            self.net = nn.Sequential(nn.Linear(3, 16), nn.ReLU(), nn.Linear(16, 2))

        def forward(self, x):
            return self.net(x)

    model = Urine_CNN()
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.Adam(model.parameters(), lr=0.005)

    print("Training Urine CNN model...")
    print(f"  Train samples: {n_train}, Test samples: {n - n_train}")
    print(f"  Architecture: Linear(3->16) -> ReLU -> Linear(16->2)")

    epochs = 30
    for epoch in range(1, epochs + 1):
        model.train()
        total_loss = 0.0
        for batch_x, batch_y in train_loader:
            optimizer.zero_grad()
            logits = model(batch_x)
            loss = criterion(logits, batch_y)
            loss.backward()
            optimizer.step()
            total_loss += loss.item() * batch_x.size(0)
        avg_loss = total_loss / n_train

        if epoch % 10 == 0 or epoch == 1:
            model.eval()
            correct = 0
            total = 0
            with torch.inference_mode():
                for batch_x, batch_y in test_loader:
                    preds = torch.argmax(model(batch_x), dim=1)
                    correct += (preds == batch_y).sum().item()
                    total += batch_y.size(0)
            print(f"  Epoch {epoch:3d}/{epochs}: loss={avg_loss:.4f}, "
                  f"test_acc={correct / total:.2%}")

    # Final accuracy
    model.eval()
    correct = 0
    total = 0
    with torch.inference_mode():
        for batch_x, batch_y in test_loader:
            preds = torch.argmax(model(batch_x), dim=1)
            correct += (preds == batch_y).sum().item()
            total += batch_y.size(0)
    print(f"  Final test accuracy: {correct / total:.2%}")

    # Save
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = MODELS_DIR / "urine_cnn.pt"
    torch.save({"state_dict": model.state_dict()}, out_path)
    print(f"  Saved to: {out_path}")
    return True


# ============================================================================ #
# Main
# ============================================================================ #
def main():
    print("=" * 70)
    print("RAKSHA-SIM MODEL TRAINER")
    print("=" * 70)
    print()

    results = {}

    print("-" * 70)
    results["XGBoost Triage"] = train_triage_model()
    print()

    print("-" * 70)
    results["ECG CNN"] = train_ecg_model()
    print()

    print("-" * 70)
    results["Urine CNN"] = train_urine_model()
    print()

    print("=" * 70)
    print("TRAINING SUMMARY")
    print("=" * 70)
    for name, ok in results.items():
        status = "OK" if ok else "FAILED"
        print(f"  {name}: {status}")
    print()

    all_ok = all(results.values())
    if all_ok:
        print("All models trained and saved successfully!")
    else:
        print("Some models failed to train. Check the output above.")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())

