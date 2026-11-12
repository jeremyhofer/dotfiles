#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2", "pyyaml==6.0.3"]
# ///
"""Tests for prose-lint: the engine's text preparation, each pattern-rule exemption, each structural
check, source-set selection, known exceptions, report-only handling, config validation and the CLI.

Every case runs the tool the way a repository meets it (a temp directory holding a config and some
markdown, `--root` pointing at it), except the few that read the text-preparation functions directly.
Each exemption or option has a control beside it: the same files with the exemption removed from the
config, so a pass is shown to come from the exemption and not from a rule that never matches.

PROSE_LINT_TOOL points the suite at another copy of the tool, so a deliberately broken copy can be run
to see the suite fail.

Run: npx nx run suite-prose-lint:test
 or: uv run --script tests/test-prose-lint.py [-k <pattern>]
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = Path(os.environ.get("PROSE_LINT_TOOL")
            or HERE.parent / "private_dot_local" / "bin" / "executable_prose-lint")


def load_tool():
    loader = importlib.machinery.SourceFileLoader("prose_lint_under_test", str(TOOL))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = mod
    loader.exec_module(mod)
    return mod


tool = load_tool()

# --- fixtures and helpers --------------------------------------------------------------------

SETS = """
[[source-set]]
name = "posts"
include = ["posts/*.md", "posts/drafts/*.md"]
exclude = ["**/_*.md"]
skip-field = "ported"
corpus-field = "spoken"

