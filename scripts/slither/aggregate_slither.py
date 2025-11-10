#!/usr/bin/env python3
"""
aggregate_slither.py (enhanced)

Reads slither JSON outputs from reports/json/*.json and creates:
- reports/summary.md : summary + detailed markdown table of findings

Usage:
  python3 scripts/aggregate_slither.py
"""

import json
import glob
from pathlib import Path
from collections import Counter, defaultdict

ROOT = Path(__file__).resolve().parents[2]
JSON_DIR = ROOT / "reports" / "json"
OUT_MD = ROOT / "reports" / "summary.md"

# map common check names to recommended actions (best-effort)
RECOMMENDATIONS = {
    "assembly": "Review inline assembly for correctness and bounds; add unit tests and comments. Replace with Solidity if feasible.",
    "boolean-equal": "Simplify boolean comparisons (e.g., use `if (flag)` instead of `if (flag == true)`) for clarity.",
    "naming-convention": "Rename to follow project/solidity naming conventions (mixedCase for vars/functions).",
    "unused-return": "Handle the return value or explicitly ignore it with a comment `// intentionally ignore`.",
    "solc-version": "Pin to a patched stable Solidity compiler version; avoid `^` ranges for critical contracts.",
    "pragma": "Standardize pragma versions across the repo; use a single pinned compiler in CI.",
    "dead-code": "Remove unused code or justify keeping it with a comment; reduces maintenance burden.",
    "shadowing-local": "Avoid variable shadowing by renaming local or state variables; improves clarity.",
    "reentrancy-events": "Ensure checks-effects-interactions; consider ReentrancyGuard and audit event ordering.",
    "reentrancy-no-eth": "Even without ETH transfers, guard against reentrancy: checks-effects-interactions and/or ReentrancyGuard.",
    "timestamp": "Avoid critical reliance on block.timestamp; document tolerances or use block.number/oracle where appropriate.",
    "uninitialized-local": "Initialize local variables explicitly to avoid logic errors.",
    "unused-local": "Remove or use the local variable; if intentionally unused, comment accordingly.",
    # fallback
    "default": "Review this finding and apply appropriate fix (test, refactor, or add checks)."
}

def load_json_files(json_dir):
    for p in sorted(json_dir.glob("*.json")):
        try:
            with p.open() as f:
                yield p.name, json.load(f)
        except Exception as e:
            print(f"Skipping {p}: {e}")

def find_detectors(data):
    """
    Return list of detector dicts, trying several known locations used by Slither JSON:
      - data['results']['detectors']
      - data['results']['printers'][*]['additional_fields']['detectors']
      - top-level 'detectors'
    """
    if not data:
        return []
    results = data.get("results") or {}
    det = results.get("detectors")
    if det:
        return det
    # fallback: printers -> additional_fields.detectors
    printers = results.get("printers") or []
    for p in printers:
        af = p.get("additional_fields") or {}
        det2 = af.get("detectors")
        if det2:
            return det2
    # older/alternate location
    top = data.get("detectors")
    if top:
        return top
    return []

def extract_location(elem):
    """
    Try to extract filename and line(s) from an 'element' entry.
    Slither element variants: may have filename, start_line/end_line, line, lines, source_mapping
    """
    if not elem:
        return ("", "")
    # common keys
    filename = elem.get("filename") or elem.get("path") or elem.get("source_mapping", {}).get("filename", "")
    # lines: try multiple patterns
    if "line" in elem:
        lines = f"L{elem.get('line')}"
    elif "start_line" in elem and "end_line" in elem:
        lines = f"L{elem.get('start_line')}-L{elem.get('end_line')}"
    elif "lines" in elem and isinstance(elem.get("lines"), list):
        lines = ",".join(str(x) for x in elem.get("lines"))
    else:
        # sometimes in source_mapping
        sm = elem.get("source_mapping") or {}
        if "start_line" in sm and "end_line" in sm:
            lines = f"L{sm.get('start_line')}-L{sm.get('end_line')}"
        else:
            lines = ""
    return (filename, lines)

def normalize_check_name(name):
    if not name:
        return "unknown"
    return name.strip()

def recommend_for(check):
    key = check.lower()
    # simple match by token
    for token, rec in RECOMMENDATIONS.items():
        if token in key:
            return rec
    return RECOMMENDATIONS["default"]

