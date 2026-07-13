import pytest
from run_bench import FIXED_PAYLOAD, VAR_PAYLOAD, MODE_NAME, PAIR_NAME, run_bench_pair

NUM_MESSAGES = 2_000_000

CASES = [
    (mode, pair, n_prod, n_cons, f"{MODE_NAME[mode]}  pair :: {PAIR_NAME[pair]}")
    for mname, mode, n_prod, n_cons in [
        ("SPSC", 0, 1, 1), ("SPMC", 1, 1, 3), ("MPSC", 2, 3, 1), ("MPMC", 3, 2, 2)
    ]
    for pair in range(5)
]


@pytest.mark.parametrize("mode,pair,n_prod,n_cons,label", CASES, ids=[c[4] for c in CASES])
def test_queue_pair(mode, pair, n_prod, n_cons, label):
    payload = VAR_PAYLOAD if pair in (2, 4) else FIXED_PAYLOAD
    prod_r, cons_r = run_bench_pair(mode, pair, n_prod, n_cons,
                                     num_messages=NUM_MESSAGES, payload_size=payload)

    print()
    for i, r in enumerate(prod_r):
        print(f"  producer[{i}]: {r['sent']} msgs  {r['mps']/1e6:.2f} M/s  "
              f"{r['gbps']:.3f} GB/s   Total: {r['bytes']/1048576:.3f} MB")
    for i, r in enumerate(cons_r):
        print(f"  consumer[{i}]: {r['received']} msgs  {r['mps']/1e6:.2f} M/s  "
              f"{r['gbps']:.3f} GB/s   Total: {r['bytes']/1048576:.3f} MB")

    total_sent = sum(r["sent"] for r in prod_r)
    assert total_sent > 0, f"{label}: producer(s) sent nothing"
    for i, r in enumerate(cons_r):
        assert r.get("corrupt", 0) == 0, f"{label}: consumer[{i}] saw {r['corrupt']} corrupted/misdelivered messages"
 
    if mode in (1, 3):  # SPMC / MPMC
        for i, r in enumerate(cons_r):
            assert r["received"] == total_sent, f"{label}: consumer[{i}] got {r['received']} != {total_sent}"
    else:  # SPSC / MPSC
        assert cons_r[0]["received"] == total_sent, f"{label}: consumer got {cons_r[0]['received']} != {total_sent}"