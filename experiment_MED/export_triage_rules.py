"""Export the *trained* XGBoost triage booster as an exact rule table.

PRD §3/§4: "XGBoost -> Dart rule/lookup table derived from the trained tree's
actual splits". This replaces the Keras surrogate in convert_to_tflite.py,
which (a) approximated the model and (b) was fitted to the random dummy
booster in models/, not the real one at ./triage_xgboost.json.

Reads the XGBoost JSON model directly, so xgboost is NOT needed to export.
If xgboost IS installed, it also generates parity fixtures and refuses to
write anything unless the pure evaluator matches booster.predict().

    python export_triage_rules.py                              # uses config path
    python export_triage_rules.py --model triage_xgboost.json --dart-out ../raksha-dash

Outputs
    triage_rules.json                           handoff artifact (Anushka)
    <dart-out>/lib/triage/xgb_triage_model.dart generated evaluator (Arnav)
    <dart-out>/test/fixtures/triage_parity_vectors.json  (needs xgboost)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Sequence

import numpy as np

FEATURES = ("ecg_hr", "bp_sys", "bp_dia", "spo2", "temperature", "urine_severity")
CLASSES = ("Green", "Yellow", "Red")
PARITY_TOL = 1e-5


def f32(v: float) -> float:
    """Exact float32 value as a Python float (what XGBoost actually compares)."""
    return float(np.float32(v))


# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Tree:
    group: int                 # class index this tree votes for
    left: List[int]
    right: List[int]
    feature: List[int]
    value: List[float]         # threshold for splits, leaf value for leaves
    default_left: List[bool]

    def leaf(self, x32: Sequence[float]) -> float:
        n = 0
        while self.left[n] != -1:
            v = x32[self.feature[n]]
            if math.isnan(v):
                n = self.left[n] if self.default_left[n] else self.right[n]
            else:
                n = self.left[n] if v < self.value[n] else self.right[n]
        return self.value[n]


@dataclass(frozen=True)
class RuleModel:
    features: tuple
    base_score: List[float]
    trees: List[Tree]
    source_sha256: str
    xgb_version: str

    def margins(self, x: Sequence[float]) -> np.ndarray:
        x32 = [float(np.float32(v)) for v in x]
        m = np.asarray(self.base_score, dtype=np.float32).copy()
        for t in self.trees:                         # float32 accumulation, tree order
            m[t.group] = np.float32(m[t.group] + np.float32(t.leaf(x32)))
        return m

    def predict_proba(self, x: Sequence[float]) -> np.ndarray:
        m = self.margins(x).astype(np.float64)
        e = np.exp(m - m.max())
        return (e / e.sum()).astype(np.float32)


# --------------------------------------------------------------------------- #
def _parse_base_score(raw: str, k: int) -> List[float]:
    raw = str(raw).strip()
    vals = [float(s) for s in raw.strip("[]").split(",")] if raw.startswith("[") else [float(raw)]
    if len(vals) == 1:
        vals *= k
    if len(vals) != k:
        raise ValueError(f"base_score has {len(vals)} entries, expected {k}")
    return [f32(v) for v in vals]


def load_rule_model(path: Path) -> RuleModel:
    blob = path.read_bytes()
    doc = json.loads(blob)
    learner = doc["learner"]
    obj = learner["objective"]["name"]
    if obj != "multi:softprob" and obj != "multi:softmax":
        raise ValueError(f"Unsupported objective {obj!r}")
    names = tuple(learner.get("feature_names") or FEATURES)
    if names != FEATURES:
        raise ValueError(f"Feature order drift: model={names}, pipeline={FEATURES}")

    k = int(learner["learner_model_param"]["num_class"])
    if k != len(CLASSES):
        raise ValueError(f"num_class={k}, expected {len(CLASSES)}")
    gb = learner["gradient_booster"]
    if gb.get("name") != "gbtree":
        raise ValueError(f"Unsupported booster {gb.get('name')!r} (dart/gblinear not handled)")
    model = gb["model"]
    if int(model["gbtree_model_param"].get("num_parallel_tree", 1)) != 1:
        raise ValueError("num_parallel_tree != 1 is not supported")

    trees: List[Tree] = []
    for t, group in zip(model["trees"], model["tree_info"]):
        if any(model_st != 0 for model_st in t.get("split_type", [])) or t.get("categories"):
            raise ValueError(f"Tree {t['id']} uses categorical splits - not supported")
        if int(t["tree_param"].get("size_leaf_vector", 1)) > 1:
            raise ValueError("Vector-leaf trees are not supported")
        trees.append(Tree(
            group=int(group),
            left=[int(v) for v in t["left_children"]],
            right=[int(v) for v in t["right_children"]],
            feature=[int(v) for v in t["split_indices"]],
            value=[f32(v) for v in t["split_conditions"]],
            default_left=[bool(v) for v in t["default_left"]],
        ))
    return RuleModel(
        features=names,
        base_score=_parse_base_score(learner["learner_model_param"]["base_score"], k),
        trees=trees,
        source_sha256=hashlib.sha256(blob).hexdigest(),
        xgb_version=".".join(map(str, doc.get("version", []))),
    )


# --------------------------------------------------------------------------- #
# Parity against the real booster
# --------------------------------------------------------------------------- #
def parity_inputs(rm: RuleModel, n_random: int = 400, seed: int = 7) -> np.ndarray:
    """Random vitals + every threshold hit exactly and just either side of it."""
    rng = np.random.default_rng(seed)
    lo = np.array([30, 60, 30, 70, 33, 0], dtype=np.float32)
    hi = np.array([180, 230, 150, 100, 43, 1], dtype=np.float32)
    rows = [rng.uniform(lo, hi).astype(np.float32) for _ in range(n_random)]
    for r in rows:
        r[5] = np.round(r[5])
    base = np.array([75, 120, 80, 98, 37, 0], dtype=np.float32)
    for t in rm.trees:
        for n, l in enumerate(t.left):
            if l == -1:
                continue
            thr = np.float32(t.value[n])
            for v in (thr, np.nextafter(thr, np.float32(-np.inf)), np.nextafter(thr, np.float32(np.inf))):
                r = base.copy()
                r[t.feature[n]] = v
                rows.append(r)
    for i in range(len(FEATURES)):          # missing-value routing
        r = base.copy()
        r[i] = np.nan
        rows.append(r)
    return np.unique(np.vstack(rows), axis=0)


def check_parity(rm: RuleModel, model_path: Path) -> list:
    import xgboost as xgb

    booster = xgb.Booster()
    booster.load_model(str(model_path))
    X = parity_inputs(rm)
    ref = booster.predict(xgb.DMatrix(X, feature_names=list(FEATURES), missing=np.nan))
    worst, vectors = 0.0, []
    for x, p in zip(X, ref):
        mine = rm.predict_proba(x)
        diff = float(np.max(np.abs(mine - p)))
        worst = max(worst, diff)
        if diff > PARITY_TOL or int(np.argmax(mine)) != int(np.argmax(p)):
            raise AssertionError(f"Parity failure at {x.tolist()}: rules={mine}, xgb={p}")
        vectors.append({
            "x": [None if math.isnan(v) else float(v) for v in x],
            "proba": [float(v) for v in p],
            "label": CLASSES[int(np.argmax(p))],
        })
    print(f"Parity OK: {len(X)} rows, max |diff| = {worst:.2e}")
    return vectors


# --------------------------------------------------------------------------- #
# Emitters
# --------------------------------------------------------------------------- #
def to_json(rm: RuleModel) -> dict:
    return {
        "format": "raksha-xgb-rules/1",
        "source_model_sha256": rm.source_sha256,
        "xgboost_version": rm.xgb_version,
        "features": list(rm.features),
        "classes": list(CLASSES),
        "semantics": "go left if x < threshold (float32); NaN -> default_left; "
                     "margin[c] = base_score[c] + sum(leaf of trees with group c); softmax",
        "base_score": rm.base_score,
        "trees": [
            {"group": t.group, "left": t.left, "right": t.right, "feature": t.feature,
             "value": t.value, "default_left": [int(b) for b in t.default_left]}
            for t in rm.trees
        ],
    }


def _dlist(xs) -> str:
    return ", ".join(repr(x) for x in xs)


def to_dart(rm: RuleModel) -> str:
    offsets, left, right, feat, val, dflt, group = [], [], [], [], [], [], []
    for t in rm.trees:
        base = len(left)
        offsets.append(base)
        group.append(t.group)
        left += [c if c == -1 else c + base for c in t.left]
        right += [c if c == -1 else c + base for c in t.right]
        feat += t.feature
        val += t.value
        dflt += [1 if b else 0 for b in t.default_left]
    return f"""// GENERATED by export_triage_rules.py - DO NOT EDIT BY HAND.
