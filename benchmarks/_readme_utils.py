"""
Helper for regenerating a benchmark results table in README.md
"""

import re
import pathlib

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
README_PATH = PROJECT_ROOT / "README.md"


def _marker_pattern(marker):
    start = re.escape(f"<!-- BENCH:{marker}:START -->")
    end = re.escape(f"<!-- BENCH:{marker}:END -->")
    return re.compile(f"({start})(.*?)({end})", re.DOTALL)


def update_table(marker, table_markdown, readme_path=README_PATH):
    text = readme_path.read_text(encoding="utf-8")
    pattern = _marker_pattern(marker)

    if not pattern.search(text):
        print(
            f"WARNING: BENCH:{marker} markers not found in {readme_path} -- README not updated"
        )
        return

    new_text = pattern.sub(
        lambda m: f"{m.group(1)}\n{table_markdown}\n{m.group(3)}", text, count=1
    )
    readme_path.write_text(new_text, encoding="utf-8")
    print(f"README.md updated ({marker} table)")


def render_ipc_table(rows):
    rows = sorted(rows, key=lambda r: r[1], reverse=True)
    lines = [
        "| Implementation | msg/sec | MiB/sec | us/msg |",
        "|---------------|--------:|--------:|-------:|",
    ]
    for label, mps, mib, us in rows:
        is_cykit = label.lower().startswith("cykit")
        name = f"**{label}**" if is_cykit else label
        cells = [name, f"{mps:,.0f}", f"{mib:.2f}", f"{us:.3f}"]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def render_queue_table(rows):
    rows = sorted(rows, key=lambda r: r[1], reverse=True)
    lines = [
        "| Implementation | Throughput | Bandwidth | Avg. Latency |",
        "| :------------- | ---------: | --------: | -----------: |",
    ]
    for label, mps, mib, us in rows:
        is_cykit = label.lower().startswith("cykit")
        name = f"**{label}**" if is_cykit else f"`{label}`"
        cells = [
            name,
            f"{mps / 1e6:.2f} M msg/s",
            f"{mib:.2f} MiB/s",
            f"{us:.3f} \u03bcs",
        ]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)
