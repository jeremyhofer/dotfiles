#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2", "pytest-xdist==3.8.0"]
# ///
"""Tests for the session-lifecycle suite's classifier (share/seam-probe/suites/session-lifecycle/
classify.py): each verdict branch judged from a hand-written record, with no clock and no process.

The cases write a JSONL record of what they saw and decide nothing; classify.py judges every verdict
from the record alone. So these tests can use the cases' real settings (a 900 s tolerance, a 1800 s
margin, 60 s rounds) where the end-to-end tests in test-seam-probe.py compress time into seconds of
wall clock, and the machine's load cannot move a result here. Times are seconds from each arm's
first turn's end, which is 0 unless a row says otherwise. Each row is one branch; the table's
section names follow the classifier's (shared control, idle_like, schedule, release, decided,
completion-hold, attached-stop)."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
CLASSIFY = HERE.parent / "private_dot_local/share/seam-probe/suites/session-lifecycle/classify.py"
_spec = importlib.util.spec_from_file_location("classify", CLASSIFY)
classify = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(classify)

IDLE_ARMS = ["control", "shell", "turn", "schedule", "release"]
CFG = {"tolerance": "900", "margin": "1800", "cap": "7200", "turn_due": "900", "record": "r.jsonl"}
# The pass path at real scale: the control stops 61 min after its turn; shell 62 min after its own;
# turn 61 min after its job's turn (FIRED at 900 s, when due); schedule never (a pending job); release
# never, its completion (RELEASED at 900 s) holding it past the control's idle plus the margin.
PASS_STOPS = {"control": 3660, "shell": 3720, "turn": 4560, "schedule": None, "release": None}
PASS_WORDS = {"turn": ("FIRED", 900.0), "release": ("RELEASED", 900.0)}


def header(case, arms, cfg, pre=None, ends=None, watch=None):
    pre, ends = pre or {}, ends or {}
    return {"kind": "header", "case": case, "plant": None, "config": cfg, "t_launch": -30.0,
            "arms": {a: {"turn_end": ends.get(a, 0.0), "pre": pre.get(a)} for a in arms},
            "watch": watch if watch is not None else [a for a in arms if a not in pre]}


def rounds(stops, end=7200, start=60, step=60, words=None, unread=None, arms=None):
    """One round each STEP seconds from START to END: an arm reads stopped from its stop time on,
    running before it, unreadable at the times UNREAD gives it (a set, or "all"); WORDS gives an
    arm's codeword and the transcript time it was written, first sighted at the round after it."""
    words, unread = words or {}, unread or {}
    out, seen_word = [], set()
    for t in range(start, end + 1, step):
        st = {}
        for a in arms or stops:
            u = unread.get(a)
            if u == "all" or (u and t in u):
                st[a] = "unreadable"
            elif stops.get(a) is not None and t >= stops[a]:
                st[a] = "stopped"
            else:
                st[a] = "running"
        w = {}
        for a, (word, at) in words.items():
            if a not in seen_word and t >= at:
                w[a] = {"word": word, "at": at}
                seen_word.add(a)
        out.append({"kind": "round", "t": float(t), "arms": st, "status": {}, "notes": {}, "words": w})
    return out


def write(tmp_path, lines):
    p = tmp_path / "r.jsonl"
    p.write_text("".join(json.dumps(x) + "\n" for x in lines))
    return p


def judge(tmp_path, lines):
    return {a: (v, r) for a, v, r in classify.judge(str(write(tmp_path, lines))).verdicts()}


def idle(tmp_path, stops=None, end=7200, start=60, words=None, unread=None, pre=None, ends=None,
         cfg=None, watch=None):
    s = dict(PASS_STOPS, **(stops or {}))
    w = dict(PASS_WORDS, **(words or {}))
    w = {k: v for k, v in w.items() if v is not None}
    h = header("idle-holders", IDLE_ARMS, dict(CFG, **(cfg or {})), pre, ends, watch)
    body = rounds({a: s[a] for a in h["watch"]}, end, start, words=w, unread=unread)
    return h, body + [{"kind": "end", "t": float(end)}]


def verdicts(v):
    return {a: x[0] for a, x in v.items()}


