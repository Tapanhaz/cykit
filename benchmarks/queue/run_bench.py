"""
All benchmarks use a fixed 64-byte payload and 2,000,000 messages.
"""

import re
import subprocess
import sys
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
RESULTS_DIR = HERE / "results"
CHART_PATH = RESULTS_DIR / "latest.png"

sys.path.insert(0, str(HERE.parent))
from _readme_utils import update_table, render_queue_table  # noqa: E402

BENCHES = [
    ("cykit.queue (Cython API)", "bench_queue_cython.py"),
    ("cykit.queue (Python API)", "bench_queue_pyapi.py"),
    ("queue.SimpleQueue", "stdlib_simplequeue.py"),
    ("collections.deque", "stdlib_deque.py"),
    ("queue.Queue", "stdlib_queue.py"),
]

METRIC_RE = re.compile(r"^(Throughput|Bandwidth|Avg Latency)\s*:\s*([\d,.]+)")


def run_one(label, script):
    print(f"\n>>> Running {label} ...", flush=True)
    proc = subprocess.run(
        [sys.executable, str(HERE / script)],
        capture_output=True,
        text=True,
    )
    print(proc.stdout)

    if proc.returncode != 0:
        print(f"!! {label} failed (exit {proc.returncode})", file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        return None

    metrics = {}
    for line in proc.stdout.splitlines():
        m = METRIC_RE.match(line.strip())
        if m:
            metrics[m.group(1)] = float(m.group(2).replace(",", ""))
    return metrics


def draw_chart(rows):
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print(
            "\n(matplotlib not installed -- skipping chart, `pip install matplotlib` to enable it)"
        )
        return

    labels = [label for label, _ in rows]
    throughput = [m.get("Throughput", 0.0) for _, m in rows]
    bandwidth = [m.get("Bandwidth", 0.0) for _, m in rows]
    latency = [m.get("Avg Latency", 0.0) for _, m in rows]

    fig, axes = plt.subplots(1, 2, figsize=(13, 5.5))

    ax = axes[0]
    bars = ax.bar(labels, throughput, color="#4C72B0")
    ax.set_title("Throughput")
    ax.set_ylabel("messages / sec")
    for bar, mps, mib in zip(bars, throughput, bandwidth):
        ax.annotate(
            f"{mps:,.0f} msg/s\n({mib:,.1f} MiB/s)",
            (bar.get_x() + bar.get_width() / 2, bar.get_height()),
            ha="center",
            va="bottom",
            fontsize=7,
        )

    ax = axes[1]
    bars = ax.bar(labels, latency, color="#C44E52")
    ax.set_title("Avg Latency (lower is better)")
    ax.set_ylabel("microseconds / msg")
    for bar, val in zip(bars, latency):
        ax.annotate(
            f"{val:,.2f}",
            (bar.get_x() + bar.get_width() / 2, bar.get_height()),
            ha="center",
            va="bottom",
            fontsize=7,
        )

    for ax in axes:
        ax.tick_params(axis="x", rotation=30, labelsize=8)
        for tick in ax.get_xticklabels():
            tick.set_ha("right")

    fig.suptitle("cykit queue benchmark — 2,000,000 msgs x 64 bytes")
    fig.tight_layout()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    fig.savefig(CHART_PATH, dpi=150)
    print(f"\nChart written to {CHART_PATH}")


def main():
    rows = []
    for label, script in BENCHES:
        metrics = run_one(label, script)
        if metrics:
            rows.append((label, metrics))

    print("\n" + "=" * 80)
    print(f"{'Implementation':<32} {'msg/sec':>14} {'MiB/sec':>12} {'us/msg':>10}")
    print("=" * 80)
    for label, m in rows:
        print(
            f"{label:<32} "
            f"{m.get('Throughput', 0):>14,.0f} "
            f"{m.get('Bandwidth', 0):>12.2f} "
            f"{m.get('Avg Latency', 0):>10.3f}"
        )

    draw_chart(rows)

    table_rows = [
        (
            label,
            m.get("Throughput", 0.0),
            m.get("Bandwidth", 0.0),
            m.get("Avg Latency", 0.0),
        )
        for label, m in rows
    ]
    update_table("QUEUE", render_queue_table(table_rows))


if __name__ == "__main__":
    main()
