#!/usr/bin/env python3
"""Development-only experimental bank builder; needs numpy and a ModelTrace checkout.

Samples remain local. Input: MenuGauge *-samples.json arrays or numeric enrollment JSONL.
Use the ModelTrace commit recorded in THIRD_PARTY_NOTICES.txt.
"""
import argparse
import importlib
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MODELS = ("gpt-6.1-sol", "gpt-6.1-terra")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modeltrace-dir", type=Path, required=True)
    parser.add_argument("--samples", type=Path, nargs="+", required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.modeltrace_dir.resolve()))
    builder = importlib.import_module("bank_builder")
    fingerprint = importlib.import_module("fingerprint")
    challenges = {x["challenge_id"]: x for x in importlib.import_module("challenge_suite").fingerprint_suite()}
    training, validation, seen = [], [], set()
    for path in args.samples:
        content = path.read_text()
        records = json.loads(content) if content.lstrip().startswith("[") else [json.loads(x) for x in content.splitlines() if x.strip()]
        for record in records:
            model = record.get("model") or record.get("source")
            cid = record.get("challengeID") or record.get("challenge_id")
            kind = record.get("kind", "validation" if cid and cid.startswith("validation-") else "training")
            if model not in MODELS or kind not in ("training", "validation") or (model, kind, cid) in seen:
                raise ValueError("Invalid or duplicate enrollment sample")
            seen.add((model, kind, cid))
            task = challenges[cid] if kind == "training" else None
            numbers = record.get("numbers") or fingerprint.parse_numbers(record.get("text", ""))
            expected = task["expected_count"] if task else record["expected_count"]
            if any(type(n) is not int or not 1 <= n <= 355 for n in numbers) or len(numbers) < max(80, math.ceil(expected * .55)):
                raise ValueError("Incomplete numeric response")
            condition = task["condition"] if task else "independent-validation"
            row = {"source": model, "family_id": "gpt", "family_name": "GPT", "condition_id": condition,
                   "nuisance_condition_id": condition, "challenge_id": cid, "numbers": numbers,
                   "counts": fingerprint.count_numbers(numbers), "strict_valid": True, "text": json.dumps(numbers), "expected_count": expected}
            (training if task else validation).append(row)
    ready = [model for model in MODELS if sum(row["source"] == model for row in training) == 36]
    if not ready:
        raise ValueError("No new model has all 36 distinct reference challenges; samples remain pending")
    training = [row for row in training if row["source"] in ready]
    references = builder.read_rows(args.modeltrace_dir / "data/gpt_reference.jsonl") + builder.read_rows(args.modeltrace_dir / "data/claude_reference.jsonl")
    bank = builder.build_bank(references + training)
    if any(c["fallback"] for c in bank["calibration"].values()):
        raise ValueError("Cross-validation did not produce calibration parameters")
    profiles = []
    for model in ready:
        rows = sorted((r for r in validation if r["source"] == model), key=lambda r: r["challenge_id"])
        results = [fingerprint.analyze_global_outputs([{"text": r["text"], "expected_count": r["expected_count"]} for r in rows[start:start+3]], bank)["prediction"] for start in range(0, len(rows)-2, 3)]
        profiles.append({"model": model, "effort": "low", "experimental": True, "samples": 36, "validationCorrect": results.count(model), "validationTotal": len(results),
                         "source": f"Codex 订阅线路，openai 提供方，Low 推理。{len(rows)} 份独立回答，按每组三份验证。仅为统计参考，不能证明实际模型权重。"})
    resources = ROOT / "Sources/StatusRing/Resources"
    (resources / "model-fingerprints.json").write_text(json.dumps(bank, ensure_ascii=False, separators=(",", ":")))
    (resources / "fingerprint-profiles.json").write_text(json.dumps(profiles, ensure_ascii=False, indent=2) + "\n")
    (resources / "fingerprint-provenance.json").write_text(json.dumps({"modeltraceCommit": "6cd4a8ff0f3f4e49d6d6969dd2fbadfa1569fde2", "builtAt": bank["built_at"], "calibration": bank["calibration"], "profiles": profiles}, ensure_ascii=False, indent=2) + "\n")
    fixtures = []
    for model in ("gpt-6-astra", "gpt-6-sol", "gpt-6-luna") + MODELS:
        pool = validation if model in MODELS else references
        cases = [x for x in pool if x["source"] == model][:3]
        if len(cases) != 3:
            continue
        outputs = [{"text": json.dumps(r["numbers"]), "expected_count": 0} for r in cases]
        result = fingerprint.analyze_global_outputs(outputs, bank)
        fixtures.append({"outputs": [x["text"] for x in outputs], "prediction": result["prediction"], "probabilities": {r["model"]: r["probability"] for r in result["results"]}})
    (ROOT / "Tests/Fixtures/model-fingerprint-parity.json").write_text(json.dumps(fixtures, separators=(",", ":")))
    print(json.dumps({"models": len(bank["models"]), "profiles": profiles, "calibration": bank["calibration"]}, indent=2))


if __name__ == "__main__":
    main()