# ---- the shared control branches (both idle cases) ---------------------------------------------

def test_s1_a_control_with_a_verdict_before_polling_gives_it_to_every_arm(tmp_path):
    h, body = idle(tmp_path, pre={"control": {"verdict": "VOID", "reason": "the control made tool calls, so x"}})
    v = judge(tmp_path, [h] + body)
    assert v == {a: ("VOID", "control: the control made tool calls, so x") for a in IDLE_ARMS}


def test_s2_a_control_never_read_leaves_every_arm_inconclusive(tmp_path):
    h, body = idle(tmp_path, unread={"control": "all"})
    v = judge(tmp_path, [h] + body)
    assert set(verdicts(v).values()) == {"INCONCLUSIVE"}
    assert "the control's process state could not be read at any poll (the poll record is at <results>/r.jsonl)" == v["shell"][1]


def test_s3_a_control_unreadable_at_the_end_is_inconclusive_not_void(tmp_path):
    h, body = idle(tmp_path, stops={"control": None}, unread={"control": set(range(660, 7201, 60))})
    v = judge(tmp_path, [h] + body)
    assert set(verdicts(v).values()) == {"INCONCLUSIVE"}
    assert "unreadable at the end of the run (last read, still present, 10.0 min after its turn ended)" in v["turn"][1]


def test_s4_a_control_never_stopped_voids_every_arm(tmp_path):
    h, body = idle(tmp_path, stops={"control": None})
    v = judge(tmp_path, [h] + body)
    assert set(verdicts(v).values()) == {"VOID"}
    assert "the control was never stopped" in v["shell"][1] and "120.0 min after its turn ended, at the end of the 7200s cap" in v["shell"][1]


def test_s5_a_control_gone_at_the_first_look_is_not_timed(tmp_path):
    # The first round comes after the control's stop, as on a loaded machine whose launches outlast it.
    h, body = idle(tmp_path, start=3700)
    v = judge(tmp_path, [h] + body)
    assert set(verdicts(v).values()) == {"INCONCLUSIVE"}
    assert "the control was already gone at the first look, 61.7 min after its turn ended" in v["release"][1]


def test_s6_and_the_pass_path(tmp_path):
    h, body = idle(tmp_path)
    v = judge(tmp_path, [h] + body)
    assert verdicts(v) == {a: "PASS" for a in IDLE_ARMS}
    assert v["control"][1] == "the idle stop was observed: no process 61.0 min after its turn ended"
    assert v["shell"][1] == "stopped 62.0 min after its first turn ended, against the control's 61.0 min after its own: within the 15.0 min tolerance"
    assert "its job's turn ended (FIRED, read from its transcript 15.0 min after its first turn)" in v["turn"][1]
    assert "a margin of at least 30.0 min" in v["schedule"][1]
    assert "the delivered completion held it" in v["release"][1]


def test_s7_a_turn_end_is_the_transcripts_not_the_first_looks(tmp_path):
    # The first round is 20 min after every turn ended. The control's idle is still from its turn's
    # end in the header, and a shell stop 30 min sooner still reads sooner.
    h, body = idle(tmp_path, start=1200, stops={"shell": 1800})
    v = judge(tmp_path, [h] + body)
    assert v["control"] == ("PASS", "the idle stop was observed: no process 61.0 min after its turn ended")
    assert v["shell"][0] == "INCONCLUSIVE" and v["shell"][1].startswith("stopped 30.0 min after its first turn ended, sooner than the control's 61.0 min")


# ---- idle_like: shell from its first turn, turn from FIRED --------------------------------------

def test_i1_present_past_the_margin_fails(tmp_path):
    h, body = idle(tmp_path, stops={"shell": None, "turn": None})
    v = judge(tmp_path, [h] + body)
    assert v["shell"] == ("FAIL", "still present 120.0 min after its first turn ended, past the control's idle duration (61.0 min) by at least the 30.0 min margin")
    assert v["turn"][0] == "FAIL" and "still present 105.0 min after its job's turn ended" in v["turn"][1]


