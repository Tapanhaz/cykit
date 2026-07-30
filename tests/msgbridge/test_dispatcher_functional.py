import pytest
from dispatcher_bench import run_sync_dispatcher_bench, run_async_dispatcher_bench

NUM_MESSAGES_SYNC = 200_000
NUM_MESSAGES_ASYNC = 20_0000

SYNC_CASES = [
    (variable_size, nonblocking, f"variable={variable_size} nonblocking={nonblocking}")
    for variable_size in (False, True)
    for nonblocking in (True, False)
]


@pytest.mark.parametrize(
    "variable_size,nonblocking,label", SYNC_CASES, ids=[c[2] for c in SYNC_CASES]
)
def test_sync_dispatcher(variable_size, nonblocking, label):
    r = run_sync_dispatcher_bench(
        num_messages=NUM_MESSAGES_SYNC,
        payload_size=128 if variable_size else 64,
        variable_size=variable_size,
        nonblocking=nonblocking,
    )

    print(
        f"\n  {label}: sent={r['sent']} msgs  received={r['received']} msgs  "
        f"corrupt={r['corrupt']}  elapsed={r['elapsed_ns']/1e9:.3f}s  "
        f"Total: {r['bytes']/1048576:.3f} MB"
    )

    assert not r["timed_out"], f"{label}: consumer never caught up"
    assert r["sent"] == NUM_MESSAGES_SYNC, f"{label}: producer sent {r['sent']}"
    assert r["corrupt"] == 0, f"{label}: {r['corrupt']} corrupted/misdelivered messages"
    assert (
        r["received"] == r["sent"]
    ), f"{label}: {r['sent'] - r['received']} messages lost"
    assert r["unique_seqs"] == r["sent"], f"{label}: duplicate deliveries detected"


@pytest.mark.parametrize("variable_size", [False, True], ids=["fixed", "variable"])
def test_async_dispatcher(variable_size):
    r = run_async_dispatcher_bench(
        num_messages=NUM_MESSAGES_ASYNC,
        payload_size=128 if variable_size else 64,
        variable_size=variable_size,
    )

    print(
        f"\n  async variable={variable_size}: sent={r['sent']} msgs  "
        f"received={r['received']} msgs  corrupt={r['corrupt']}  "
        f"elapsed={r['elapsed_ns']/1e9:.3f}s  "
        f"Total: {r['bytes']/1048576:.3f} MB"
    )

    assert not r["timed_out"], "consumer never caught up"
    assert r["sent"] == NUM_MESSAGES_ASYNC, f"producer sent {r['sent']}"
    assert r["corrupt"] == 0, f"{r['corrupt']} corrupted/misdelivered messages"
    assert r["received"] == r["sent"], f"{r['sent'] - r['received']} messages lost"
