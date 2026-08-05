"""Tests for the extraction layer.

These cover the pure logic -- filename parsing, the incremental set arithmetic,
and the cost guard. That is deliberately where the tests are: those are the
parts that would actually break, and they need no BigQuery or GCS connection to
exercise.
"""

import datetime as dt

import pytest

from extract import config
from extract.extract_crm import missing_snapshots, parse_snapshot_date
from extract.extract_market import build_sql, check_cost


# --- filename parsing ------------------------------------------------------


def test_parse_snapshot_date_from_bare_filename():
    assert parse_snapshot_date("crm_accounts_2025-11-04.csv") == dt.date(2025, 11, 4)


def test_parse_snapshot_date_from_full_object_path():
    assert parse_snapshot_date("crm/crm_opportunities_2026-05-02.csv") == dt.date(
        2026, 5, 2
    )


@pytest.mark.parametrize(
    "name",
    [
        "product_catalogue.parquet",
        "crm_accounts.csv",           # no date
        "crm_accounts_2025-11.csv",   # partial date
        "crm_accounts_2025-11-04.txt",  # wrong extension
    ],
)
def test_parse_snapshot_date_rejects_unexpected_names(name):
    """A file we cannot date must raise, never load silently under a guess."""
    with pytest.raises(ValueError):
        parse_snapshot_date(name)


# --- incremental logic -----------------------------------------------------

D = dt.date


def test_first_run_loads_everything():
    available = {D(2025, 11, 4): "a", D(2025, 11, 5): "b"}
    assert missing_snapshots(available, set()) == [D(2025, 11, 4), D(2025, 11, 5)]


def test_second_run_is_a_noop():
    available = {D(2025, 11, 4): "a", D(2025, 11, 5): "b"}
    assert missing_snapshots(available, set(available)) == []


def test_only_the_gap_is_loaded():
    available = {D(2025, 11, 4): "a", D(2025, 11, 5): "b", D(2025, 11, 6): "c"}
    loaded = {D(2025, 11, 4), D(2025, 11, 6)}
    assert missing_snapshots(available, loaded) == [D(2025, 11, 5)]


def test_result_is_sorted():
    available = {D(2025, 11, 6): "c", D(2025, 11, 4): "a", D(2025, 11, 5): "b"}
    assert missing_snapshots(available, set()) == sorted(available)


def test_extra_loaded_dates_do_not_resurface():
    """A snapshot pulled from the bucket before it was withdrawn stays loaded."""
    available = {D(2025, 11, 5): "b"}
    loaded = {D(2025, 11, 4), D(2025, 11, 5)}
    assert missing_snapshots(available, loaded) == []


# --- cost guard ------------------------------------------------------------


def test_cost_guard_allows_a_query_under_the_ceiling():
    check_cost(4 * 1024**3, ceiling=10 * 1024**3)  # must not raise


def test_cost_guard_blocks_a_query_over_the_ceiling():
    with pytest.raises(RuntimeError, match="Refusing to run"):
        check_cost(50 * 1024**3, ceiling=10 * 1024**3)


# --- the gin category decision --------------------------------------------


def test_sloe_gin_is_excluded():
    """Sloe gin is a sweetened liqueur, not part of Thameswood's set."""
    assert "AMERICAN SLOE GINS" not in config.gin_categories()


def test_virgin_islands_rum_is_not_matched():
    """The reason we use an explicit list rather than LIKE '%GIN%'."""
    assert "PUERTO RICO & VIRGIN ISLANDS RUM" not in config.gin_categories()
    assert "PUERTO RICO & VIRGIN ISLANDS RUM" not in build_sql()


def test_both_flavored_gin_spellings_are_captured():
    cats = config.gin_categories()
    assert "FLAVORED GIN" in cats and "FLAVORED GINS" in cats


def test_generated_sql_contains_every_gin_category():
    sql = build_sql()
    for category in config.gin_categories():
        assert category in sql