def test_i1_present_past_the_margin_then_stopped_fails_naming_the_stop(tmp_path):
    h, body = idle(tmp_path, stops={"shell": 6000})
    v = judge(tmp_path, [h] + body)
    assert v["shell"][0] == "FAIL" and v["shell"][1].endswith("margin (stopped later, 100.0 min after it)")


def test_i2_gone_at_the_first_look_and_sooner_by_more_than_the_tolerance(tmp_path):
    h, body = idle(tmp_path, stops={"shell": 30})
    v = judge(tmp_path, [h] + body)
    assert v["shell"] == ("INCONCLUSIVE", "stopped at most 1.0 min after its first turn ended (gone at the first look), sooner than the control's 61.0 min by more than the 15.0 min tolerance: not the idle stop the control showed")


def test_i3_gone_at_the_first_look_and_not_sooner_by_the_tolerance(tmp_path):
    h, body = idle(tmp_path, start=3000, stops={"shell": 2900})
    v = judge(tmp_path, [h] + body)
    assert v["shell"] == ("INCONCLUSIVE", "already gone at the first look, 50.0 min after its first turn ended, so it stopped at some time before then, which cannot be compared with the control's 61.0 min (the poll record is at <results>/r.jsonl)")


def test_i4_within_the_tolerance_passes(tmp_path):
    # Either side of the control, by up to the tolerance.
    for stop in (3660 - 900, 3660 + 900):
        h, body = idle(tmp_path, stops={"shell": stop})
        assert judge(tmp_path, [h] + body)["shell"][0] == "PASS", stop


def test_i5_sooner_by_more_than_the_tolerance_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, stops={"shell": 2700})
    v = judge(tmp_path, [h] + body)
    assert v["shell"] == ("INCONCLUSIVE", "stopped 45.0 min after its first turn ended, sooner than the control's 61.0 min by more than the 15.0 min tolerance: not the idle stop the control showed")


def test_i6_later_by_more_than_the_tolerance_within_the_margin_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, stops={"shell": 4620})
    v = judge(tmp_path, [h] + body)
    assert v["shell"] == ("INCONCLUSIVE", "stopped 77.0 min after its first turn ended, later than the control's 61.0 min by more than the 15.0 min tolerance but within the 30.0 min margin: something held it a while, and this case does not read what")


def test_i7_never_read_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, unread={"shell": "all"})
    v = judge(tmp_path, [h] + body)
    assert v["shell"] == ("INCONCLUSIVE", "its process state could not be read at any poll (the poll record is at <results>/r.jsonl)")


def test_i8_a_run_cut_short_of_the_margin_cannot_pass_or_fail(tmp_path):
    h, body = idle(tmp_path, end=4500, stops={"shell": None})
    v = judge(tmp_path, [h] + body)
    assert v["shell"] == ("INCONCLUSIVE", "the run ended too soon to tell: last seen present 75.0 min after its first turn ended, short of the control's idle duration plus the margin (the poll record is at <results>/r.jsonl)")


def test_i9_a_job_turn_never_seen_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, words={"turn": None})
    v = judge(tmp_path, [h] + body)
    assert v["turn"] == ("INCONCLUSIVE", "its job's turn was never seen (no FIRED in its transcript by the end of the run, 120.0 min after its first turn), so there is no turn to time a stop from (the poll record is at <results>/r.jsonl)")


def test_i10_a_job_turn_seen_before_its_job_was_due_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, words={"turn": ("FIRED", 600.0)})
    v = judge(tmp_path, [h] + body)
    assert v["turn"] == ("INCONCLUSIVE", "FIRED was seen 5.0 min before its job was due, so another turn wrote it and the job's own turn cannot be told from it")


# ---- schedule and release ------------------------------------------------------------------------

def test_h2_a_schedule_session_stopped_early_fails(tmp_path):
    h, body = idle(tmp_path, stops={"schedule": 4000})
    v = judge(tmp_path, [h] + body)
    assert v["schedule"] == ("FAIL", "the process was gone 67.0 min after its first turn ended, before the end of the run (120.0 min), with the control stopped at 61.0 min after its own")


def test_h3_a_schedule_session_never_read_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, unread={"schedule": "all"})
    assert judge(tmp_path, [h] + body)["schedule"][0] == "INCONCLUSIVE"