[[source-set]]
name = "docs"
include = ["docs/**/*.md"]
scope = "file"
"""

CONTRASTIVE = r"""\b(?:is|are|was|were)(?:n't| not)\b[^.!?]{1,60}?,\s*(?:it'?s|they'?re|that'?s)\b"""


def toml_value(v):
    return json.dumps(v, ensure_ascii=False)


def table(name, /, **kw):
    """One `[[name]]` table; keys use `_` for `-` in Python."""
    lines = [f"[[{name}]]"]
    lines += [f"{k.replace('_', '-')} = {toml_value(v)}" for k, v in kw.items()]
    return "\n".join(lines) + "\n"


def rule(id, pattern, **kw):
    kw.setdefault("message", f"message for {id}")
    return table("rule", id=id, pattern=pattern, **kw)


def check(kind, **kw):
    return table("check", kind=kind, **kw)


def post(body, front="title: T"):
    """A post whose first body line is file line 5 when `front` is one line."""
    return f"---\n{front}\n---\n\n{body}\n"


HIT = re.compile(r'^(\S+?):(\d+): \[([^\]]+)\] "(.*)"$', re.MULTILINE)


class Result:
    def __init__(self, proc):
        self.rc, self.out, self.err = proc.returncode, proc.stdout, proc.stderr

    @property
    def hits(self):
        return [(m[1], int(m[2]), m[3], m[4]) for m in HIT.finditer(self.err)]

    @property
    def rules(self):
        return [h[2] for h in self.hits]


def lint(tmp_path, files, config, *args, env=None, cwd=None):
    root = tmp_path / "repo"
    root.mkdir(exist_ok=True)
    for rel, text in files.items():
        f = root / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text, encoding="utf-8")
    if config is not None:
        (root / ".prose-lint.toml").write_text(config, encoding="utf-8")
    e = {k: v for k, v in os.environ.items() if k != "PROSE_LINT_CONFIG"}
    e.update(env or {})
    proc = subprocess.run([sys.executable, str(TOOL), "--root", str(root), *args],
                          capture_output=True, text=True, env=e, cwd=cwd or root)
    return Result(proc)


def one(tmp_path, body, config, name="posts/a.md", front="title: T", *args):
    """Lint a single post; findings come back as (file, line, rule, match)."""
    return lint(tmp_path, {name: post(body, front)}, config, *args)


# --- text preparation ------------------------------------------------------------------------

def test_blank_inert_preserves_length():
    line = "text `code` more"
    assert len(tool.blank_inert(line)) == len(line)


def test_blank_inert_blanks_link_destination_keeps_text():
    out = tool.blank_inert("see [the guide](/a-b-c;x) now")
    assert "the guide" in out and "a-b-c" not in out


def test_blank_inert_blanks_html_and_entities():
    assert ";" not in tool.blank_inert('<img src="a.webp" style="x;y"> R&amp;B')


def test_blank_inert_image_destination_blanked_alt_kept():
    assert tool.blank_inert("![alt; text](/a;b.png) after") == f"![alt; text]({' ' * 8}) after"


def test_blank_inert_blanks_bare_url():
    assert "a-b;c" not in tool.blank_inert("go to https://example.test/a-b;c now")


def test_prose_lines_drop_fenced_code():
    lines = tool.prose_lines("prose\n```\ncode; here\n```\nmore", 1)
    assert [t.strip() for _, t in lines] == ["prose", "more"]


def test_prose_lines_drop_tilde_fences():
    assert [t for _, t in tool.prose_lines("a\n~~~\nb\n~~~\nc", 1)] == ["a", "c"]


def test_prose_lines_numbers_start_at_offset():
    assert [n for n, _ in tool.prose_lines("a\nb", 10)] == [10, 11]


def test_split_frontmatter_offsets():
    assert tool.split_frontmatter("plain") == ({}, "plain", 1)
    assert tool.split_frontmatter("---\ntitle: x\nno end") == ({}, "---\ntitle: x\nno end", 1)
    data, body, offset = tool.split_frontmatter("---\na: 1\nb: 2\n---\nbody")
    assert (data, body, offset) == ({"a": 1, "b": 2}, "body", 5)


# --- pattern rules and their exemptions ------------------------------------------------------

def test_rule_flags_a_match_with_file_line_and_text(tmp_path):
    r = one(tmp_path, "The report opens early — then it closes late.", SETS + rule("dash", "—"))
    assert r.rc == 1
    assert r.hits == [("posts/a.md", 5, "dash", "—")]
    assert "message for dash" in r.err


def test_rule_that_does_not_match_is_clean(tmp_path):
    r = one(tmp_path, "A small cabinet holds the spare cables.", SETS + rule("dash", "—"))
    assert r.rc == 0 and r.hits == []


def test_ignore_case(tmp_path):
    text = "UNLOCK the cabinet."
    assert one(tmp_path, text, SETS + rule("w", r"\bunlock\b")).rc == 0
    assert one(tmp_path, text, SETS + rule("w", r"\bunlock\b", ignore_case=True)).rules == ["w"]


def test_rule_counts_each_match_on_a_line(tmp_path):
    r = one(tmp_path, "This will unlock a seamless, robust process.",
            SETS + rule("w", r"\b(?:unlock|seamless|robust)\b"))
    assert [h[3] for h in r.hits] == ["unlock", "seamless", "robust"]


def test_fenced_code_and_inline_code_are_not_prose(tmp_path):
    body = "```\nconst a = 1; // Here's the thing\n```\nUse `a; b` here and <b style=\"x;y\">bold</b>."
    assert one(tmp_path, body, SETS + rule("semi", ";")).rc == 0


def test_empty_match_reports_once_and_terminates(tmp_path):
    r = one(tmp_path, "abc", SETS + rule("empty", "x*"))
    # The post's blank lines match too: one finding per line, each line once.
    assert r.hits == [("posts/a.md", n, "empty", "") for n in (4, 5, 6)]


# corpus exemption

CORPUS_RULE = rule("dive", r"\bdive in\b", ignore_case=True, corpus_exempt=True)


def test_corpus_exemption_drops_a_hit_the_author_said(tmp_path):
    r = one(tmp_path, "We can dive in later.", SETS + CORPUS_RULE, front="spoken: okay we can dive in later")
    assert r.rc == 0


def test_corpus_exemption_control_hit_returns_without_the_exemption(tmp_path):
    cfg = SETS + rule("dive", r"\bdive in\b", ignore_case=True)
    r = one(tmp_path, "We can dive in later.", cfg, front="spoken: okay we can dive in later")
    assert r.rules == ["dive"]


def test_corpus_exemption_control_hit_returns_without_the_corpus(tmp_path):
    assert one(tmp_path, "We can dive in later.", SETS + CORPUS_RULE).rules == ["dive"]


def test_corpus_exemption_compares_lower_case(tmp_path):
    r = one(tmp_path, "We Dive In now.", SETS + CORPUS_RULE, front="spoken: Dive IN")
    assert r.rc == 0


@pytest.mark.parametrize("value", ["5", "[so we dive in]", "{a: dive in}"])
def test_corpus_exemption_needs_a_string_field(tmp_path, value):
    r = one(tmp_path, "So we dive in.", SETS + CORPUS_RULE, front=f"spoken: {value}")
    assert r.rules == ["dive"]


def test_corpus_does_not_exempt_a_rule_that_did_not_ask(tmp_path):
    r = one(tmp_path, "The lamp — the whole lamp.", SETS + rule("dash", "—"), front="spoken: the lamp — the whole lamp")
    assert r.rules == ["dash"]


# context exemption

RANGE = r"[\d)]\s*–\s*[~$(]?\d"


def test_context_exemption_drops_a_hit_in_a_range(tmp_path):
    text = "Fees run $2–$7 per unit, in 3–4 day blocks."
    assert one(tmp_path, text, SETS + rule("en", "–", context_exempt=RANGE)).rc == 0


def test_context_exemption_still_flags_a_sentence_break(tmp_path):
    r = one(tmp_path, "The report opens early – then it closes late.", SETS + rule("en", "–", context_exempt=RANGE))
    assert r.rules == ["en"]


def test_context_exemption_control_hits_return_without_the_exemption(tmp_path):
    text = "Fees run $2–$7 per unit, in 3–4 day blocks."
    assert one(tmp_path, text, SETS + rule("en", "–")).rules == ["en", "en"]


def test_context_window_is_configurable(tmp_path):
    # The text the exemption needs sits just beside the match: inside the default window, outside a window of 0.
    text = "a1 – 2b"
    exempt = rule("en", "–", context_exempt=r"1 – 2")
    assert one(tmp_path, text, SETS + exempt).rc == 0
    assert one(tmp_path, text, "context-window = 0\n" + SETS + exempt).rules == ["en"]


# --- the skip field and the corpus field, source selection ----------------------------------

def test_skip_field_puts_a_file_out_of_scope(tmp_path):
    r = one(tmp_path, "Old — text.", SETS + rule("dash", "—"), front="ported: https://x.test/")
    assert r.rc == 0 and "0 in posts" in r.out


def test_skip_field_control_hit_returns_without_the_field(tmp_path):
    cfg = SETS.replace('skip-field = "ported"\n', "") + rule("dash", "—")
    assert one(tmp_path, "Old — text.", cfg, front="ported: https://x.test/").rules == ["dash"]


def test_skip_field_with_no_value_does_not_skip(tmp_path):
    assert one(tmp_path, "Old — text.", SETS + rule("dash", "—"), front="ported:").rules == ["dash"]


def test_include_and_exclude_globs(tmp_path):
    files = {
        "posts/a.md": post("a — x"),
        "posts/_template.md": post("t — x"),
        "posts/notes.txt": "n — x",
        "posts/drafts/d.md": post("d — x"),
        "posts/sub/deep.md": post("deep — x"),
    }
    r = lint(tmp_path, files, SETS + rule("dash", "—", sets=["posts"]))
    assert sorted(h[0] for h in r.hits) == ["posts/a.md", "posts/drafts/d.md"]


def test_exclude_control_template_returns_without_exclusion(tmp_path):
    files = {"posts/_template.md": post("t — x")}
    cfg = SETS.replace('exclude = ["**/_*.md"]\n', "") + rule("dash", "—")
    assert lint(tmp_path, files, cfg).rules == ["dash"]


def test_double_star_crosses_directories_and_may_match_none(tmp_path):
    files = {"docs/a.md": "x — y", "docs/s/b.md": "x — y", "docs/s/t/c.md": "x — y"}
    r = lint(tmp_path, files, SETS + rule("dash", "—"))
    assert sorted(h[0] for h in r.hits) == ["docs/a.md", "docs/s/b.md", "docs/s/t/c.md"]


def test_skip_dirs_are_not_entered(tmp_path):
    files = {"docs/node_modules/x.md": "x — y", "docs/ok.md": "fine"}
    assert lint(tmp_path, files, SETS + rule("dash", "—")).rc == 0


def test_skip_dirs_control_hit_returns_when_the_list_is_emptied(tmp_path):
    files = {"docs/node_modules/x.md": "x — y"}
    cfg = SETS.replace('include = ["docs/**/*.md"]', 'include = ["docs/**/*.md"]\nskip-dirs = []')
    assert lint(tmp_path, files, cfg + rule("dash", "—")).hits[0][0] == "docs/node_modules/x.md"


def test_missing_directories_are_tolerated(tmp_path):
    r = lint(tmp_path, {}, SETS + rule("dash", "—"))
    assert r.rc == 0 and "0 in posts, 0 in docs" in r.out


def test_body_scope_numbers_lines_from_the_file(tmp_path):
    files = {"posts/a.md": "---\ntitle: T\nspoken: x\n---\nline one\nEdge — here"}
    assert lint(tmp_path, files, SETS + rule("dash", "—")).hits == [("posts/a.md", 6, "dash", "—")]


def test_body_scope_does_not_read_frontmatter(tmp_path):
    files = {"posts/a.md": "---\ntitle: Secret\n---\nbody"}
    assert lint(tmp_path, files, SETS + rule("s", "Secret")).rc == 0


def test_file_scope_reads_frontmatter_too(tmp_path):
    files = {"docs/a.md": "---\ntitle: Secret\n---\nbody"}
    assert lint(tmp_path, files, SETS + rule("s", "Secret")).hits == [("docs/a.md", 2, "s", "Secret")]


def test_unterminated_frontmatter_is_all_body(tmp_path):
    files = {"posts/a.md": "---\ntitle: x\nEdge — here"}
    assert lint(tmp_path, files, SETS + rule("dash", "—")).hits == [("posts/a.md", 3, "dash", "—")]


def test_invalid_yaml_frontmatter_is_exit_2_naming_the_file(tmp_path):
    r = lint(tmp_path, {"posts/a.md": "---\nkey: [unclosed\n---\nbody"}, SETS + rule("dash", "—"))
    assert r.rc == 2 and "posts/a.md" in r.err and "content error" in r.err and "YAML" in r.err
    assert len(r.err.strip().splitlines()) == 1


# --- per-rule sets and paths -----------------------------------------------------------------

def test_rule_sets_restrict_where_it_runs(tmp_path):
    files = {"posts/a.md": post("x — y"), "docs/a.md": "x — y"}
    r = lint(tmp_path, files, SETS + rule("dash", "—", sets=["docs"]))
    assert [h[0] for h in r.hits] == ["docs/a.md"]


def test_rule_without_sets_runs_everywhere(tmp_path):
    files = {"posts/a.md": post("x — y"), "docs/a.md": "x — y"}
    assert len(lint(tmp_path, files, SETS + rule("dash", "—")).hits) == 2


def test_rule_paths_restrict_by_glob(tmp_path):
    files = {"docs/a/x.md": "x — y", "docs/a/deep/er/x.md": "x — y", "docs/b/x.md": "x — y"}
    r = lint(tmp_path, files, SETS + rule("dash", "—", paths=["docs/a/**"]))
    assert sorted(h[0] for h in r.hits) == ["docs/a/deep/er/x.md", "docs/a/x.md"]


def test_rule_paths_control_both_hit_without_paths(tmp_path):
    files = {"docs/a/x.md": "x — y", "docs/b/x.md": "x — y"}
    assert len(lint(tmp_path, files, SETS + rule("dash", "—")).hits) == 2


WWW = r"\bwww\.(?![A-Za-z0-9-])"
SKIPPED_TREES = ["**/docs/archive/plans/**", "**/docs/specs/**"]


def test_rule_exclude_paths_skip_a_file(tmp_path):
    files = {"docs/archive/plans/old.md": "ends with www.", "docs/specs/s.md": "ends with www.",
             "docs/live.md": "ends with www."}
    r = lint(tmp_path, files, SETS + rule("www", WWW, exclude_paths=SKIPPED_TREES))
    assert [h[0] for h in r.hits] == ["docs/live.md"]


def test_rule_exclude_paths_control_hits_return_without_them(tmp_path):
    files = {"docs/archive/plans/old.md": "ends with www.", "docs/specs/s.md": "ends with www."}
    assert len(lint(tmp_path, files, SETS + rule("www", WWW)).hits) == 2


def test_dangling_www_outside_code_only(tmp_path):
    body = "Prefer the apex over `www.` here. Visit www.example.com for more. Ends with a plain www."
    r = lint(tmp_path, {"docs/a.md": body}, SETS + rule("www", WWW))
    assert r.hits == [("docs/a.md", 1, "www", "www.")]


# --- structural checks -----------------------------------------------------------------------

CONTRAST = check("contrastive-density", pattern=CONTRASTIVE, ignore_case=True,
                 density_rule="density", density_message="{count} punchlines here",
                 heading_rule="in-heading", heading_message="not in a heading")


def test_contrastive_one_is_allowed(tmp_path):
    assert one(tmp_path, "The cart isn't a truck, it's a wagon.", SETS + CONTRAST).rc == 0


def test_contrastive_flags_the_second_and_later(tmp_path):
    body = ("The cart isn't a truck, it's a wagon.\nA lamp isn't a sun, it's a candle.\n"
            "A pond isn't a lake, it's a puddle.")
    r = one(tmp_path, body, SETS + CONTRAST)
    assert [(h[1], h[2]) for h in r.hits] == [(6, "density"), (7, "density")]


def test_contrastive_two_names_the_count_line_and_match(tmp_path):
    body = "The cart isn't a truck, it's a wagon.\nA lamp isn't a sun, it's a candle."
    r = one(tmp_path, body, SETS + CONTRAST)
    assert len(r.hits) == 1 and r.hits[0][1] == 6 and "isn't a sun" in r.hits[0][3]
    assert "2 punchlines here" in r.err


def test_contrastive_max_is_configurable(tmp_path):
    body = "The cart isn't a truck, it's a wagon.\nA lamp isn't a sun, it's a candle."
    allow2 = CONTRAST.replace("[[check]]\n", "[[check]]\nmax = 2\n", 1)
    assert one(tmp_path, body, SETS + allow2).rc == 0


def test_contrastive_never_in_a_heading(tmp_path):
    r = one(tmp_path, "## A lamp isn't a sun, it's a candle", SETS + CONTRAST)
    assert r.rules == ["in-heading"]


def test_contrastive_heading_control_passes_without_heading_rule(tmp_path):
    no_heading = check("contrastive-density", pattern=CONTRASTIVE, ignore_case=True,
                       density_rule="density", density_message="m")
    assert one(tmp_path, "## A lamp isn't a sun, it's a candle", SETS + no_heading).rc == 0


TRIPLET = check("clipped-triplets", rule="triplet", message="stacked", skip_lines=r"^\s*[#>|\-*+]")


def test_triplet_flags_three_short_sentences(tmp_path):
    r = one(tmp_path, "It is late. It is dark. Lamps help.", SETS + TRIPLET)
    assert r.hits == [("posts/a.md", 5, "triplet", "Lamps help.")]


def test_triplet_serial_list_in_one_sentence_is_not_flagged(tmp_path):
    assert one(tmp_path, "Count the cups, the plates, and the bowls.", SETS + TRIPLET).rc == 0


def test_triplet_long_sentence_resets_the_run(tmp_path):
    body = "One. Two. This sentence is a good deal longer than eight words in total. Three. Four."
    assert one(tmp_path, body, SETS + TRIPLET).rc == 0


@pytest.mark.parametrize("line", ["# A. B. C.", "> A. B. C.", "| A. B. C.", "- A. B. C."])
def test_triplet_skip_lines_skip_structure(tmp_path, line):
    assert one(tmp_path, line, SETS + TRIPLET).rc == 0


def test_triplet_skip_lines_control_flags_without_them(tmp_path):
    bare = check("clipped-triplets", rule="triplet", message="stacked")
    assert one(tmp_path, "- A. B. C.", SETS + bare).rules == ["triplet"]


def test_triplet_thresholds_are_configurable(tmp_path):
    body = "One. Two. Three."
    four = check("clipped-triplets", rule="triplet", message="m", run=4)
    assert one(tmp_path, body, SETS + four).rc == 0
    short = check("clipped-triplets", rule="triplet", message="m", max_words=1)
    assert one(tmp_path, "Aa bb. Cc dd. Ee ff.", SETS + short).rc == 0
    assert one(tmp_path, "Aa bb. Cc dd. Ee ff.", SETS + TRIPLET).rules == ["triplet"]


DOLLARS = check("paired-dollars", pattern=r"(?<!\\)\$\d", rule="dollar", message="pair",
                alt_paths=["posts/**"], alt_rule="dollar-posts")
DOCS_ONLY = {"sets": ["docs"]}


def test_dollars_lone_amount_is_fine(tmp_path):
    assert lint(tmp_path, {"docs/a.md": "Fees are $5 each."}, SETS + DOLLARS).rc == 0


def test_dollars_pair_in_a_paragraph_flags_each(tmp_path):
    r = lint(tmp_path, {"docs/a.md": "Fees run $3 to $9 each."}, SETS + DOLLARS)
    assert r.rules == ["dollar", "dollar"]


def test_dollars_do_not_pair_across_a_blank_line(tmp_path):
    assert lint(tmp_path, {"docs/a.md": "Costs $3.\n\nAlso $9."}, SETS + DOLLARS).rc == 0


def test_dollars_escaped_amounts_are_ignored(tmp_path):
    assert lint(tmp_path, {"docs/a.md": "Runs \\$3 to \\$9."}, SETS + DOLLARS).rc == 0


def test_dollars_alt_paths_use_the_alt_rule(tmp_path):
    r = one(tmp_path, "Runs $3 to $9.", SETS + DOLLARS)
    assert r.rules == ["dollar-posts", "dollar-posts"]


def test_dollars_min_is_configurable(tmp_path):
    three = check("paired-dollars", pattern=r"\$\d", rule="dollar", message="m", min=3)
    assert lint(tmp_path, {"docs/a.md": "$1 and $2."}, SETS + three).rc == 0
    assert lint(tmp_path, {"docs/a.md": "$1 and $2 and $3."}, SETS + three).rules == ["dollar"] * 3


def test_checks_run_only_on_their_sets(tmp_path):
    scoped = check("paired-dollars", sets=["docs"], pattern=r"\$\d", rule="dollar", message="m")
    files = {"docs/a.md": "$1 and $2.", "posts/a.md": post("$1 and $2.")}
    assert {h[0] for h in lint(tmp_path, files, SETS + scoped).hits} == {"docs/a.md"}


def test_checks_read_in_code_free_prose(tmp_path):
    body = "```\n$1 and $2\n```\nOnly `$3` and `$4` here."
    assert lint(tmp_path, {"docs/a.md": body}, SETS + DOLLARS).rc == 0


# --- report-only, known exceptions -----------------------------------------------------------

DASH = rule("dash", "—")


def test_report_only_never_fails_and_is_hidden_by_default(tmp_path):
    r = one(tmp_path, "Edge — here.", SETS + rule("dash", "—", report_only=True))
    assert r.rc == 0 and r.err == "" and "1 advisory, run with --report" in r.out


def test_report_only_is_shown_with_report_and_still_exit_0(tmp_path):
    r = one(tmp_path, "Edge — here.", SETS + rule("dash", "—", report_only=True), "posts/a.md", "title: T", "--report")
    assert r.rc == 0 and r.hits == [("posts/a.md", 5, "dash", "—")] and "advisory" in r.err


def test_report_only_control_fails_without_the_flag(tmp_path):
    assert one(tmp_path, "Edge — here.", SETS + DASH).rc == 1


def test_report_only_list_covers_structural_ids(tmp_path):
    cfg = 'report-only = ["triplet"]\n' + SETS + TRIPLET
    r = one(tmp_path, "One. Two. Three.", cfg)
    assert r.rc == 0 and "advisory" in r.out
    assert one(tmp_path, "One. Two. Three.", SETS + TRIPLET).rc == 1


def test_report_with_nothing_advisory_prints_nothing(tmp_path):
    r = one(tmp_path, "Clean.", SETS + DASH, "posts/a.md", "title: T", "--report")
    assert r.rc == 0 and r.err == ""


def exception(**kw):
    return table("exception", **kw)


def test_known_exception_demotes_a_finding_to_advisory(tmp_path):
    cfg = SETS + DASH + exception(file="posts/a.md", rule="dash", reason="reviewed")
    quiet = one(tmp_path, "Edge — here.", cfg)
    assert quiet.rc == 0 and quiet.err == ""
    loud = one(tmp_path, "Edge — here.", cfg, "posts/a.md", "title: T", "--report")
    assert loud.rc == 0 and loud.rules == ["dash"]


def test_known_exception_control_fails_without_the_entry(tmp_path):
    assert one(tmp_path, "Edge — here.", SETS + DASH).rc == 1


def test_known_exception_is_per_file_and_per_rule(tmp_path):
    files = {"posts/a.md": post("Edge — here."), "posts/b.md": post("Edge — here; and")}
    cfg = SETS + DASH + rule("semi", ";") + exception(file="posts/a.md", rule="dash", reason="r")
    r = lint(tmp_path, files, cfg)
    assert r.rc == 1
    assert sorted((h[0], h[2]) for h in r.hits) == [("posts/b.md", "dash"), ("posts/b.md", "semi")]


def test_known_exception_match_narrows_it(tmp_path):
    files = {"posts/a.md": post("One — two; three")}
    cfg = SETS + DASH + rule("semi", ";")
    narrow = cfg + exception(file="posts/a.md", rule="dash", match="—", reason="r")
    assert lint(tmp_path, files, narrow).rules == ["semi"]
    wrong = cfg + exception(file="posts/a.md", rule="dash", match="–", reason="r")
    assert lint(tmp_path, files, wrong).rules == ["dash", "semi"]


# --- output and CLI --------------------------------------------------------------------------

def test_clean_tree_reports_what_it_read(tmp_path):
    files = {"posts/a.md": post("Plain."), "docs/x.md": "Nothing wrong.", "docs/y.md": "Also fine."}
    r = lint(tmp_path, files, SETS + DASH)
    assert r.rc == 0 and r.err == ""
    assert r.out.strip() == "prose-lint: OK: files read: 1 in posts, 2 in docs; 0 findings"


def test_findings_are_grouped_by_file_sorted_and_footer_printed(tmp_path):
    # A third set selects every file again, so each file's findings are produced in two separated
    # batches and files are visited out of name order: grouping and sorting both have work to do.
    everything = table("source-set", name="everything", include=["**/*.md"], scope="file")
    files = {"posts/x.md": post("q — r"), "docs/q.md": "a — b\nc — d"}
    r = lint(tmp_path, files, 'footer = "see the style guide"\n' + SETS + everything + DASH)
    assert r.rc == 1 and r.out == ""
    assert [(h[0], h[1]) for h in r.hits] == [
        ("docs/q.md", 1), ("docs/q.md", 2), ("docs/q.md", 1), ("docs/q.md", 2),
        ("posts/x.md", 5), ("posts/x.md", 5)]
    assert "prose-lint: 6 prose finding(s):" in r.err
    assert "    message for dash" in r.err
    assert r.err.rstrip().endswith("see the style guide")


def test_no_config_is_exit_0_and_says_nothing_was_checked(tmp_path):
    r = lint(tmp_path, {"posts/a.md": post("Edge — here.")}, None)
    assert r.rc == 0 and r.out == ""
    assert "no config found" in r.err and "nothing was checked" in r.err


def test_config_discovery_order(tmp_path):
    files = {"docs/a.md": "dash — semi ; ellipsis ... end"}
    root_cfg = SETS + rule("dash", "—")
    (tmp_path / "env.toml").write_text(SETS + rule("semi", ";"))
    (tmp_path / "flag.toml").write_text(SETS + rule("ellipsis", r"\.\.\."))
    assert lint(tmp_path, files, root_cfg).rules == ["dash"]
    assert lint(tmp_path, files, root_cfg, env={"PROSE_LINT_CONFIG": str(tmp_path / "env.toml")}).rules == ["semi"]
    flag = lint(tmp_path, files, root_cfg, "--config", str(tmp_path / "flag.toml"),
                env={"PROSE_LINT_CONFIG": str(tmp_path / "env.toml")})
    assert flag.rules == ["ellipsis"]


def test_missing_config_files_are_exit_2(tmp_path):
    r = lint(tmp_path, {}, SETS, "--config", str(tmp_path / "nope.toml"))
    assert r.rc == 2 and "nope.toml" in r.err
    r = lint(tmp_path, {}, SETS, env={"PROSE_LINT_CONFIG": str(tmp_path / "nope2.toml")})
    assert r.rc == 2 and "PROSE_LINT_CONFIG" in r.err


def test_paths_narrow_the_run_and_unselected_paths_are_reported(tmp_path):
    files = {"posts/a.md": post("a — x"), "posts/b.md": post("b — x"), "README.md": "r — x"}
    r = lint(tmp_path, files, SETS + DASH, "posts/a.md", "README.md")
    assert [h[0] for h in r.hits] == ["posts/a.md"]
    assert "SKIPPED README.md" in r.err and "nothing was checked" in r.err


def test_paths_outside_the_root_are_skipped(tmp_path):
    outside = tmp_path / "elsewhere.md"
    outside.write_text("x — y")
    r = lint(tmp_path, {"posts/a.md": post("fine")}, SETS + DASH, str(outside))
    assert r.rc == 0 and "SKIPPED" in r.err


def bad(config_tail, expect, head=SETS):
    return pytest.param(head + config_tail, expect, id=expect.replace(" ", "_")[:40])


CONFIG_ERRORS = [
    bad("not toml [[", "not valid TOML"),
    bad('bogus = 1\n', "unknown key 'bogus'"),
    bad(table("rule", id="r", pattern="x", message="m", mesage="typo"), "[[rule]] 'r': unknown key 'mesage'"),
    bad(table("rule", id="r", message="m"), "missing required key 'pattern'"),
    bad(table("rule", id="r", pattern="(", message="m"), "key 'pattern' is not a valid regex"),
    bad(table("rule", id="r", pattern="x", message="m", context_exempt="["), "key 'context-exempt'"),
    bad(table("rule", id="r", pattern="x", message="m", sets=["nope"]), "names 'nope'"),
    bad(table("rule", id="r", pattern="x", message="m", corpus_exempt="yes"), "key 'corpus-exempt' must be true or false"),
    bad(table("rule", id="r", pattern=5, message="m"), "key 'pattern' must be a non-empty string"),
    bad(table("check", kind="nope"), "key 'kind' must be one of"),
    bad(table("check", kind="clipped-triplets", message="m"), "missing required key 'rule'"),
    bad(table("check", kind="clipped-triplets", rule="r", message="m", run=0), "key 'run' must be an integer >= 1"),
    bad(table("check", kind="paired-dollars", pattern="x", rule="r", message="m", alt_rule="a"), "'alt-paths' and 'alt-rule' go together"),
    bad(table("check", kind="contrastive-density", pattern="x", density_rule="d", density_message="m", heading_rule="h"),
        "'heading-rule' and 'heading-message' go together"),
    bad(table("exception", file="a.md", rule="r"), "missing required key 'reason'"),
    bad(table("source-set", name="posts", include=["x"]), "key 'name' is used twice"),
    bad(table("source-set", name="x", include=["x"], scope="some"), "key 'scope' must be"),
    bad(table("source-set", name="x"), "missing required key 'include'"),
    bad("rule = 5\n", "'rule' must be an array of tables", head=""),
    bad(table("rule", id="r", pattern="x", message="m", context_exempt=""), "key 'context-exempt' must be a non-empty string"),
    bad(table("rule", id="r", pattern="x", message="m", sets=[]), "key 'sets' must be a non-empty list"),
    bad(table("rule", id="r", pattern="x", message="m", paths=[]), "key 'paths' must be a non-empty list"),
    bad(table("check", kind="clipped-triplets", rule="r", message="m", skip_lines=""), "key 'skip-lines' must be a non-empty string"),
    bad(table("check", kind="clipped-triplets", rule="r", message="m", sets=[]), "key 'sets' must be a non-empty list"),
    bad(table("check", kind="contrastive-density", pattern="x", density_rule="d", density_message="m",
              heading_rule="", heading_message="h"), "key 'heading-rule' must be a non-empty string"),
    bad(table("check", kind="contrastive-density", pattern="x", density_rule="d", density_message="m",
              heading_rule="h", heading_message=""), "key 'heading-message' must be a non-empty string"),
    bad(table("check", kind="paired-dollars", pattern="x", rule="r", message="m", alt_paths=["a/**"], alt_rule=""),
        "key 'alt-rule' must be a non-empty string"),
    bad(table("source-set", name="x", include=["x"], skip_field=""), "key 'skip-field' must be a non-empty string"),
    bad(table("source-set", name="x", include=["x"], corpus_field=""), "key 'corpus-field' must be a non-empty string"),
    bad(table("source-set", name="x", include=[]), "key 'include' must be a non-empty list"),
]


@pytest.mark.parametrize("config,expect", CONFIG_ERRORS)
def test_config_errors_are_exit_2_and_name_the_key(tmp_path, config, expect):
    r = lint(tmp_path, {"docs/a.md": "x — y"}, config)
    assert r.rc == 2, r.err
    assert expect in r.err
    assert r.hits == []


def test_a_valid_config_with_every_check_loads(tmp_path):
    cfg = SETS + DASH + CONTRAST + TRIPLET + DOLLARS + exception(file="x.md", rule="dash", reason="r")
    assert lint(tmp_path, {"docs/a.md": "fine"}, cfg).rc == 0


def test_usage_error_is_exit_2(tmp_path):
    r = lint(tmp_path, {}, SETS, "--no-such-flag")
    assert r.rc == 2


# --- skip field values, case, CRLF, BOM --------------------------------------------------------

@pytest.mark.parametrize("value,skipped", [("true", True), ("false", True), ("0", True), ('""', True), ("https://x.test/", True),
                                          ("null", False), ("", False)])
def test_skip_field_means_a_non_null_value(tmp_path, value, skipped):
    r = one(tmp_path, "Old — text.", SETS + DASH, front=f"ported: {value}")
    assert (r.rc == 0) is skipped


def test_contrastive_ignore_case(tmp_path):
    body = "The Cart ISN'T a truck, it's a wagon.\nA lamp IS NOT a sun, it's a candle."
    on = check("contrastive-density", pattern=CONTRASTIVE, ignore_case=True, density_rule="density", density_message="m")
    off = check("contrastive-density", pattern=CONTRASTIVE, density_rule="density", density_message="m")
    assert one(tmp_path, body, SETS + on).rules == ["density"]
    assert one(tmp_path, body, SETS + off).rc == 0


def test_crlf_frontmatter_is_read(tmp_path):
    text = "---\r\nported: yes\r\n---\r\nEdge — x\r\n"
    assert lint(tmp_path, {"posts/a.md": text}, SETS + DASH).rc == 0
    plain = "---\r\ntitle: T\r\n---\r\nline\r\nEdge — x\r\n"
    assert lint(tmp_path, {"posts/a.md": plain}, SETS + DASH).hits == [("posts/a.md", 5, "dash", "—")]


def test_bom_file_keeps_its_frontmatter(tmp_path):
    skipped = "\ufeff---\nported: yes\n---\nEdge — x\n"
    assert lint(tmp_path, {"posts/a.md": skipped}, SETS + DASH).rc == 0
    spoken = "\ufeff---\nspoken: the lamp\n---\n\nThe lamp — here.\n"
    rule_ = rule("lamp", r"\bthe lamp\b", corpus_exempt=True)
    assert lint(tmp_path, {"posts/a.md": spoken}, SETS + rule_).rc == 0
    body = "\ufeff---\ntitle: Edge — x\n---\nplain\n"
    assert lint(tmp_path, {"posts/a.md": body}, SETS + DASH).rc == 0


def test_bom_file_with_file_scope_reads_the_first_line(tmp_path):
    r = lint(tmp_path, {"docs/a.md": "\ufeffEdge — x"}, SETS + DASH)
    assert r.hits == [("docs/a.md", 1, "dash", "—")]


def test_bom_config_is_read(tmp_path):
    r = lint(tmp_path, {"docs/a.md": "Edge — x"}, "\ufeff" + SETS + DASH)
    assert r.rules == ["dash"]


# --- unreadable files and configs are exit 2, not a traceback ----------------------------------

def assert_one_line_exit_2(r, *names):
    assert r.rc == 2, r.err
    assert len(r.err.strip().splitlines()) == 1, r.err
    assert all(n in r.err for n in names)


def test_broken_symlink_is_exit_2_naming_it(tmp_path):
    (tmp_path / "repo" / "docs").mkdir(parents=True)
    (tmp_path / "repo" / "docs" / "broken.md").symlink_to("missing.md")
    assert_one_line_exit_2(lint(tmp_path, {}, SETS + DASH), "docs/broken.md")


def test_unreadable_file_is_exit_2_naming_it(tmp_path):
    if os.geteuid() == 0:
        pytest.skip("root reads any file")
    f = tmp_path / "repo" / "docs" / "locked.md"
    f.parent.mkdir(parents=True)
    f.write_text("x")
    f.chmod(0)
    try:
        assert_one_line_exit_2(lint(tmp_path, {}, SETS + DASH), "docs/locked.md")
    finally:
        f.chmod(0o644)


def test_config_that_is_not_utf8_is_exit_2_naming_it(tmp_path):
    (tmp_path / "repo").mkdir()
    (tmp_path / "repo" / ".prose-lint.toml").write_bytes(b"name = '\xff\xfe\x80'\n")
    assert_one_line_exit_2(lint(tmp_path, {}, None), ".prose-lint.toml")


def test_unreadable_config_is_exit_2_naming_it(tmp_path):
    if os.geteuid() == 0:
        pytest.skip("root reads any file")
    cfg = tmp_path / "repo" / ".prose-lint.toml"
    cfg.parent.mkdir()
    cfg.write_text(SETS)
    cfg.chmod(0)
    try:
        assert_one_line_exit_2(lint(tmp_path, {}, None), ".prose-lint.toml")
    finally:
        cfg.chmod(0o644)


# --- fences follow CommonMark ------------------------------------------------------------------

def fenced(tmp_path, body):
    return lint(tmp_path, {"docs/a.md": body}, SETS + DASH).hits


def test_fence_text_on_the_opening_line_with_a_backtick_does_not_open(tmp_path):
    hits = fenced(tmp_path, "Edge — a\n```js``` is inline\nEdge — b")
    assert [h[1] for h in hits] == [1, 3]


def test_other_fence_character_does_not_close(tmp_path):
    hits = fenced(tmp_path, "```\n~~~\nEdge — in\n```\nEdge — out")
    assert [h[1] for h in hits] == [5]


def test_shorter_fence_does_not_close(tmp_path):
    hits = fenced(tmp_path, "````\n```\nEdge — in\n````\nEdge — out")
    assert [h[1] for h in hits] == [5]


def test_closing_fence_with_text_after_it_does_not_close(tmp_path):
    hits = fenced(tmp_path, "```\n``` text\nEdge — in\n```\nEdge — out")
    assert [h[1] for h in hits] == [5]


def test_longer_fence_closes(tmp_path):
    hits = fenced(tmp_path, "```\nEdge — in\n`````  \nEdge — out")
    assert [h[1] for h in hits] == [4]


def test_tilde_fence_may_carry_a_backtick_in_its_info_string(tmp_path):
    hits = fenced(tmp_path, "~~~ a`b\nEdge — in\n~~~\nEdge — out")
    assert [h[1] for h in hits] == [4]


def test_unclosed_fence_runs_to_the_end(tmp_path):
    assert fenced(tmp_path, "Edge — a\n```\nEdge — hidden\nEdge — also") == [("docs/a.md", 1, "dash", "—")]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
