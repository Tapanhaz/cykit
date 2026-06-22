import pytest


def test_spsc_bench(queue_module):
    result = queue_module.SPSCBench(duration_s=0.3).run()
    assert result["ok"]
    assert result["total_received"] > 0


def test_spmc_bench(queue_module):
    result = queue_module.SPMCBench(duration_s=0.3).run()
    assert result["ok"]
    assert result["total_received"] > 0


def test_mpsc_bench(queue_module):
    result = queue_module.MPSCBench(duration_s=0.3).run()
    assert result["ok"]
    assert result["total_received"] > 0


def test_mpmc_bench(queue_module):
    result = queue_module.MPMCBench(duration_s=0.3).run()
    assert result["ok"]
    assert result["total_received"] > 0