def test_h4_a_run_cut_short_of_the_schedule_margin(tmp_path):
    h, body = idle(tmp_path, end=4500)
    v = judge(tmp_path, [h] + body)
    assert v["schedule"] == ("INCONCLUSIVE", "the run ended too soon to tell: the process was last seen 14.0 min after the control stopped, less than the 30.0 min margin (the poll record is at <results>/r.jsonl)")


def test_r2_a_completion_that_does_not_hold_fails(tmp_path):
    h, body = idle(tmp_path, stops={"release": 4620})
    v = judge(tmp_path, [h] + body)
    assert v["release"] == ("FAIL", "stopped 62.0 min after its completion turn ended (RELEASED, read from its transcript), against the control's 61.0 min: the delivered completion did not hold it past the idle stop")


def test_r3_a_release_stopped_with_no_completion_fails(tmp_path):
    h, body = idle(tmp_path, stops={"release": 3720}, words={"release": None})
    v = judge(tmp_path, [h] + body)
    assert v["release"] == ("FAIL", "stopped 62.0 min after its first turn ended with no completion turn in its transcript (no RELEASED): with no completion delivered, nothing held it")


def test_r4_a_release_never_read_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, unread={"release": "all"})
    assert judge(tmp_path, [h] + body)["release"] == ("INCONCLUSIVE", "its process state could not be read at any poll (the poll record is at <results>/r.jsonl)")


def test_r5_a_release_held_with_no_completion_is_inconclusive(tmp_path):
    h, body = idle(tmp_path, words={"release": None})
    v = judge(tmp_path, [h] + body)
    assert v["release"] == ("INCONCLUSIVE", "present at the end of the run, 120.0 min after its first turn, with no completion turn in its transcript (no RELEASED): what holds it is not a delivered completion (the poll record is at <results>/r.jsonl)")


def test_r6_a_run_cut_short_of_the_release_margin(tmp_path):
    h, body = idle(tmp_path, end=4500)
    v = judge(tmp_path, [h] + body)
    assert v["release"] == ("INCONCLUSIVE", "the run ended too soon to tell: last seen present 60.0 min after its completion turn ended, short of the control's idle duration plus the margin (the poll record is at <results>/r.jsonl)")


def test_an_arm_with_a_verdict_before_polling_keeps_it(tmp_path):
    pre = {"schedule": {"verdict": "SKIPPED", "reason": "no CronCreate tool was available"}}
    h, body = idle(tmp_path, pre=pre)
    v = judge(tmp_path, [h] + body)
    assert v["schedule"] == ("SKIPPED", "no CronCreate tool was available") and v["shell"][0] == "PASS"


# ---- decided: when the run may stop early ---------------------------------------------------------

def decided(tmp_path, lines):
    return classify.judge(str(write(tmp_path, lines))).decided()


def test_d1_nothing_is_decided_before_the_control_stops(tmp_path):
    h, body = idle(tmp_path, stops={"control": None}, end=7200)
    assert not decided(tmp_path, [h] + body[:-1])


@pytest.mark.parametrize("arm,stops,words,end,want", [
    # shell: decided by its stop, or once seen the control's idle plus the margin after its turn
    ("shell", {"shell": None}, {}, 5400, False),
    ("shell", {"shell": None}, {}, 5460, True),
    # turn: never decided on a run with no FIRED until it stops
    ("turn", {"turn": None}, {"turn": None}, 7200, False),
    ("turn", {"turn": None}, {}, 6300, False),
    ("turn", {"turn": None}, {}, 6360, True),
    # schedule: seen the margin after the control's stop
    ("schedule", {}, {}, 5400, False),
    ("schedule", {}, {}, 5460, True),
    # release: seen the control's idle plus the margin after its completion
    ("release", {}, {}, 6300, False),
    ("release", {}, {}, 6360, True),
])
def test_d2_to_d5_each_arm_is_decided_by_its_own_rule(tmp_path, arm, stops, words, end, want):
    watch = ["control", arm]
    h, body = idle(tmp_path, stops=stops, words=words, end=end, watch=watch)
    assert decided(tmp_path, [h] + body[:-1]) is want


