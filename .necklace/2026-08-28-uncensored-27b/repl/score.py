import json, sys
sys.path.insert(0, sys.argv[1])
from corpus import CORPUS
which = sys.argv[2]           # q4 | q8
respdir = sys.argv[3]
rows = []
for c in CORPUS:
    resp = json.load(open(f"{respdir}/sum-{which}-{c['id']}.json"))
    summ = (resp.get("choices",[{}])[0].get("message",{}).get("content") or "")
    low = summ.lower()
    kept, missed = 0, []
    for fact in c["facts"]:
        if any(alt.lower() in low for alt in fact):
            kept += 1
        else:
            missed.append(fact[0])
    rows.append((c["id"], kept, len(c["facts"]), missed, len(summ)))
tot_k = sum(r[1] for r in rows); tot_n = sum(r[2] for r in rows)
print(f"=== {which.upper()} ===")
for cid, k, n, missed, L in rows:
    print(f"  {cid:16s} {k}/{n}  ({L} chars)" + (f"  MISSED: {', '.join(missed)}" if missed else ""))
print(f"  TOTAL {tot_k}/{tot_n} = {100*tot_k/tot_n:.1f}%")
