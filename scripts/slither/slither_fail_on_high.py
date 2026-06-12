#!/usr/bin/env python3
# scripts/slither_fail_on_high.py
import json
import glob
import sys
from pathlib import Path

def extract_detectors(d):
    dets = (d.get("results") or {}).get("detectors") or d.get("detectors") or []
    if dets:
        return dets
    printers = (d.get("results") or {}).get("printers") or []
    for pr in printers:
        af = pr.get("additional_fields") or {}
        dets = af.get("detectors") or dets
    return dets or []

reports_dir = Path("reports/json")
if not reports_dir.exists():
    print("No reports/json directory. Skipping Slither check.")
    sys.exit(0)

fail = False
for p in sorted(glob.glob("reports/json/*.json")):
    try:
        with open(p, "r") as fh:
            d = json.load(fh)
    except Exception as e:
        print("Warning: failed to parse", p, e)
        continue
    dets = extract_detectors(d)
    for x in dets:
        sev = (x.get("severity") or x.get("impact") or "").strip().lower()
        conf_raw = x.get("confidence") or x.get("confidence_level") or x.get("confidenceString") or ""
        conf = str(conf_raw).strip().lower()
        if sev == "high" and conf == "high":
            print("High severity + High confidence found in", p, "->", (x.get("check") or x.get("name") or x.get("title") or "unknown"))
            fail = True

if fail:
    print("\nFailing CI because Slither found High severity + High confidence issues.")
    sys.exit(1)

print("No High severity Slither findings.")
sys.exit(0)