def test_a_stopped_arm_is_decided(tmp_path):
    h, body = idle(tmp_path, stops={"shell": 3720}, end=3720, watch=["control", "shell"])
    assert decided(tmp_path, [h] + body[:-1])


# ---- completion-hold --------------------------------------------------------------------------------

def hold(tmp_path, release_stop=None, word=("RELEASED", 900.0), unread=None, end=28800, step=300):
    h = header("completion-hold", ["control", "release"], {"cap": "28800", "record": "r.jsonl"})
    body = rounds({"control": 3600, "release": release_stop}, end, start=300, step=step,
                  words={"release": word} if word else {}, unread=unread)
    return [h] + body + [{"kind": "end", "t": float(end)}]


def test_c1_a_release_never_read_is_inconclusive(tmp_path):
    assert judge(tmp_path, hold(tmp_path, unread={"release": "all"}))["release"][0] == "INCONCLUSIVE"


def test_c2_stopped_with_no_completion_is_inconclusive(tmp_path):
    v = judge(tmp_path, hold(tmp_path, release_stop=4200, word=None))
    assert v["release"] == ("INCONCLUSIVE", "stopped 70.0 min after its first turn ended with no completion turn in its transcript (no RELEASED), so it was never held by a delivered completion")


def test_c3_present_with_no_completion_is_inconclusive(tmp_path):
    v = judge(tmp_path, hold(tmp_path, word=None))
    assert v["release"] == ("INCONCLUSIVE", "no completion turn in its transcript (no RELEASED) by the end of the run, 480.0 min after its first turn, so it was never held by a delivered completion (the poll record is at <results>/r.jsonl)")


def test_c4_stopped_after_its_completion_passes(tmp_path):
    v = judge(tmp_path, hold(tmp_path, release_stop=10200))
    assert verdicts(v) == {"control": "PASS", "release": "PASS"}
    assert v["release"][1] == "stopped 155.0 min after its completion turn ended (RELEASED, read from its transcript 15.0 min after its first turn), within the 480.0 min cap; the control stopped 60.0 min after its own turn"


def test_c5_unreadable_at_the_end_after_its_completion_is_inconclusive(tmp_path):
    v = judge(tmp_path, hold(tmp_path, unread={"release": set(range(20100, 28801, 300))}))
    assert v["release"][0] == "INCONCLUSIVE" and "unreadable at the end of the run (last read, still present, 315.0 min after its completion turn ended)" in v["release"][1]


def test_c6_present_at_the_cap_fails(tmp_path):
    v = judge(tmp_path, hold(tmp_path))
    assert v["release"] == ("FAIL", "still present at the end of the 480.0 min cap, 465.0 min after its completion turn ended (RELEASED, read from its transcript): a session held by a delivered completion was not stopped (the control stopped 60.0 min after its own turn)")


def test_completion_hold_shares_the_control_branches(tmp_path):
    lines = hold(tmp_path)
    lines = [lines[0]] + [dict(r, arms=dict(r["arms"], control="running")) if r["kind"] == "round" else r for r in lines[1:]]
    v = judge(tmp_path, lines)
    assert verdicts(v) == {"control": "VOID", "release": "VOID"} and "at the end of the 28800s cap" in v["release"][1]


@pytest.mark.parametrize("stop,want", [(None, False), (10200, True)])
def test_completion_hold_is_decided_when_both_sessions_stopped(tmp_path, stop, want):
    assert decided(tmp_path, hold(tmp_path, release_stop=stop, end=10200)[:-1]) is want


# ---- attached-stop ------------------------------------------------------------------------------------

ATS_ARMS = ["control", "terminal", "agentview"]
CLEAN = [(0.4, "absent", 4, "no"), (2.4, "absent", 4, "no")]
CONFIRMED = classify.CONFIRMED


def ats(pre=None, stops=None, watches=None):
    pre, stops, watches = pre or {}, stops or {}, watches or {}
    lines = [{"kind": "header", "case": "attached-stop", "plant": None,
              "config": {"watch": "120", "record": "r.jsonl"},
              "arms": {a: {"pre": pre.get(a)} for a in ATS_ARMS}}]
    for a in ATS_ARMS:
        if a in pre:
            continue
        rc, base = stops.get(a, (0, 4))
        lines.append({"kind": "stop", "arm": a, "term_rc": rc, "term_out": "out\nline", "base": base, "plant_resume": None})
        if rc == 0:
            for el, p, t, l in watches.get(a, CLEAN):
                lines.append({"kind": "watch", "arm": a, "el": el, "process": p, "transcript": t, "listed": l})
    return lines + [{"kind": "end"}]


