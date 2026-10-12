#!/usr/bin/env python3
"""Record and compare the actual build inputs before and after packaging."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def inputs(profile="full"):
    files = [ROOT / "Package.swift"]
    for name in ("Sources", "Tests", "scripts", "Resources"):
        files.extend(p for p in (ROOT / name).rglob("*") if p.is_file()
                     and not any(part.startswith("._") for part in p.relative_to(ROOT).parts)
                     and (name == "Resources" or p.suffix in (".swift", ".c", ".m", ".mm", ".h", ".modulemap", ".py", ".sh")))
    manifests = ["Vendor/manifest.json", "Vendor/tools/manifest.json"]
    if profile == "full":
        manifests.extend(("Vendor/WebTools/manifest.json",
        "Vendor/LiveASR/manifest.json", "Vendor/LiveASRModel/model-manifest.json",
        "scripts/live_asr_verification/input-pins.json",
        ))
    files.extend(ROOT / name for name in manifests)
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(files))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("before", "verify"))
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--profile", choices=("full", "core"), default="full")
    args = parser.parse_args()
    current = inputs(args.profile)
    if args.phase == "before":
        record = {"startedUTC": datetime.now(timezone.utc).isoformat(), "inputFiles": current}
        if args.profile == "core":
            record["buildProfile"] = "core"
        args.snapshot.write_text(json.dumps(record, indent=2) + "\n")
        return
    before = json.loads(args.snapshot.read_text())
    if before.get("buildProfile", "full") != args.profile:
        raise SystemExit("Build profile changed; packaging aborted.")
    if before["inputFiles"] != current:
        changed = sorted(name for name in set(before["inputFiles"]) | set(current)
                         if before["inputFiles"].get(name) != current.get(name))
        raise SystemExit("Build inputs changed; packaging aborted: " + ", ".join(changed))
    if args.bundle is None:
        raise SystemExit("verify requires --bundle")
    before.update(finishedUTC=datetime.now(timezone.utc).isoformat(), inputFilesUnchanged=True,
                  scope="Source/resources/test contracts/dependency manifests including LiveASR package pins and model manifest; payloads are separately verified by their bootstrap/build manifests")
    if args.profile == "core":
        before.update(scope="All source/resources/test contracts and core playback/media-tools dependency manifests; Live ASR and WebTools payloads are not packaged or accepted by this build",
                      omittedBundleComponents=["offlineSpeechRecognition", "liveSpeechRecognition", "webMediaExtractor"])
    target = args.bundle / "Contents/Resources/build-provenance.json"
    target.write_text(json.dumps(before, indent=2) + "\n")
    print("Build inputs unchanged:", len(current))


if __name__ == "__main__":
    main()
