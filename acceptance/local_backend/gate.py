#!/usr/bin/env python3
"""Deterministic release gates for the local KB Whisper Transcription Backend."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, asdict
import hashlib
import json
import math
from pathlib import Path
import sys
import unicodedata
from typing import Any, Sequence, cast


PUNCTUATION = frozenset(".,?!:;")
MODES_BY_LANGUAGE = {"en": ("en", "auto"), "sv": ("sv", "auto")}
WER_LIMITS = {"en": 0.15, "sv": 0.15, "auto:en": 0.20, "auto:sv": 0.20}
PINNED_CANDIDATE = {
    "model_revision": "3564d61a42fc210ceaa55a22a96dd64478959c78",
    "model_sha256": "de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6",
    "model_bytes": 487_601_984,
    "runtime": "whisper.cpp-v1.9.1",
    "runtime_source_sha256": "147267177eef7b22ec3d2476dd514d1b12e160e176230b740e3d1bd600118447",
}
REQUIRED_FAULT_ASSERTIONS = {
    "successful_lifecycle": ("serialized_phases", "exactly_one_insertion"),
    "empty_capture": ("abandoned", "no_insertion"),
    "empty_final_transcript": ("abandoned", "no_insertion"),
    "helper_loss_during_capture": ("feedback_until_release", "abandoned"),
    "helper_crash": ("abandoned", "restart_scheduled"),
    "malformed_ipc": ("abandoned", "restart_scheduled"),
    "inference_failure": ("abandoned", "restart_scheduled"),
    "restart_backoff_and_latch": ("backoff_1_2_4_seconds", "latched_after_three"),
    "successful_final_resets_failures": ("failure_budget_reset",),
    "cooperative_cancellation": ("cancel_requested_at_9500ms", "abandoned", "no_insertion"),
    "forced_termination": ("terminated_by_10000ms", "abandoned", "no_insertion"),
    "final_timeout_race": ("exactly_one_terminal_winner",),
    "stale_events": ("late_ignored", "duplicate_ignored", "mismatched_id_ignored", "post_cancel_ignored"),
    "non_idle_press": ("press_ignored",),
    "backend_switch": ("lease_stays_pinned", "no_cross_backend_audio", "new_capture_blocked"),
    "prerequisite_loss": ("active_utterance_poisoned", "capture_stopped"),
    "helper_recovery": ("ready_only_after_warmup",),
    "abandonment_has_no_side_effects": ("no_insertion", "no_retry", "no_openai_fallback"),
}
REQUIRED_FAULTS = tuple(REQUIRED_FAULT_ASSERTIONS)
REQUIRED_PRIVACY_PROBES = (
    "offline_operation",
    "network_boundary",
    "default_logs",
    "model_operation_boundary",
)


class ContractError(ValueError):
    pass


@dataclass(frozen=True)
class Check:
    id: str
    category: str
    passed: bool
    observed: Any
    required: Any


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read {path.name}: {error}") from error
    require(isinstance(value, dict), f"{path.name}: root must be an object")
    return cast(dict[str, Any], value)


def wer_tokens(text: str) -> list[str]:
    tokens: list[str] = []
    current: list[str] = []
    for character in unicodedata.normalize("NFKC", text).casefold():
        category = unicodedata.category(character)
        if category.startswith(("L", "N")) or (character in "'’" and current):
            current.append(character)
        elif current:
            token = "".join(current).strip("'’")
            if token:
                tokens.append(token)
            current = []
    if current:
        token = "".join(current).strip("'’")
        if token:
            tokens.append(token)
    return tokens


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for ref_index, ref_word in enumerate(reference, start=1):
        current = [ref_index]
        for hyp_index, hyp_word in enumerate(hypothesis, start=1):
            current.append(min(
                current[-1] + 1,
                previous[hyp_index] + 1,
                previous[hyp_index - 1] + (ref_word != hyp_word),
            ))
        previous = current
    return previous[-1]


def punctuation_anchors(text: str) -> Counter[tuple[str, int]]:
    anchors: Counter[tuple[str, int]] = Counter()
    word_count = 0
    in_word = False
    for character in unicodedata.normalize("NFKC", text):
        if unicodedata.category(character).startswith(("L", "N")):
            if not in_word:
                word_count += 1
            in_word = True
        else:
            in_word = False
            if character in PUNCTUATION:
                anchors[(character, word_count)] += 1
    return anchors


def multiset_overlap(left: Counter[Any], right: Counter[Any]) -> int:
    return sum((left & right).values())


def safe_ratio(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 1.0


def round_metric(value: float) -> float:
    return round(value, 6)


def is_measurement(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value) and value >= 0


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise ContractError(f"manifest: cannot read audio fixture {path.name}: {error}") from error
    return digest.hexdigest()


def resolve_artifact(root: Path, relative_path: Any, description: str) -> Path:
    require(isinstance(relative_path, str) and bool(relative_path), f"{description} path is required")
    assert isinstance(relative_path, str)
    relative = Path(relative_path)
    require(not relative.is_absolute(), f"{description} path must be relative")
    resolved_root = root.resolve()
    resolved = (resolved_root / relative).resolve()
    try:
        resolved.relative_to(resolved_root)
    except ValueError as error:
        raise ContractError(f"{description} path escapes its evidence directory") from error
    require(resolved.is_file(), f"{description} file is missing")
    return resolved


def validate_manifest(manifest: dict[str, Any], manifest_root: Path) -> dict[str, dict[str, Any]]:
    require(manifest.get("schema_version") == 1, "manifest: unsupported schema_version")
    corpus = manifest.get("corpus")
    require(isinstance(corpus, dict), "manifest: corpus must be an object")
    assert isinstance(corpus, dict)
    require(isinstance(corpus.get("id"), str) and bool(corpus["id"]), "manifest: corpus id is required")
    require(corpus.get("human_speech") is True, "manifest: corpus must be human speech")
    require(corpus.get("redistributable") is True, "manifest: corpus must be redistributable")
    require(isinstance(corpus.get("license"), str) and bool(corpus["license"]), "manifest: corpus license is required")
    fixtures = manifest.get("fixtures")
    require(isinstance(fixtures, list) and bool(fixtures), "manifest: fixtures must be a non-empty array")
    assert isinstance(fixtures, list)
    indexed: dict[str, dict[str, Any]] = {}
    for fixture in fixtures:
        require(isinstance(fixture, dict), "manifest: each fixture must be an object")
        assert isinstance(fixture, dict)
        fixture_id = fixture.get("id")
        require(isinstance(fixture_id, str) and bool(fixture_id), "manifest: fixture id is required")
        assert isinstance(fixture_id, str)
        require(fixture_id not in indexed, f"manifest: duplicate fixture id {fixture_id}")
        language = fixture.get("language")
        require(language in MODES_BY_LANGUAGE, f"manifest: {fixture_id} language must be en or sv")
        assert isinstance(language, str)
        require(fixture.get("language_modes") == list(MODES_BY_LANGUAGE[language]), f"manifest: {fixture_id} must run explicit and auto modes")
        require(isinstance(fixture.get("exact_final_transcript"), str) and fixture["exact_final_transcript"], f"manifest: {fixture_id} exact Final Transcript is required")
        require(fixture.get("duration_class") in ("short", "medium", "long"), f"manifest: {fixture_id} duration_class is invalid")
        duration = fixture.get("duration_seconds")
        require(not isinstance(duration, bool) and isinstance(duration, (int, float)) and 0 < duration <= 15, f"manifest: {fixture_id} duration_seconds must be within (0, 15]")
        assert isinstance(duration, (int, float)) and not isinstance(duration, bool)
        duration_matches_class = (
            fixture["duration_class"] == "short" and duration <= 5
            or fixture["duration_class"] == "medium" and 5 < duration < 10
            or fixture["duration_class"] == "long" and 10 <= duration <= 15
        )
        require(duration_matches_class, f"manifest: {fixture_id} duration_seconds does not match duration_class")
        require(isinstance(fixture.get("speaker_id"), str) and bool(fixture["speaker_id"]), f"manifest: {fixture_id} speaker_id is required")
        require(isinstance(fixture.get("punctuation"), bool), f"manifest: {fixture_id} punctuation must be boolean")
        if fixture["punctuation"]:
            require(bool(punctuation_anchors(fixture["exact_final_transcript"])), f"manifest: {fixture_id} is marked for punctuation but its Final Transcript has no scored mark")
        require(isinstance(fixture.get("tags"), list) and all(isinstance(tag, str) for tag in fixture["tags"]), f"manifest: {fixture_id} tags must be an array of strings")
        protected = fixture.get("protected_semantics")
        require(isinstance(protected, list), f"manifest: {fixture_id} protected_semantics must be an array")
        assert isinstance(protected, list)
        for semantic in protected:
            require(isinstance(semantic, dict) and semantic.get("kind") in ("negation", "number", "command") and isinstance(semantic.get("text"), str) and bool(semantic["text"]), f"manifest: {fixture_id} has an invalid protected semantic")
        digest = fixture.get("audio_sha256")
        require(isinstance(digest, str) and len(digest) == 64 and all(c in "0123456789abcdef" for c in digest), f"manifest: {fixture_id} audio_sha256 is invalid")
        assert isinstance(digest, str)
        audio = fixture.get("audio")
        require(isinstance(audio, str) and bool(audio), f"manifest: {fixture_id} audio path is required")
        audio_path = resolve_artifact(manifest_root, audio, f"manifest: {fixture_id} audio")
        require(file_sha256(audio_path) == digest, f"manifest: {fixture_id} audio digest does not match")
        indexed[fixture_id] = fixture
    source_index = corpus.get("source_index")
    if source_index is not None:
        source_digest = corpus.get("source_index_sha256")
        require(isinstance(source_digest, str) and len(source_digest) == 64, "manifest: source index digest is invalid")
        source_path = resolve_artifact(manifest_root, source_index, "manifest: source index")
        require(file_sha256(source_path) == source_digest, "manifest: source index digest does not match")
        sources_document = load_json(source_path)
        require(sources_document.get("schema_version") == 1 and isinstance(sources_document.get("dataset_revision"), str), "manifest: source index identity is invalid")
        sources = sources_document.get("sources")
        require(isinstance(sources, list), "manifest: source index rows must be an array")
        assert isinstance(sources, list)
        source_ids: set[str] = set()
        source_speakers: dict[str, set[str]] = {}
        language_source_speakers: dict[str, set[str]] = {language: set() for language in MODES_BY_LANGUAGE}
        for source in sources:
            require(isinstance(source, dict) and isinstance(source.get("fixture_id"), str), "manifest: source index row is invalid")
            source_id = source["fixture_id"]
            require(source_id not in source_ids, f"manifest: duplicate source index fixture {source_id}")
            require(source_id in indexed, f"manifest: unknown source index fixture {source_id}")
            require(source.get("source_duration_seconds") == indexed[source_id]["duration_seconds"], f"manifest: source duration mismatch for {source_id}")
            source_sha256 = source.get("source_sha256")
            require(isinstance(source_sha256, str) and len(source_sha256) == 64, f"manifest: source digest is invalid for {source_id}")
            source_speaker = source.get("source_speaker_sha256")
            require(isinstance(source_speaker, str) and len(source_speaker) == 64 and all(character in "0123456789abcdef" for character in source_speaker), f"manifest: source speaker binding is invalid for {source_id}")
            require(all(isinstance(source.get(field), str) and source[field] for field in ("locale", "split", "archive_shard", "clip")), f"manifest: source location is incomplete for {source_id}")
            local_speaker = indexed[source_id]["speaker_id"]
            source_speakers.setdefault(local_speaker, set()).add(source_speaker)
            language_source_speakers[indexed[source_id]["language"]].add(source_speaker)
            source_ids.add(source_id)
        require(source_ids == set(indexed), "manifest: source index must cover every fixture exactly once")
        require(all(len(bindings) == 1 for bindings in source_speakers.values()), "manifest: a local speaker label maps to multiple source speakers")
        require(all(len(bindings) == 2 for bindings in language_source_speakers.values()), "manifest: source index must prove exactly two speakers per language")
    return indexed


def corpus_check(fixtures: dict[str, dict[str, Any]]) -> Check:
    language_counts = Counter(fixture["language"] for fixture in fixtures.values())
    speaker_counts = {
        language: len({fixture["speaker_id"] for fixture in fixtures.values() if fixture["language"] == language})
        for language in MODES_BY_LANGUAGE
    }
    duration_counts = {
        language: Counter(fixture["duration_class"] for fixture in fixtures.values() if fixture["language"] == language)
        for language in MODES_BY_LANGUAGE
    }
    tags = {tag for fixture in fixtures.values() for tag in fixture["tags"]}
    required_tags = {"natural-dictation", "technical-term", "proper-noun", "numbers", "self-correction", "negation", "command"}
    protected_kinds = {
        semantic["kind"]
        for fixture in fixtures.values()
        for semantic in fixture["protected_semantics"]
    }
    punctuation_languages = {
        fixture["language"] for fixture in fixtures.values() if fixture["punctuation"]
    }
    balanced = all(
        set(counts) == {"short", "medium", "long"} and max(counts.values()) - min(counts.values()) <= 1
        for counts in duration_counts.values()
    )
    passed = (
        language_counts == {"en": 10, "sv": 10}
        and speaker_counts == {"en": 2, "sv": 2}
        and balanced
        and required_tags <= tags
        and protected_kinds == {"negation", "number", "command"}
        and punctuation_languages == {"en", "sv"}
    )
    observed = {
        "fixtures_per_language": dict(sorted(language_counts.items())),
        "speakers_per_language": speaker_counts,
        "duration_classes_per_language": {language: dict(sorted(counts.items())) for language, counts in duration_counts.items()},
        "missing_tags": sorted(required_tags - tags),
        "missing_protected_semantics": sorted({"negation", "number", "command"} - protected_kinds),
        "languages_with_punctuation": sorted(punctuation_languages),
    }
    return Check("corpus.authoritative_shape", "corpus", passed, observed, {"fixtures_per_language": 10, "speakers_per_language": 2, "balanced_duration_classes": ["short", "medium", "long"], "required_tags": sorted(required_tags)})


def packaged_identity_check(evidence: dict[str, Any]) -> Check:
    identity = evidence.get("artifact_identity")
    required = {
        "same_packaged_pair": True,
        "valid_signatures": True,
        "receipt_matches_helper": True,
        "pinned_model_and_runtime": True,
    }
    if not isinstance(identity, dict):
        return Check("candidate.packaged_identity", "candidate", False, identity, required)
    daemon = identity.get("daemon")
    helper = identity.get("helper")
    model = identity.get("model")
    receipt = identity.get("receipt")
    provenance = identity.get("provenance")
    if not all(isinstance(value, dict) for value in (daemon, helper, model, receipt, provenance)):
        return Check("candidate.packaged_identity", "candidate", False, identity, required)
    assert isinstance(daemon, dict) and isinstance(helper, dict) and isinstance(model, dict)
    assert isinstance(receipt, dict) and isinstance(provenance, dict)
    daemon_signature = daemon.get("signature")
    helper_signature = helper.get("signature")
    signatures_pass = (
        isinstance(daemon_signature, dict)
        and daemon_signature.get("verified") is True
        and daemon_signature.get("identifier") == "me.ba78.type-wave"
        and isinstance(helper_signature, dict)
        and helper_signature.get("verified") is True
        and helper_signature.get("identifier") == "me.ba78.type-wave.whisper"
    )
    pinned_pass = (
        model == {"bytes": PINNED_CANDIDATE["model_bytes"], "sha256": PINNED_CANDIDATE["model_sha256"]}
        and receipt.get("model_revision") == PINNED_CANDIDATE["model_revision"]
        and receipt.get("model_sha256") == PINNED_CANDIDATE["model_sha256"]
        and receipt.get("model_bytes") == PINNED_CANDIDATE["model_bytes"]
        and receipt.get("runtime") == PINNED_CANDIDATE["runtime"]
        and provenance.get("model_revision") == PINNED_CANDIDATE["model_revision"]
        and provenance.get("runtime_source_sha256") == PINNED_CANDIDATE["runtime_source_sha256"]
    )
    digest_fields = (daemon.get("sha256"), helper.get("sha256"), receipt.get("sha256"), provenance.get("sha256"))
    digests_valid = all(
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
        for value in digest_fields
    )
    passed = (
        identity.get("same_packaged_pair") is True
        and signatures_pass
        and pinned_pass
        and digests_valid
        and receipt.get("matches_helper") is True
        and receipt.get("runtime_sha256") == helper.get("sha256")
    )
    return Check("candidate.packaged_identity", "candidate", passed, identity, required)


def quality_checks(fixtures: dict[str, dict[str, Any]], evidence: dict[str, Any]) -> tuple[list[Check], list[dict[str, Any]]]:
    rows = evidence.get("transcription_runs")
    require(isinstance(rows, list), "evidence: transcription_runs must be an array")
    assert isinstance(rows, list)
    indexed: dict[tuple[str, str], dict[str, Any]] = {}
    details: list[dict[str, Any]] = []
    totals: dict[str, list[int]] = {group: [0, 0] for group in WER_LIMITS}
    punctuation_reference: Counter[tuple[str, int, str, str]] = Counter()
    punctuation_hypothesis: Counter[tuple[str, int, str, str]] = Counter()
    protected_failures: list[str] = []

    for row in rows:
        require(isinstance(row, dict), "evidence: each transcription run must be an object")
        assert isinstance(row, dict)
        fixture_id = row.get("fixture_id")
        mode = row.get("mode")
        require(isinstance(fixture_id, str) and isinstance(mode, str), "evidence: transcription run identity is invalid")
        assert isinstance(fixture_id, str) and isinstance(mode, str)
        key = (fixture_id, mode)
        require(fixture_id in fixtures, f"evidence: unknown fixture {fixture_id}")
        require(key not in indexed, f"evidence: duplicate transcription run {key[0]}/{key[1]}")
        fixture = fixtures[key[0]]
        require(key[1] in fixture["language_modes"], f"evidence: invalid mode for {key[0]}")
        final_transcript = row.get("final_transcript")
        require(isinstance(final_transcript, str), f"evidence: {key[0]}/{key[1]} Final Transcript must be text")
        assert isinstance(final_transcript, str)
        semantic_errors = row.get("meaning_changing_errors")
        require(isinstance(semantic_errors, list) and all(error in ("negation", "number", "command") for error in semantic_errors), f"evidence: {key[0]}/{key[1]} meaning_changing_errors is invalid")
        assert isinstance(semantic_errors, list)
        latencies = row.get("latency_ms")
        require(isinstance(latencies, list) and len(latencies) == 3 and all(is_measurement(value) for value in latencies), f"evidence: {key[0]}/{key[1]} requires three finite non-negative latency runs")
        assert isinstance(latencies, list)
        indexed[key] = row

        reference_words = wer_tokens(fixture["exact_final_transcript"])
        hypothesis_words = wer_tokens(final_transcript)
        errors = edit_distance(reference_words, hypothesis_words)
        group = fixture["language"] if key[1] != "auto" else f"auto:{fixture['language']}"
        totals[group][0] += errors
        totals[group][1] += len(reference_words)
        utterance_wer = safe_ratio(errors, len(reference_words))
        details.append({
            "fixture_id": key[0],
            "mode": key[1],
            "wer": round_metric(utterance_wer),
            "latency_ms_median": sorted(latencies)[1],
            "latency_ms_worst": max(latencies),
        })

        ref_marks = punctuation_anchors(fixture["exact_final_transcript"])
        hyp_marks = punctuation_anchors(final_transcript)
        punctuation_reference.update({(mark, anchor, key[0], key[1]): count for (mark, anchor), count in ref_marks.items()})
        punctuation_hypothesis.update({(mark, anchor, key[0], key[1]): count for (mark, anchor), count in hyp_marks.items()})

        # Literal matching cannot distinguish semantic loss from an equivalent form
        # (for example "two" and "2"). The predeclared human review is authoritative.
        protected_failures.extend(f"{key[0]}/{key[1]}:{kind}" for kind in semantic_errors)

    expected = {(fixture_id, mode) for fixture_id, fixture in fixtures.items() for mode in fixture["language_modes"]}
    missing = sorted(expected - indexed.keys())
    require(not missing, f"evidence: missing transcription runs {missing}")

    checks = []
    for group, limit in WER_LIMITS.items():
        errors, word_count = totals[group]
        require(word_count > 0, f"manifest: no fixtures for quality group {group}")
        value = safe_ratio(errors, word_count)
        checks.append(Check(f"quality.wer.{group}", "quality", value <= limit, round_metric(value), {"maximum": limit}))
    worst = max(detail["wer"] for detail in details)
    checks.append(Check("quality.per_utterance_wer", "quality", worst <= 0.40, worst, {"maximum": 0.40}))
    true_positive = multiset_overlap(punctuation_reference, punctuation_hypothesis)
    precision = safe_ratio(true_positive, sum(punctuation_hypothesis.values()))
    recall = safe_ratio(true_positive, sum(punctuation_reference.values()))
    punctuation_f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    checks.append(Check("quality.punctuation_f1", "quality", punctuation_f1 >= 0.75, round_metric(punctuation_f1), {"minimum": 0.75}))
    checks.append(Check("quality.protected_semantics", "quality", not protected_failures, protected_failures, {"maximum_errors": 0}))
    return checks, sorted(details, key=lambda detail: (detail["fixture_id"], detail["mode"]))


def performance_checks(details: list[dict[str, Any]], evidence: dict[str, Any]) -> list[Check]:
    performance = evidence.get("performance")
    require(isinstance(performance, dict), "evidence: performance must be an object")
    assert isinstance(performance, dict)
    machine = performance.get("machine")
    require(isinstance(machine, dict), "evidence: performance.machine must be an object")
    assert isinstance(machine, dict)
    require(machine.get("chip") == "Apple M1" or isinstance(machine.get("chip"), str), "evidence: performance.machine.chip must be text")
    require(not isinstance(machine.get("memory_gib"), bool) and isinstance(machine.get("memory_gib"), (int, float)) and machine["memory_gib"] > 0, "evidence: performance.machine.memory_gib must be positive")
    for field in ("cached_ready_ms", "first_metal_ready_ms", "idle_rss_mib", "peak_rss_mib"):
        require(is_measurement(performance.get(field)), f"evidence: performance.{field} must be a finite non-negative measurement")
    checks = [
        Check("performance.base_m1", "performance", machine.get("chip") == "Apple M1" and machine.get("memory_gib") == 8, machine, {"chip": "Apple M1", "memory_gib": 8}),
        Check("performance.transcription_latency", "performance", max(detail["latency_ms_worst"] for detail in details) <= 2000, max(detail["latency_ms_worst"] for detail in details), {"maximum_ms": 2000, "runs_per_utterance": 3}),
        Check("performance.cached_ready", "performance", performance.get("cached_ready_ms", float("inf")) <= 2000, performance.get("cached_ready_ms"), {"maximum_ms": 2000}),
    ]
    first_ready = performance.get("first_metal_ready_ms", float("inf"))
    first_passed = first_ready <= 15000 and performance.get("first_metal_visible_preparing") is True and performance.get("first_metal_capture_accepted") is False
    checks.append(Check("performance.first_metal_preparation", "performance", first_passed, {"ready_ms": performance.get("first_metal_ready_ms"), "visible_preparing": performance.get("first_metal_visible_preparing"), "capture_accepted": performance.get("first_metal_capture_accepted")}, {"maximum_ms": 15000, "visible_preparing": True, "capture_accepted": False}))
    checks.extend([
        Check("performance.idle_rss", "performance", performance.get("idle_rss_mib", float("inf")) <= 600, performance.get("idle_rss_mib"), {"maximum_mib": 600}),
        Check("performance.peak_rss", "performance", performance.get("peak_rss_mib", float("inf")) <= 750, performance.get("peak_rss_mib"), {"maximum_mib": 750}),
    ])
    timeout = performance.get("timeout")
    require(isinstance(timeout, dict), "evidence: performance.timeout must be an object")
    assert isinstance(timeout, dict)
    require(isinstance(timeout.get("supported", True), bool), "evidence: performance.timeout.supported must be boolean")
    for field in ("cooperative_cancel_requested_ms", "helper_terminated_ms", "insertions"):
        require(is_measurement(timeout.get(field)), f"evidence: performance.timeout.{field} must be a finite non-negative measurement")
    require(isinstance(timeout.get("utterance_abandoned"), bool), "evidence: performance.timeout.utterance_abandoned must be boolean")
    timeout_passed = timeout.get("supported", True) is True and timeout.get("cooperative_cancel_requested_ms") == 9500 and timeout.get("helper_terminated_ms", float("inf")) <= 10000 and timeout.get("utterance_abandoned") is True and timeout.get("insertions") == 0
    checks.append(Check("performance.hard_timeout", "performance", timeout_passed, timeout, {"cancel_requested_ms": 9500, "terminated_by_ms": 10000, "utterance_abandoned": True, "insertions": 0}))
    return checks


def privacy_checks(evidence: dict[str, Any], evidence_root: Path) -> list[Check]:
    privacy = evidence.get("privacy")
    require(isinstance(privacy, dict), "evidence: privacy must be an object")
    assert isinstance(privacy, dict)
    artifacts = privacy.get("artifacts")
    require(isinstance(artifacts, list), "evidence: privacy.artifacts must be an array")
    assert isinstance(artifacts, list)
    observations: dict[str, Any] = {}
    for artifact in artifacts:
        require(isinstance(artifact, dict) and artifact.get("name") in REQUIRED_PRIVACY_PROBES, "evidence: invalid privacy probe artifact")
        assert isinstance(artifact, dict)
        name = artifact["name"]
        require(name not in observations, f"evidence: duplicate privacy probe artifact {name}")
        expected_digest = artifact.get("trace_sha256")
        require(isinstance(expected_digest, str) and len(expected_digest) == 64 and all(c in "0123456789abcdef" for c in expected_digest), f"evidence: invalid privacy trace digest for {name}")
        trace_path = resolve_artifact(evidence_root, artifact.get("trace"), f"evidence: {name} privacy trace")
        require(file_sha256(trace_path) == expected_digest, f"evidence: {name} privacy trace digest does not match")
        trace = load_json(trace_path)
        require(trace.get("schema_version") == 1 and trace.get("probe") == name and isinstance(trace.get("observed"), dict), f"evidence: {name} privacy trace is invalid")
        observations[name] = trace["observed"]
    missing = sorted(set(REQUIRED_PRIVACY_PROBES) - observations.keys())
    require(not missing, f"evidence: missing privacy probe artifacts {missing}")
    offline = observations["offline_operation"]
    require(isinstance(offline, dict), "evidence: offline_operation privacy observations must be an object")
    require(isinstance(offline.get("supported", True), bool), "evidence: offline_operation support observation is invalid")
    credentials = offline.get("credentials_available")
    require(isinstance(credentials, dict) and all(isinstance(credentials.get(name), bool) for name in ("openai", "hugging_face")), "evidence: offline_operation credential observations are invalid")
    require(all(isinstance(offline.get(field), bool) for field in ("network_disabled", "ready_offline", "corpus_completed")), "evidence: offline_operation observations are invalid")
    offline_passed = offline.get("supported", True) is True and credentials == {"openai": False, "hugging_face": False} and offline.get("network_disabled") is True and offline.get("ready_offline") is True and offline.get("corpus_completed") is True
    network_observed = observations["network_boundary"]
    logs_observed = observations["default_logs"]
    model_operation = observations["model_operation_boundary"]
    require(isinstance(network_observed, dict) and isinstance(network_observed.get("supported", True), bool), "evidence: network_boundary observations are invalid")
    if network_observed.get("supported", True):
        require(all(is_measurement(network_observed.get(field)) for field in ("helper_socket_attempts", "daemon_network_requests")), "evidence: network_boundary observations are invalid")
    require(isinstance(logs_observed, dict) and isinstance(logs_observed.get("supported", True), bool) and all(isinstance(logs_observed.get(field), bool) for field in ("contains_pcm", "contains_transcript", "contains_operational_metadata")), "evidence: default_logs observations are invalid")
    require(isinstance(model_operation, dict) and isinstance(model_operation.get("supported", True), bool) and is_measurement(model_operation.get("artifact_requests")) and all(isinstance(model_operation.get(field), bool) for field in ("contains_pcm", "contains_transcript")), "evidence: model_operation_boundary observations are invalid")
    return [
        Check("privacy.offline_operation", "privacy", offline_passed, offline, {"supported": True, "no_credentials": True, "network_disabled": True, "ready_offline": True, "corpus_completed": True}),
        Check("privacy.network_boundary", "privacy", network_observed.get("supported", True) is True and network_observed.get("helper_socket_attempts") == 0 and network_observed.get("daemon_network_requests") == 0, network_observed, {"supported": True, "helper_socket_attempts": 0, "daemon_network_requests": 0}),
        Check("privacy.default_logs", "privacy", logs_observed.get("supported", True) is True and logs_observed.get("contains_pcm") is False and logs_observed.get("contains_transcript") is False and logs_observed.get("contains_operational_metadata") is True, logs_observed, {"supported": True, "contains_pcm": False, "contains_transcript": False, "contains_operational_metadata": True}),
        Check("privacy.model_operation_boundary", "privacy", model_operation.get("supported", True) is True and model_operation.get("artifact_requests", 0) > 0 and model_operation.get("contains_pcm") is False and model_operation.get("contains_transcript") is False, model_operation, {"supported": True, "artifact_requests_minimum": 1, "contains_pcm": False, "contains_transcript": False}),
    ]


def fault_checks(evidence: dict[str, Any], evidence_root: Path) -> list[Check]:
    probes = evidence.get("fault_probes")
    require(isinstance(probes, list), "evidence: fault_probes must be an array")
    assert isinstance(probes, list)
    indexed: dict[str, dict[str, Any]] = {}
    for probe in probes:
        require(isinstance(probe, dict) and probe.get("name") in REQUIRED_FAULT_ASSERTIONS, "evidence: invalid fault probe")
        assert isinstance(probe, dict) and isinstance(probe.get("name"), str)
        require(probe["name"] not in indexed, f"evidence: duplicate fault probe {probe['name']}")
        expected_digest = probe.get("trace_sha256")
        require(isinstance(expected_digest, str) and len(expected_digest) == 64 and all(c in "0123456789abcdef" for c in expected_digest), f"evidence: invalid trace digest for {probe['name']}")
        trace_path = resolve_artifact(evidence_root, probe.get("trace"), f"evidence: {probe['name']} fault trace")
        require(file_sha256(trace_path) == expected_digest, f"evidence: {probe['name']} fault trace digest does not match")
        trace = load_json(trace_path)
        require(trace.get("schema_version") == 1 and trace.get("scenario") == probe["name"], f"evidence: {probe['name']} fault trace identity is invalid")
        events = trace.get("events")
        assertions = trace.get("assertions")
        require(isinstance(events, list) and bool(events), f"evidence: {probe['name']} fault trace has no events")
        require(isinstance(assertions, list) and bool(assertions), f"evidence: {probe['name']} fault trace has no assertions")
        assert isinstance(assertions, list)
        require(all(isinstance(assertion, dict) and isinstance(assertion.get("id"), str) and isinstance(assertion.get("passed"), bool) for assertion in assertions), f"evidence: {probe['name']} fault trace assertions are invalid")
        assertion_results = {assertion["id"]: assertion["passed"] for assertion in assertions}
        require(len(assertion_results) == len(assertions), f"evidence: {probe['name']} fault trace has duplicate assertion ids")
        missing_assertions = sorted(set(REQUIRED_FAULT_ASSERTIONS[probe["name"]]) - assertion_results.keys())
        require(not missing_assertions, f"evidence: {probe['name']} fault trace is missing assertions {missing_assertions}")
        indexed[probe["name"]] = {
            "passed": all(assertion_results.values()),
            "trace_sha256": expected_digest,
        }
    missing = sorted(set(REQUIRED_FAULTS) - indexed.keys())
    failed = sorted(name for name in REQUIRED_FAULTS if name in indexed and indexed[name].get("passed") is not True)
    return [Check("lifecycle.deterministic_fault_matrix", "lifecycle", not missing and not failed, {"missing": missing, "failed": failed, "trace_sha256": hashlib.sha256("".join(indexed[name]["trace_sha256"] for name in sorted(indexed)).encode()).hexdigest()}, {"required_probes": list(REQUIRED_FAULTS), "all_passed": True})]


def evaluate(manifest: dict[str, Any], evidence: dict[str, Any], manifest_root: Path, evidence_root: Path) -> dict[str, Any]:
    require(evidence.get("schema_version") == 1, "evidence: unsupported schema_version")
    fixtures = validate_manifest(manifest, manifest_root)
    quality, details = quality_checks(fixtures, evidence)
    candidate = evidence.get("candidate")
    candidate_check = Check("candidate.pinned_design", "candidate", candidate == PINNED_CANDIDATE, candidate, PINNED_CANDIDATE)
    checks = [candidate_check, packaged_identity_check(evidence), corpus_check(fixtures)] + quality + performance_checks(details, evidence) + privacy_checks(evidence, evidence_root) + fault_checks(evidence, evidence_root)
    report_checks = [asdict(check) for check in checks]
    canonical_manifest = json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return {
        "schema_version": 1,
        "corpus": {
            "id": manifest["corpus"]["id"],
            "manifest_sha256": hashlib.sha256(canonical_manifest).hexdigest(),
        },
        "candidate": evidence.get("candidate"),
        "verdict": "pass" if all(check.passed for check in checks) else "fail",
        "checks": report_checks,
        "utterances": details,
    }


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    args = parse_args(arguments)
    try:
        report = evaluate(load_json(args.manifest), load_json(args.evidence), args.manifest.parent, args.evidence.parent)
        rendered = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        args.report.write_text(rendered, encoding="utf-8")
    except ContractError as error:
        print(f"release-gate contract error: {error}", file=sys.stderr)
        return 2
    failed = [check["id"] for check in report["checks"] if not check["passed"]]
    print(json.dumps({"failed_checks": failed, "verdict": report["verdict"]}, sort_keys=True))
    return 0 if report["verdict"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