def summarise_and_build_table(all_files):
    total = 0
    by_check = Counter()
    by_severity = Counter()
    per_file = defaultdict(list)
    table_rows = []

    for fname, data in all_files:
        detectors = find_detectors(data)
        for d in detectors:
            total += 1
            # extract fields
            check = d.get("check") or d.get("name") or d.get("title") or d.get("detector") or "unknown"
            check = normalize_check_name(check)
            severity = d.get("severity") or d.get("impact") or "unknown"
            description = d.get("description") or d.get("info") or d.get("message") or ""
            confidence = d.get("confidence") or d.get("confidence_level") or ""
            # elements: try to pick a primary element for file/line
            file_field = ""
            lines_field = ""
            elements = d.get("elements") or d.get("elements", []) or d.get("locations") or []
            if elements and isinstance(elements, list) and len(elements) > 0:
                # pick first element that contains a filename
                chosen = None
                for e in elements:
                    fname_e, lines_e = extract_location(e)
                    if fname_e:
                        chosen = e
                        file_field, lines_field = fname_e, lines_e
                        break
                if not chosen:
                    # fallback to first element
                    file_field, lines_field = extract_location(elements[0])
            else:
                # sometimes detectors have 'filename' directly
                file_field = d.get("filename") or d.get("file")
                lines_field = d.get("line") or ""
            # short description: first line
            short_desc = description.strip().splitlines()[0] if description else ""
            rec_action = recommend_for(check)
            # append aggregated counters and table rows
            by_check[check] += 1
            by_severity[severity] += 1
            per_file[fname].append(d)
            table_rows.append({
                "check": check,
                "severity": severity,
                "file": file_field or fname,
                "lines": lines_field or "",
                "short": short_desc,
                "recommendation": rec_action
            })

    return total, by_check, by_severity, per_file, table_rows

def write_markdown(total, by_check, by_severity, per_file, table_rows, out_path):
    lines = []
    lines.append("# Slither aggregated report\n")
    lines.append(f"- Generated from JSON files in `reports/json/`\n")
    lines.append(f"- Total findings: **{total}**\n")
    lines.append("\n## Findings by severity\n")
    if by_severity:
        for sev, cnt in by_severity.most_common():
            lines.append(f"- **{sev}**: {cnt}")
    else:
        lines.append("- none\n")

    lines.append("\n## Top checks\n")
    if by_check:
        for chk, cnt in by_check.most_common(30):
            lines.append(f"- {chk}: {cnt}")
    else:
        lines.append("- none")

    lines.append("\n---\n")
    lines.append("\n## Detailed findings table\n")
    lines.append("\n(Columns: #, Check, Severity, File, Lines, Short description, Recommended action)\n")
    # header
    lines.append("\n| # | Check | Severity | File | Lines | Short description | Recommended action |")
    lines.append("|---:|---|---|---|---|---|---|")

    # sort rows by severity (High, Medium, Low, Informational, unknown) then check name
    severity_order = {"High": 0, "Critical": 0, "Medium": 1, "Low": 2, "Informational": 3, "Unknown": 4, "unknown": 4}
    def sev_key(r):
        return (severity_order.get(r["severity"], 5), r["check"].lower())
    table_rows_sorted = sorted(table_rows, key=sev_key)

    for i, r in enumerate(table_rows_sorted, start=1):
        file_cell = r["file"] if r["file"] else ""
        # escape pipe in text
        short = r["short"].replace("|", "\\|")
        rec = r["recommendation"].replace("|", "\\|")
        lines.append(f"| {i} | {r['check']} | {r['severity']} | {file_cell} | {r['lines']} | {short} | {rec} |")

    # small per-file summary
    lines.append("\n---\n\n## Per-file findings (count)\n")
    for fname, dets in per_file.items():
        lines.append(f"- **{fname}** — {len(dets)} findings")

    out_path.write_text("\n".join(lines))
    print(f"Wrote summary to {out_path}")

def main():
    files = list(load_json_files(JSON_DIR))
    print(JSON_DIR)
    if not files:
        print("No JSON files found in", JSON_DIR)
        return
    total, by_check, by_severity, per_file, table_rows = summarise_and_build_table(files)
    write_markdown(total, by_check, by_severity, per_file, table_rows, OUT_MD)

if __name__ == "__main__":
    main()
