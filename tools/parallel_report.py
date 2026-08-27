#!/usr/bin/env python3
"""Render the concurrency sweep's record as markdown.

Generated rather than hand-written for one reason: every number in the writeup
is then the number in the record, and a transcription slip cannot happen. The
prose around it is written by hand; the tables and the verdicts are not.

The verdict logic is the part that matters. The measured noise floor on this
machine is around 13% peak-to-peak, and several arms differ by less than that.
Where a comparison falls inside the combined spread of its two arms, this says
"inconclusive" rather than naming a winner -- a difference smaller than the
measurement cannot be reported as a difference.

Usage:
  parallel_report.py bench/parallel-scaling.tsv
"""
import csv
import sys


def load(path):
    with open(path) as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def f(row, key):
    v = row.get(key, "")
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def verdict(a, b, key="aggregate_tps", spread_key="aggregate_spread_pct"):
    """Compare two arms, refusing to call a difference the spread cannot resolve."""
    fa, fb = f(a, key), f(b, key)
    if fa is None or fb is None or fa <= 0 or fb <= 0:
        return "no data", 0.0
    mean = (fa + fb) / 2
    gap = 100.0 * (fa - fb) / mean
    band = ((f(a, spread_key) or 0.0) + (f(b, spread_key) or 0.0)) / 2
    if abs(gap) < band:
        return "inconclusive", gap
    return ("MTP faster" if gap > 0 else "MTP slower"), gap


def scaling_table(rows):
    main = [r for r in rows if r["group"] == "main" and r["spec_type"] == "draft-mtp"]
    main.sort(key=lambda r: int(r["slots"]))
    if not main:
        return ""
    base = f(main[0], "aggregate_tps") or 1.0
    out = ["| slots | per-slot ctx | per-stream tok/s | aggregate tok/s | vs 1 slot | draft accept |",
           "| ---: | ---: | ---: | ---: | ---: | ---: |"]
    for r in main:
        agg = f(r, "aggregate_tps") or 0.0
        out.append(
            f"| {r['slots']} | {int(r['ctx_per_slot']):,} | "
            f"{r['per_stream_tps']} ±{r['per_stream_spread_pct']}% | "
            f"{r['aggregate_tps']} ±{r['aggregate_spread_pct']}% | "
            f"{agg / base:.2f}x | {r['draft_accept_pct'] or '—'}% |")
    return "\n".join(out)


def mtp_table(rows):
    pairs = {}
    for r in rows:
        if r["group"] not in ("main", "prose"):
            continue
        k = (r["group"], int(r["slots"]), r["workload"])
        pairs.setdefault(k, {})[r["spec_type"]] = r
    # The column headers say "with MTP" / "without", not "MTP on/off": on this
    # engine --spec-type none still loads ngram-mod, so the comparison arm is
    # the default speculative stack rather than no speculation at all.
    out = ["| workload | slots | with MTP | without | difference | verdict | accept | stack (with / without) |",
           "| --- | ---: | ---: | ---: | ---: | --- | ---: | --- |"]
    for k in sorted(pairs, key=lambda k: (k[2], k[1])):
        v = pairs[k]
        if set(v) != {"draft-mtp", "none"}:
            continue
        on, off = v["draft-mtp"], v["none"]
        verd, gap = verdict(on, off)
        out.append(
            f"| {k[2]} | {k[1]} | {on['aggregate_tps']} ±{on['aggregate_spread_pct']}% | "
            f"{off['aggregate_tps']} ±{off['aggregate_spread_pct']}% | "
            f"{gap:+.1f}% | {verd} | {on['draft_accept_pct'] or '—'}% | "
            f"`{on.get('spec_impls','?')}` / `{off.get('spec_impls','?')}` |")
    return "\n".join(out)


def controls(rows):
    by = {r["label"]: r for r in rows}
    out = []
    a, b = by.get("np1-mtp"), by.get("np1-cache8192")
    if a and b:
        verd, gap = verdict(a, b)
        out.append(
            f"- **Prompt cache 16384 vs 8192 MiB**, one slot, everything else equal: "
            f"{a['aggregate_tps']} against {b['aggregate_tps']} tok/s aggregate "
            f"({gap:+.1f}%, {verd}).")
    a, b = by.get("np1-mtp"), by.get("np1-win32k-mtp")
    if a and b:
        verd, gap = verdict(a, b)
        out.append(
            f"- **Per-slot window 262144 vs 32768**, one slot, everything else equal: "
            f"{a['aggregate_tps']} against {b['aggregate_tps']} tok/s aggregate "
            f"({gap:+.1f}%, {verd}). This bounds how much the shrinking window "
            f"confounds the slot sweep.")
    return "\n".join(out)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = load(sys.argv[1])
    if not rows:
        sys.exit("no rows in the record")
    print("## How throughput scales with slots\n")
    print(scaling_table(rows))
    print("\n## Does MTP still pay?\n")
    print(mtp_table(rows))
    print("\n## Controls\n")
    print(controls(rows))


if __name__ == "__main__":
    main()
