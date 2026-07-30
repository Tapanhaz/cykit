import json
import sys

from run_ipc_bench import run_ipc_pair

if __name__ == "__main__":
    mode, pair, n_prod, n_cons = (
        int(sys.argv[1]),
        int(sys.argv[2]),
        int(sys.argv[3]),
        int(sys.argv[4]),
    )
    tag = sys.argv[5]
    num_messages = int(sys.argv[6]) if len(sys.argv) > 6 else 2_000_000
    payload_size = int(sys.argv[7]) if len(sys.argv) > 7 else None

    prod_r, cons_r = run_ipc_pair(
        mode,
        pair,
        n_prod,
        n_cons,
        num_messages=num_messages,
        tag=tag,
        payload_size=payload_size,
        timeout=170,
    )
    print("PAIR_RESULT_JSON:" + json.dumps({"prod": prod_r, "cons": cons_r}))