// Source model sha256: {rm.source_sha256}
// XGBoost {rm.xgb_version}, {len(rm.trees)} trees, {len(left)} nodes.
// Exact re-implementation of booster.predict(); verified by
// test/xgb_triage_model_test.dart against XGBoost's own outputs.
import 'dart:math' as math;
import 'dart:typed_data';

const List<String> kTriageFeatures = [{", ".join(repr(f) for f in rm.features)}];
const List<String> kTriageClasses = [{", ".join(repr(c) for c in CLASSES)}];
const String kTriageModelSha256 = '{rm.source_sha256}';

const List<double> _base = [{_dlist(rm.base_score)}];
const List<int> _root = [{_dlist(offsets)}];
const List<int> _group = [{_dlist(group)}];
const List<int> _left = [{_dlist(left)}];
const List<int> _right = [{_dlist(right)}];
const List<int> _feat = [{_dlist(feat)}];
const List<int> _dflt = [{_dlist(dflt)}];
const List<double> _val = [{_dlist(val)}];

class TriageProbs {{
  final Float32List probs; // [Green, Yellow, Red]
  const TriageProbs(this.probs);
  int get argmax {{
    var best = 0;
    for (var i = 1; i < probs.length; i++) {{
      if (probs[i] > probs[best]) best = i;
    }}
    return best;
  }}
  String get label => kTriageClasses[argmax];
}}

