# test_cylogger_handlers.py
import re

LEVELS = ["trace", "debug", "info", "warning", "error", "critical"]
MESSAGES = {
    "trace": "Trace: cylogger test",
    "debug": "Debug: sending data",
    "info": "Info: regular log",
    "warning": "Warning: something",
    "error": "Error: occurred",
    "critical": "Critical: shutdown",
}
CONSOLE_RE = re.compile(
    r"\[test\] \[(trace|debug|info|warning|error|critical)\] (.+)"
)


def console_lines(stdout):
    return [
        (m.group(1), m.group(2).strip())
        for m in CONSOLE_RE.finditer(stdout)
    ]


def test_01_console_receives_all_levels(run_logger):
    lines = console_lines(run_logger["stdout"])
    assert [lvl for lvl, _ in lines] == LEVELS
    for lvl, msg in lines:
        assert msg == MESSAGES[lvl]


def test_02_udp_receives_all_six(run_logger):
    msgs = sorted(run_logger["udp"].messages, key=lambda m: m["received_at"])
    assert len(msgs) == 6
    for lvl, m in zip(LEVELS, msgs):
        text = m["data"].decode("utf-8", errors="replace")
        assert f"[{lvl}]" in text
        assert MESSAGES[lvl] in text


def test_03_tcp_default_level_all_six(run_logger):
    assert len(run_logger["tcp"].messages) == 6


def test_04_http_receives_all_six_correct_format(run_logger):
    reqs = sorted(run_logger["http"].requests, key=lambda r: r["received_at"])
    assert len(reqs) == 6
    for lvl, r in zip(LEVELS, reqs):
        assert r["headers"].get("Content-Type") == "text/plain"
        assert r["path"].endswith("/logs")
        assert f"[{lvl}]" in r["body"]
        assert MESSAGES[lvl] in r["body"]


def test_05_smtp_filters_to_error_and_above(run_logger):
    emails = sorted(run_logger["smtp"].emails, key=lambda e: e["connected_at"])
    assert len(emails) == 2
    assert MESSAGES["error"] in emails[0]["body"]
    assert MESSAGES["critical"] in emails[1]["body"]


def test_06_message_content_matches_pattern(run_logger):
    pattern = re.compile(
        r"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[(trace|debug|info|warning|error|critical)\] .+$"
    )
    for r in run_logger["http"].requests:
        assert pattern.match(r["body"].strip())
    for m in run_logger["udp"].messages:
        text = m["data"].decode("utf-8", errors="replace").strip()
        assert pattern.match(text)
    for e in run_logger["smtp"].emails:
        assert pattern.match(e["body"].strip())


def test_07_ordering_preserved_across_transports(run_logger):
    udp = sorted(run_logger["udp"].messages, key=lambda m: m["received_at"])
    assert [
        next(lvl for lvl in LEVELS if f"[{lvl}]" in m["data"].decode())
        for m in udp
    ] == LEVELS

    http = sorted(run_logger["http"].requests, key=lambda r: r["received_at"])
    assert [
        next(lvl for lvl in LEVELS if f"[{lvl}]" in r["body"])
        for r in http
    ] == LEVELS

    smtp = sorted(run_logger["smtp"].emails, key=lambda e: e["connected_at"])
    assert MESSAGES["error"] in smtp[0]["body"]
    assert MESSAGES["critical"] in smtp[1]["body"]


def test_08_tcp_reconnects_each_message(run_logger):
    ports = [m["client_port"] for m in run_logger["tcp"].messages]
    assert len(ports) == len(set(ports)) == 6


def test_10_smtp_envelope_correct(run_logger):
    for e in run_logger["smtp"].emails:
        assert e["envelope_from"] == "<logger@test.local>"
        assert e["envelope_to"] == "<admin@test.local>"
        assert "Subject: Log Alert from cylogger" in e["headers"]


def test_11_smtp_never_receives_below_error(run_logger):
    forbidden = [MESSAGES[l] for l in ("trace", "debug", "info", "warning")]
    for e in run_logger["smtp"].emails:
        for text in forbidden:
            assert text not in e["body"]


def test_12_internal_diag_counts_match_delivery_counts(run_logger):
    stdout = run_logger["stdout"]
    http_diag = len(re.findall(r"cylogger_internal.*HTTP status=200", stdout))
    smtp_diag = len(re.findall(r"cylogger_internal.*SMTP ok=1", stdout))
    assert http_diag == len(run_logger["http"].requests)
    assert smtp_diag == len(run_logger["smtp"].emails)


def test_14_run_exits_cleanly(run_logger):
    assert run_logger["returncode"] == 0


def test_15_no_duplicate_deliveries(run_logger):
    udp_bodies = [m["data"] for m in run_logger["udp"].messages]
    tcp_bodies = [m["data"] for m in run_logger["tcp"].messages]
    http_bodies = [r["body"] for r in run_logger["http"].requests]
    smtp_bodies = [e["body"] for e in run_logger["smtp"].emails]

    assert len(udp_bodies) == len(set(udp_bodies))
    assert len(tcp_bodies) == len(set(tcp_bodies))
    assert len(http_bodies) == len(set(http_bodies))
    assert len(smtp_bodies) == len(set(smtp_bodies))