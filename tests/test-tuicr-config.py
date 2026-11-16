#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""tuicr's deployed config is read the way tuicr reads it.

Run: sh tests/run-all.sh --only test-tuicr-config.py
 or: uv run --script tests/test-tuicr-config.py [-k <pattern>]

Why this exists: TOML puts every key that follows a `[table]` header inside that table. A
top-level key written below `[forge]` is read as `forge.<key>`, which tuicr warns about at startup
and ignores, falling back to its built-in defaults. The comment types sat below `[forge]` that way
from the file's first commit, so none of them ever loaded, and nothing said so. These tests hold the
keys at the level tuicr reads them, with only the fields tuicr accepts (as of tuicr 0.29.0:
`src/config/mod.rs`, `CommentTypeConfig` and `ForgeConfig`).
"""
import sys
import tomllib
from pathlib import Path

import pytest

CONFIG = Path(__file__).resolve().parent.parent / "dot_config" / "tuicr" / "config.toml"
TYPE_FIELDS = {"id", "label", "definition", "color"}
FORGE_KEYS = {"comment_type_prefix"}


@pytest.fixture(scope="module")
def config():
    with CONFIG.open("rb") as f:
        return tomllib.load(f)


def test_comment_types_are_a_top_level_key(config):
    assert "comment_types" in config, "comment_types is not top level (is it below a [table]?)"
    assert isinstance(config["comment_types"], list) and config["comment_types"]


def test_the_forge_table_holds_only_keys_tuicr_reads_there(config):
    assert set(config.get("forge", {})) <= FORGE_KEYS


def test_each_comment_type_has_an_id_and_only_known_fields(config):
    for entry in config["comment_types"]:
        assert set(entry) <= TYPE_FIELDS, entry
        assert isinstance(entry.get("id"), str) and entry["id"], entry


def test_the_routing_ids_the_review_skill_names_are_configured(config):
    ids = [entry["id"] for entry in config["comment_types"]]
    assert ids == ["issue", "suggestion", "nit", "question", "praise", "callout",
                   "discussion", "followup", "internal"]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