def test_a1_a_control_that_comes_back_voids_every_arm(tmp_path):
    v = judge(tmp_path, ats(watches={"control": [(0.4, "present", 4, "no"), (2.4, "absent", 4, "yes")]}))
    assert v == {a: ("VOID", "an unattached session came back after the stop too (a process for its session uuid (0.4 s after the stop); a listed row for its id or uuid (2.4 s after the stop);), so a respawn cannot be laid to attachment") for a in ATS_ARMS}


def test_a2_an_unmeasured_control_leaves_every_arm_inconclusive(tmp_path):
    v = judge(tmp_path, ats(pre={"control": {"verdict": "INCONCLUSIVE", "reason": "the first turn did not finish"}}))
    assert v["control"] == ("INCONCLUSIVE", "control: the first turn did not finish")
    assert v["terminal"] == ("INCONCLUSIVE", f"the control could not be measured, so a result here cannot be laid to attachment ({CONFIRMED})")


def test_a3_a_control_sign_never_read_leaves_every_arm_inconclusive(tmp_path):
    v = judge(tmp_path, ats(watches={"control": [(0.4, "absent", 4, "unreadable"), (2.4, "absent", 4, "unreadable")]}))
    assert v["control"] == ("INCONCLUSIVE", "the control's listing could not be read at any poll during its 120s watch, so a return could not be ruled out (r.jsonl)")
    assert v["agentview"][0] == "INCONCLUSIVE" and "the control could not be measured" in v["agentview"][1]


def test_a4_and_a8_the_pass_path(tmp_path):
    v = judge(tmp_path, ats())
    assert v["control"] == ("PASS", "nothing came back within 120s of the stop (process, transcript and listing each read): an unattached session stays stopped, as the fleet relies on")
    assert v["terminal"] == ("PASS", f"nothing came back within 120s of the stop (process, transcript and listing each read), as with the unattached control; {CONFIRMED}")


@pytest.mark.parametrize("pre,stop,want", [
    ({"terminal": {"verdict": "INCONCLUSIVE", "reason": "the person could not be asked to attach"}}, {}, "the person could not be asked to attach"),
    ({}, {"terminal": (1, None)}, "the process ended but `claude rm` failed, so a listed row would say nothing: out line"),
    ({}, {"terminal": (2, None)}, "the session could not be stopped as the fleet stops one: out line"),
])
def test_a5_an_attached_arm_unmeasured_before_or_at_its_stop(tmp_path, pre, stop, want):
    v = judge(tmp_path, ats(pre=pre, stops=stop))
    assert v["terminal"] == ("INCONCLUSIVE", want) and v["agentview"][0] == "PASS"


def test_a6_a_sign_of_return_fails_that_arm_only(tmp_path):
    v = judge(tmp_path, ats(watches={"terminal": [(0.6, "absent", 5, "no"), (2.6, "absent", 6, "no")]}))
    assert v["terminal"] == ("FAIL", f"the session came back after the stop: new lines in its transcript (0.6 s after the stop); while the control stayed stopped; {CONFIRMED}")
    assert v["control"][0] == "PASS" and v["agentview"][0] == "PASS"


def test_a7_an_attached_arm_sign_never_read_is_inconclusive_not_passed(tmp_path):
    v = judge(tmp_path, ats(watches={"agentview": [(0.4, "unreadable", 4, "no"), (2.4, "unreadable", 4, "no")]}))
    assert v["agentview"] == ("INCONCLUSIVE", "its process could not be read at any poll during the 120s watch, so a return could not be ruled out (r.jsonl)")


def test_a9_a_transcript_not_found_at_the_stop_is_inconclusive(tmp_path):
    v = judge(tmp_path, ats(stops={"terminal": (0, None)}))
    assert v["terminal"] == ("INCONCLUSIVE", "the transcript could not be found to count its lines at the stop")


