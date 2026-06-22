import pytest

FUNC_TEST_NAMES = [
    "spsc  push/pop",
    "spsc  try_push full",
    "spsc  try_pop empty",
    "spsc  borrow/commit",
    "spsc  push_var/pop_var",
    "spsc  try_push_var full",
    "spsc  try_pop_var empty",
    "spmc  fanout 1p3c",
    "spmc  try_pop empty",
    "spmc  borrow/commit",
    "spmc  push_var/pop_var",
    "mpsc  3p1c total",
    "mpsc  try_push full",
    "mpsc  borrow/commit",
    "mpsc  push_var/pop_var",
    "mpmc  fanout 3p3c",
    "mpmc  try_pop empty",
    "mpmc  push_var/pop_var",
]


@pytest.fixture(scope="module")
def func_results(queue_module):
    return dict(queue_module.run_func_tests_collect())


@pytest.mark.parametrize("name", FUNC_TEST_NAMES)
def test_functional(func_results, name):
    assert name in func_results, f"missing result for {name!r}"
    assert func_results[name] == 0, f"{name} reported {func_results[name]} failure(s)"