/// [features] must follow [kTriageFeatures] order. Use double.nan for a
/// missing reading; it is routed exactly like XGBoost routes missing values.
TriageProbs predictTriage(List<double> features) {{
  if (features.length != kTriageFeatures.length) {{
    throw ArgumentError('expected ${{kTriageFeatures.length}} features, got ${{features.length}}');
  }}
  final x = Float32List.fromList(features); // XGBoost compares in float32
  final margin = Float32List.fromList(_base);
  for (var t = 0; t < _root.length; t++) {{
    var n = _root[t];
    while (_left[n] != -1) {{
      final v = x[_feat[n]];
      final goLeft = v.isNaN ? _dflt[n] == 1 : v < _val[n];
      n = goLeft ? _left[n] : _right[n];
    }}
    margin[_group[t]] += _val[n]; // float32 accumulation, same order as XGBoost
  }}
  var mx = margin[0];
  for (final m in margin) {{
    if (m > mx) mx = m;
  }}
  var sum = 0.0;
  final e = List<double>.generate(margin.length, (i) => math.exp(margin[i] - mx));
  for (final v in e) {{
    sum += v;
  }}
  return TriageProbs(Float32List.fromList([for (final v in e) v / sum]));
}}
"""


DART_TEST = """import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Adjust the package name to match pubspec.yaml if it differs.
import 'package:raksha_dash/triage/xgb_triage_model.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/triage_parity_vectors.json').readAsStringSync());

  test('fixture was generated from the same model as the Dart tables', () {
    expect(fixture['source_model_sha256'], kTriageModelSha256);
  });

  test('Dart triage == XGBoost booster.predict on every fixture row', () {
    final rows = fixture['vectors'] as List;
    expect(rows, isNotEmpty);
    for (final row in rows) {
      final x = [
        for (final v in row['x'] as List) v == null ? double.nan : (v as num).toDouble()
      ];
      final out = predictTriage(x);
      final want = [for (final v in row['proba'] as List) (v as num).toDouble()];
      for (var i = 0; i < 3; i++) {
        expect(out.probs[i], closeTo(want[i], 1e-5), reason: 'row $x class $i');
      }
      expect(out.label, row['label'], reason: 'row $x');
    }
  });
}
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=Path, default=None,
                    help="XGBoost JSON model (default: config.triage.model_path)")
    ap.add_argument("--out", type=Path, default=Path("triage_rules.json"))
    ap.add_argument("--dart-out", type=Path, default=Path("dart_out"),
                    help="root of the Flutter project (raksha-dash)")
    ap.add_argument("--skip-parity", action="store_true",
                    help="export without xgboost (NOT acceptable for a release build)")
    args = ap.parse_args()

    model_path = args.model
    if model_path is None:
        from config import get_config
        model_path = get_config().triage.model_path
    rm = load_rule_model(model_path)
    print(f"Loaded {len(rm.trees)} trees from {model_path} (xgboost {rm.xgb_version})")

    vectors = None
    if not args.skip_parity:
        try:
            vectors = check_parity(rm, model_path)
        except ImportError:
            print("ERROR: xgboost not installed; cannot prove fidelity. "
                  "Install xgboost>=3.1 or pass --skip-parity for a draft.", file=sys.stderr)
            return 2

    args.out.write_text(json.dumps(to_json(rm), indent=1))
    lib = args.dart_out / "lib" / "triage"
    lib.mkdir(parents=True, exist_ok=True)
    (lib / "xgb_triage_model.dart").write_text(to_dart(rm))
    tests = args.dart_out / "test"
    (tests / "fixtures").mkdir(parents=True, exist_ok=True)
    (tests / "xgb_triage_model_test.dart").write_text(DART_TEST)
    if vectors is not None:
        (tests / "fixtures" / "triage_parity_vectors.json").write_text(json.dumps(
            {"source_model_sha256": rm.source_sha256, "vectors": vectors}))
    print(f"Wrote {args.out}, {lib / 'xgb_triage_model.dart'}"
          + ("" if vectors is None else ", parity fixture"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