# ---- the writer, through the command line the cases use --------------------------------------------

def run(*args):
    return subprocess.run([sys.executable, str(CLASSIFY), *map(str, args)], capture_output=True, text=True)


def test_the_writer_verbs_make_a_record_the_judge_reads(tmp_path):
    rec = tmp_path / "w.jsonl"
    assert run("header", rec, "--case", "completion-hold", "--arms", "control release", "--watch", "control release",
               "--config", "cap=28800", "--config", "record=w.jsonl", "--t-launch", "-30",
               "--turn-end", "control=0", "--turn-end", "release=0", "--pre", "control=", "--pre", "release=").returncode == 0
    assert run("round", rec, "--t", "300", "--read", "control=running", "--status", "control=idle",
               "--read", "release=running", "--word", "release=RELEASED@290.5").returncode == 0
    assert run("round", rec, "--t", "3900", "--read", "control=stopped", "--read", "release=unreadable",
               "--note", "release=pid record unreadable: x").returncode == 0
    assert run("round", rec, "--t", "4200", "--read", "control=stopped", "--read", "release=stopped").returncode == 0
    assert run("decided", rec).returncode == 0
    assert run("end", rec, "--t", "4200").returncode == 0
    r = run("verdicts", rec)
    assert r.returncode == 0, r.stderr
    got = [line.split("\t") for line in r.stdout.splitlines()]
    assert [g[:2] for g in got] == [["control", "PASS"], ["release", "PASS"]]
    assert "RELEASED, read from its transcript 4.8 min after its first turn" in got[1][2]
    lines = [json.loads(x) for x in rec.read_text().splitlines()]
    assert lines[1]["words"] == {"release": {"word": "RELEASED", "at": 290.5}} and lines[2]["notes"] == {"release": "pid record unreadable: x"}


def test_the_attached_writer_verbs(tmp_path):
    rec = tmp_path / "a.jsonl"
    assert run("header", rec, "--case", "attached-stop", "--arms", "control terminal agentview", "--config", "watch=2",
               "--config", "record=a.jsonl", "--pre", "control=", "--pre", "terminal=",
               "--pre", "agentview=INCONCLUSIVE|the person could not be asked").returncode == 0
    for a in ("control", "terminal"):
        assert run("stop", rec, "--arm", a, "--rc", "0", "--out", "stopped", "--base", "4", "--resume", "0@resumed").returncode == 0
        assert run("watch", rec, "--arm", a, "--el", "0.4", "--process", "absent", "--transcript",
                   "5" if a == "terminal" else "4", "--listed", "no").returncode == 0
    assert run("end", rec).returncode == 0
    got = {line.split("\t")[0]: line.split("\t")[1] for line in run("verdicts", rec).stdout.splitlines()}
    assert got == {"control": "PASS", "terminal": "FAIL", "agentview": "INCONCLUSIVE"}


@pytest.mark.parametrize("args,needle", [
    (["round", "--t", "1", "--read", "control=gone"], "a reading is running, stopped or unreadable"),
    (["header", "--case", "idle-holders"], "header needs --case and --arms"),
    (["header", "--case", "x", "--arms", "a", "--pre", "a=NOBAR"], "a pre verdict is VERDICT|REASON"),
    (["round", "--t", "1", "--word", "turn=FIRED"], "--word is ARM=WORD@T"),
])
def test_a_malformed_write_is_a_usage_error(tmp_path, args, needle):
    r = run(args[0], tmp_path / "x.jsonl", *args[1:])
    assert r.returncode == 2 and needle in r.stderr


@pytest.mark.parametrize("content,needle", [
    ("", "has no header line"),
    ('{"kind": "round"}\n', "has no header line"),
    ('{"kind": "header", "case": "nope", "arms": {}, "config": {}}\n', "unknown case"),
    ("{not json\n", "cannot be read"),
])
def test_an_unusable_record_is_refused_not_judged(tmp_path, content, needle):
    p = tmp_path / "bad.jsonl"
    p.write_text(content)
    r = run("verdicts", p)
    assert r.returncode == 2 and needle in r.stderr and r.stdout == ""


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", *sys.argv[1:]]))
