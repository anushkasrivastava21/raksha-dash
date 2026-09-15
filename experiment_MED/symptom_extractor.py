"""Symptom extraction without a transformer.

The biomedical BERT was the heaviest component in the pipeline (~420 MB of
weights) and was also the weakest link on this data: it is trained on formal
English clinical notes, so on a noisy Hinglish ASR transcript the curated
keyword list was already doing most of the work.

This module replaces it with a gazetteer over a curated bilingual lexicon,
plus two things the NER never gave us:
  * negation handling  - "seene mein dard nahi hai" no longer escalates to Red
  * severity tiers     - a cough and chest pain no longer weigh the same

Cost: one compiled regex, a few hundred microseconds, zero model weights.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from functools import lru_cache
from typing import Dict, List, Optional, Tuple

from config import get_config

log = logging.getLogger(__name__)
CFG = get_config().audio

TIER_ORDER = {"critical": 3, "moderate": 2, "minor": 1}
# Clause separator inserted in place of punctuation so a negation scope cannot
# leak across "denies chest pain, reports palpitations".
BOUNDARY = "|"


@dataclass(frozen=True)
class Symptom:
    canonical: str
    tier: str
    matched: str
    negated: bool = False
    fuzzy: bool = False


@dataclass(frozen=True)
class _Lexicon:
    variant_to_entry: Dict[str, Tuple[str, str]]     # variant -> (canonical, tier)
    pattern: Optional[re.Pattern]
    prefix_cues: frozenset
    prefix_window: int
    suffix_cues: frozenset
    suffix_window: int
    fuzzy_candidates: Tuple[str, ...]                # critical+moderate variants only


@lru_cache(maxsize=1)
def _lexicon() -> Optional[_Lexicon]:
    try:
        doc = json.loads(CFG.lexicon_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        log.error("Symptom lexicon unreadable at %s: %s", CFG.lexicon_file, exc)
        return None

    mapping: Dict[str, Tuple[str, str]] = {}
    fuzzy: List[str] = []
    for canonical, entry in doc.get("symptoms", {}).items():
        tier = entry.get("tier", "minor")
        for variant in entry.get("variants", ()):
            variant = variant.strip().lower()
            if not variant:
                continue
            mapping[variant] = (canonical, tier)
            if tier in ("critical", "moderate"):
                fuzzy.append(variant)
    if not mapping:
        return None

    # Longest variant first so "chest pain" beats "pain".
    alternation = "|".join(re.escape(v) for v in sorted(mapping, key=len, reverse=True))
    neg = doc.get("negation", {})
    return _Lexicon(
        variant_to_entry=mapping,
        pattern=re.compile(rf"\b(?:{alternation})\b"),
        prefix_cues=frozenset(neg.get("prefix_cues", ())),
        prefix_window=int(neg.get("prefix_window_tokens", 4)),
        suffix_cues=frozenset(neg.get("suffix_cues", ())),
        suffix_window=int(neg.get("suffix_window_tokens", 3)),
        fuzzy_candidates=tuple(dict.fromkeys(fuzzy)),
    )


def normalise(text: str) -> str:
    """Lower-case, mark clause boundaries, de-stutter, cap length."""
    text = text.lower()
    text = re.sub(r"[.,;:!?\u0964]+", f" {BOUNDARY} ", text)
    text = re.sub(r"[^\w\s|]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\b(\w+)(?: \1\b)+", r"\1", text)
    return text[: CFG.max_transcript_chars]


def _negated_positions(tokens: List[str], lex: _Lexicon) -> set:
    """Token indices falling inside a negation scope.

    English negation is pre-positional ("no chest pain") so the scope runs
    forward from the cue. Hindi/Hinglish negation is post-positional
    ("seene mein dard nahi hai") so the scope runs backward. Applying only the
    English direction silently inverts every Hinglish report.
    """
    scope: set = set()
    for i, token in enumerate(tokens):
        if token in lex.prefix_cues:
            for j in range(i + 1, min(len(tokens), i + 1 + lex.prefix_window)):
                if tokens[j] == BOUNDARY:
                    break
                scope.add(j)
        if token in lex.suffix_cues:
            for j in range(i - 1, max(-1, i - lex.suffix_window - 1), -1):
                if tokens[j] == BOUNDARY:
                    break
                scope.add(j)
    return scope


def _fuzzy_pass(tokens: List[str], covered: set, negated: set, lex: _Lexicon) -> List[Symptom]:
    """Catch ASR misspellings of high-severity terms only ('sene me dard').

    Restricted to critical/moderate variants: the cost of a fuzzy false positive
    on a minor symptom is not worth the recall.
    """
    try:
        from rapidfuzz import fuzz, process
    except ImportError:
        return []

    found: List[Symptom] = []
    seen = set()
    n_max = min(CFG.fuzzy_max_ngram, len(tokens))
    for size in range(1, n_max + 1):
        for i in range(len(tokens) - size + 1):
            if any(j in covered for j in range(i, i + size)):
                continue
            gram = " ".join(tokens[i:i + size])
            if len(gram) < 5:
                continue
            match = process.extractOne(gram, lex.fuzzy_candidates,
                                       scorer=fuzz.ratio,
                                       score_cutoff=CFG.fuzzy_threshold)
            if not match:
                continue
            canonical, tier = lex.variant_to_entry[match[0]]
            if canonical in seen:
                continue
            seen.add(canonical)
            found.append(Symptom(canonical, tier, gram, negated=i in negated, fuzzy=True))
    return found


def extract(transcript: str) -> List[Symptom]:
    """Return de-duplicated, negation-aware symptoms found in a transcript."""
    lex = _lexicon()
    if not transcript or lex is None or lex.pattern is None:
        return []

    text = normalise(transcript)
    if not text:
        return []

    tokens = text.split()
    # char offset -> token index, so negation can be checked in token space.
    offsets, cursor = [], 0
    for tok in tokens:
        cursor = text.index(tok, cursor)
        offsets.append(cursor)
        cursor += len(tok)

    negated_scope = _negated_positions(tokens, lex)
    results: Dict[str, Symptom] = {}
    covered: set = set()
    for match in lex.pattern.finditer(text):
        canonical, tier = lex.variant_to_entry[match.group(0)]
        token_index = next((i for i, off in enumerate(offsets) if off >= match.start()), 0)
        span = len(match.group(0).split())
        covered.update(range(token_index, token_index + span))
        negated = token_index in negated_scope
        existing = results.get(canonical)
        # An affirmed mention always beats an earlier negated one.
        if existing is None or (existing.negated and not negated):
            results[canonical] = Symptom(canonical, tier, match.group(0), negated)

    if CFG.fuzzy_enabled:
        for symptom in _fuzzy_pass(tokens, covered, negated_scope, lex):
            results.setdefault(symptom.canonical, symptom)

    kept: List[Symptom] = []
    for symptom in results.values():
        if not symptom.negated:
            kept.append(symptom)
        elif symptom.tier == "critical" and not CFG.negation_suppresses_critical:
            # Window-based negation cannot resolve "khoon behna band nahi ho raha"
            # ("the bleeding is not stopping"), where the cue attaches to the verb.
            # For a triage device, dropping a critical symptom is the expensive
            # error, so keep it, demoted, and let the medic confirm.
            log.warning("Ambiguous negation on critical symptom %r - retained as "
                        "moderate for medic confirmation.", symptom.canonical)
            kept.append(Symptom(symptom.canonical, "moderate", symptom.matched,
                                negated=False, fuzzy=symptom.fuzzy))
        else:
            log.info("Negated mention ignored: %s", symptom.canonical)
    return sorted(kept, key=lambda s: (-TIER_ORDER.get(s.tier, 0), s.canonical))


def highest_tier(symptoms: List[Symptom]) -> Optional[str]:
    if not symptoms:
        return None
    return max(symptoms, key=lambda s: TIER_ORDER.get(s.tier, 0)).tier


def names(symptoms: List[Symptom]) -> List[str]:
    """Canonical English names - what the frontend and the medic's chart see."""
    return [s.canonical for s in symptoms]
