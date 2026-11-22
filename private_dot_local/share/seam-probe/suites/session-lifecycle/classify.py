"""classify.py -- the session-lifecycle cases' record, and the verdicts judged from it.

Each case that watches sessions over time (idle-holders, completion-hold, attached-stop) gathers
what it sees into one JSONL record in the run's results directory, through this file's writer verbs,
and decides nothing itself. The verdicts are a pure function of that record: this file reads no
clock, starts no process and looks at nothing else, so a test can judge any timeline by writing the
record it would produce, with no wall clock for the machine's load to move. Each case declares this
file in suite.toml's `helpers`, so a change here retires the seen-red records of every case that
uses it, as a change to its own script does.

    python3 classify.py header  RECORD --case C [--plant P] --arms "A B .." [--watch "A .."]
                                [--config K=V].. [--t-launch T] [--turn-end ARM=T]..
                                [--pre ARM=VERDICT|REASON]..
    python3 classify.py round   RECORD --t T [--read ARM=running|stopped|unreadable]..
                                [--status ARM=WORD].. [--note ARM=TEXT].. [--word ARM=WORD@T]..
    python3 classify.py stop    RECORD --arm A --rc N --out TEXT [--base N] [--resume RC@TEXT]
    python3 classify.py watch   RECORD --arm A --el S --process present|absent|unreadable
                                --transcript N|unreadable --listed yes|no|unreadable
    python3 classify.py end     RECORD [--t T]
    python3 classify.py verdicts RECORD     one line per arm: ARM<TAB>VERDICT<TAB>REASON
    python3 classify.py decided  RECORD     exit 0 when every watched arm is decided, else 1

THE RECORD. One JSON object per line; times are epoch seconds. The idle cases write a `header`
once their holders are read (each arm's first-turn end, read from its transcript, and any verdict
decided before polling, its `pre`), then one `round` per poll, then `end`. attached-stop writes a
`header`, then per arm a `stop` and its `watch` lines, then `end`. Config values are kept as the
strings the case was given, because some reasons print them as given (`the 60s cap`).

DERIVED STATE, as the cases' poll loop has always set it: an arm's `seen` is the last round that
found it running; `stop`, the first that found it gone (later rounds say stopped without looking);
`read`, whether any round read it running or stopped; `last`, the latest of running or unreadable.
A stop is timed only when a round saw the arm present at or after its reference turn (`sighted`):
gone at the first look, it stopped at some time before then.

Exit status: 0, or 1 for `decided` when an arm is undecided; 2 for a usage error or an unreadable
record, with the reason on stderr.
"""
import json
import sys

ORDER_IDLE = {"idle-holders": ["control", "shell", "turn", "schedule", "release"],
              "completion-hold": ["control", "release"]}


class Bad(Exception):
    pass


# ---- the writer -----------------------------------------------------------------------------------

def pairs(values, what):
    out = {}
    for v in values:
        if "=" not in v:
            raise Bad(f"{what} needs ARM=VALUE, not {v!r}")
        k, _, x = v.partition("=")
        out[k] = x
    return out


def opts(argv, single, multi):
    """Parse --name VALUE pairs: SINGLE names once, MULTI names any number of times."""
    got = {k: None for k in single}
    got.update({k: [] for k in multi})
    i = 0
    while i < len(argv):
        k = argv[i]
        if not k.startswith("--") or i + 1 >= len(argv):
            raise Bad(f"expected --option VALUE at {k!r}")
        name = k[2:]
        if name in single:
            got[name] = argv[i + 1]
        elif name in multi:
            got[name].append(argv[i + 1])
        else:
            raise Bad(f"unknown option {k}")
        i += 2
    return got


def split_pre(text):
    v, sep, r = text.partition("|")
    if not sep or not v:
        raise Bad(f"a pre verdict is VERDICT|REASON, not {text!r}")
    return {"verdict": v, "reason": r}


def append(path, obj):
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")


def w_header(path, argv):
    o = opts(argv, ["case", "plant", "arms", "watch", "t-launch"], ["config", "turn-end", "pre"])
    if not o["case"] or not o["arms"]:
        raise Bad("header needs --case and --arms")
    ends = {k: float(v) for k, v in pairs(o["turn-end"], "--turn-end").items() if v}
    pres = {k: split_pre(v) for k, v in pairs(o["pre"], "--pre").items() if v}
    arms = {a: {"turn_end": ends.get(a), "pre": pres.get(a)} for a in o["arms"].split()}
    append(path, {"kind": "header", "case": o["case"], "plant": o["plant"] or None,
                  "config": pairs(o["config"], "--config"),
                  "t_launch": float(o["t-launch"]) if o["t-launch"] else None,
                  "arms": arms, "watch": (o["watch"] or "").split()})


def w_round(path, argv):
    o = opts(argv, ["t"], ["read", "status", "note", "word"])
    if o["t"] is None:
        raise Bad("round needs --t")
    words = {}
    for a, v in pairs(o["word"], "--word").items():
        w, sep, t = v.rpartition("@")
        if not sep:
            raise Bad(f"--word is ARM=WORD@T, not {a}={v}")
        words[a] = {"word": w, "at": float(t)}
    reads = pairs(o["read"], "--read")
    for a, st in reads.items():
        if st not in ("running", "stopped", "unreadable"):
            raise Bad(f"--read {a}={st}: a reading is running, stopped or unreadable")
    append(path, {"kind": "round", "t": float(o["t"]), "arms": reads,
                  "status": pairs(o["status"], "--status"), "notes": pairs(o["note"], "--note"),
                  "words": words})


def w_stop(path, argv):
    o = opts(argv, ["arm", "rc", "out", "base", "resume"], [])
    if not o["arm"] or o["rc"] is None:
        raise Bad("stop needs --arm and --rc")
    resume = None
    if o["resume"] is not None:
        rc, _, out = o["resume"].partition("@")
        resume = {"rc": int(rc), "out": out}
    append(path, {"kind": "stop", "arm": o["arm"], "term_rc": int(o["rc"]), "term_out": o["out"] or "",
                  "base": int(o["base"]) if o["base"] else None, "plant_resume": resume})


def w_watch(path, argv):
    o = opts(argv, ["arm", "el", "process", "transcript", "listed"], [])
    if not o["arm"] or o["el"] is None:
        raise Bad("watch needs --arm and --el")
    tr = o["transcript"]
    append(path, {"kind": "watch", "arm": o["arm"], "el": float(o["el"]), "process": o["process"],
                  "transcript": int(tr) if tr not in (None, "", "unreadable") else "unreadable",
                  "listed": o["listed"]})


def w_end(path, argv):
    o = opts(argv, ["t"], [])
    append(path, {"kind": "end", "t": float(o["t"]) if o["t"] else None})


# ---- reading the record ---------------------------------------------------------------------------

def load(path):
    try:
        lines = [json.loads(x) for x in open(path).read().splitlines() if x.strip()]
    except (OSError, ValueError) as e:
        raise Bad(f"the record {path} cannot be read: {e}")
    if not lines or lines[0].get("kind") != "header":
        raise Bad(f"the record {path} has no header line")
    return lines[0], lines[1:]


def minutes(s):
    return "%.1f" % (s / 60)


def mins_between(a, b):
    return minutes(a - b)


def oneline(s):
    return s.replace("\n", " ")[:300]


class Arm:
    """One arm's state, derived from the rounds as the poll loop has always set it."""

    def __init__(self, name, rounds):
        self.seen = self.stop = None
        self.read = False
        self.last = None
        self.words = {}
        for r in rounds:
            st = r["arms"].get(name)
            if st == "running":
                self.seen, self.read, self.last = r["t"], True, "running"
            elif st == "stopped":
                if self.stop is None:
                    self.stop = r["t"]
                self.read = True
            elif st == "unreadable":
                self.last = "unreadable"
            w = r.get("words", {}).get(name)
            if w and w["word"] not in self.words:
                self.words[w["word"]] = w["at"]

    def sighted(self, ref):
        return self.seen is not None and self.seen - ref >= 0

    def seen_past(self, ref, *secs):
        return self.seen is not None and self.seen - ref >= sum(secs)


# ---- the idle cases -------------------------------------------------------------------------------

class Idle:
    def __init__(self, header, body):
        self.h = header
        self.case = header["case"]
        self.arms = list(header["arms"])
        self.rounds = [x for x in body if x.get("kind") == "round"]
        ends = [x for x in body if x.get("kind") == "end"]
        self.t_end = ends[-1]["t"] if ends and ends[-1].get("t") is not None else \
            (self.rounds[-1]["t"] if self.rounds else None)
        c = header["config"]
        self.cap_raw = c.get("cap", "")
        self.cap = float(c["cap"]) if c.get("cap") else 0.0
        self.tolerance = float(c.get("tolerance") or 0)
        self.margin = float(c.get("margin") or 0)
        self.turn_due = float(c["turn_due"]) if c.get("turn_due") else None
        self.where = f"the poll record is at <results>/{c.get('record', 'the record')}"
        self.st = {a: Arm(a, self.rounds) for a in self.arms}

    def end(self, a):
        return self.h["arms"][a]["turn_end"]

    def pre(self, a):
        return self.h["arms"][a]["pre"]

    def all(self, v, r):
        return [(a, v, r) for a in self.arms]

    # The control's verdict: every arm's when it cannot be used, else PASS and its idle duration.
    def control(self):
        p = self.pre("control")
        if p:
            return self.all(p["verdict"], "control: " + p["reason"]), None
        c, end = self.st["control"], self.end("control")
        if c.stop is None:
            if not c.read:
                return self.all("INCONCLUSIVE", f"the control's process state could not be read at any poll ({self.where})"), None
            if c.last == "unreadable":
                return self.all("INCONCLUSIVE", f"the control's process state was unreadable at the end of the run (last read, still present, {mins_between(c.seen, end)} min after its turn ended), so a stop could not be seen ({self.where})"), None
            return self.all("VOID", f"the control was never stopped, so the idle stop was not observed (an attached client such as an open agent view, or a changed idle duration): its process was still present {mins_between(c.seen, end)} min after its turn ended, at the end of the {self.cap_raw}s cap"), None
        cidle = c.stop - end
        cmin = minutes(cidle)
        if not c.sighted(end):
            return self.all("INCONCLUSIVE", f"the control was already gone at the first look, {cmin} min after its turn ended, so it stopped at some time before then and its idle duration was not measured ({self.where})"), None
        return [("control", "PASS", f"the idle stop was observed: no process {cmin} min after its turn ended")], (c.stop, cidle, cmin)

    # An arm whose claim is that nothing holds it: stopped about the control's idle duration after REF.
    def idle_like(self, a, ref, what, cidle, cmin):
        s, tmin, mmin = self.st[a], minutes(self.tolerance), minutes(self.margin)
        if s.seen_past(ref, cidle, self.margin):
            later = f" (stopped later, {mins_between(s.stop, ref)} min after it)" if s.stop is not None else ""
            return "FAIL", f"still present {mins_between(s.seen, ref)} min after {what}, past the control's idle duration ({cmin} min) by at least the {mmin} min margin{later}"
        if s.stop is not None:
            d = s.stop - ref
            diff = d - cidle
            if not s.sighted(ref):
                # Gone at the first look after REF: it stopped at some time up to d, so only "sooner"
                # can be read, and only when even d is sooner by more than the tolerance.
                if not self.tolerance >= cidle - d:
                    return "INCONCLUSIVE", f"stopped at most {minutes(d)} min after {what} (gone at the first look), sooner than the control's {cmin} min by more than the {tmin} min tolerance: not the idle stop the control showed"
                return "INCONCLUSIVE", f"already gone at the first look, {minutes(d)} min after {what}, so it stopped at some time before then, which cannot be compared with the control's {cmin} min ({self.where})"
            if self.tolerance >= abs(diff):
                return "PASS", f"stopped {minutes(d)} min after {what}, against the control's {cmin} min after its own: within the {tmin} min tolerance"
            if 0 >= diff:
                return "INCONCLUSIVE", f"stopped {minutes(d)} min after {what}, sooner than the control's {cmin} min by more than the {tmin} min tolerance: not the idle stop the control showed"
            return "INCONCLUSIVE", f"stopped {minutes(d)} min after {what}, later than the control's {cmin} min by more than the {tmin} min tolerance but within the {mmin} min margin: something held it a while, and this case does not read what"
        if not s.read:
            return "INCONCLUSIVE", f"its process state could not be read at any poll ({self.where})"
        return "INCONCLUSIVE", f"the run ended too soon to tell: last seen present {mins_between(s.seen, ref)} min after {what}, short of the control's idle duration plus the margin ({self.where})"

    def verdicts(self):
        out, ctl = self.control()
        if ctl is None:
            return out
        cs, cidle, cmin = ctl
        for a in self.arms[1:]:
            p = self.pre(a)
            if p:
                out.append((a, p["verdict"], p["reason"]))
                continue
            out.append((a,) + getattr(self, "v_" + self.case.replace("-", "_") + "_" + a)(cs, cidle, cmin))
        return out

    def v_idle_holders_shell(self, cs, cidle, cmin):
        return self.idle_like("shell", self.end("shell"), "its first turn ended", cidle, cmin)

    def v_idle_holders_turn(self, cs, cidle, cmin):
        ft, end = self.st["turn"].words.get("FIRED"), self.end("turn")
        if ft is None:
            return "INCONCLUSIVE", f"its job's turn was never seen (no FIRED in its transcript by the end of the run, {mins_between(self.t_end, end)} min after its first turn), so there is no turn to time a stop from ({self.where})"
        if self.turn_due is not None and not ft >= self.turn_due:
            return "INCONCLUSIVE", f"FIRED was seen {mins_between(self.turn_due, ft)} min before its job was due, so another turn wrote it and the job's own turn cannot be told from it"
        return self.idle_like("turn", ft, f"its job's turn ended (FIRED, read from its transcript {mins_between(ft, end)} min after its first turn)", cidle, cmin)

    def v_idle_holders_schedule(self, cs, cidle, cmin):
        s, end, mmin = self.st["schedule"], self.end("schedule"), minutes(self.margin)
        if s.seen_past(cs, self.margin):
            return "PASS", f"the process was still present {mins_between(s.seen, end)} min after its first turn ended, {mins_between(s.seen, cs)} min after the control stopped (at {cmin} min after its own turn), a margin of at least {mmin} min"
        if s.stop is not None:
            return "FAIL", f"the process was gone {mins_between(s.stop, end)} min after its first turn ended, before the end of the run ({mins_between(self.t_end, end)} min), with the control stopped at {cmin} min after its own"
        if not s.read:
            return "INCONCLUSIVE", f"its process state could not be read at any poll ({self.where})"
        return "INCONCLUSIVE", f"the run ended too soon to tell: the process was last seen {mins_between(s.seen, cs)} min after the control stopped, less than the {mmin} min margin ({self.where})"

    def v_idle_holders_release(self, cs, cidle, cmin):
        s, end, mmin = self.st["release"], self.end("release"), minutes(self.margin)
        rd = s.words.get("RELEASED")
        if rd is not None and s.seen_past(rd, cidle, self.margin):
            return "PASS", f"still present {mins_between(s.seen, rd)} min after its completion turn ended (RELEASED, read from its transcript {mins_between(rd, end)} min after its first turn), past the control's idle duration ({cmin} min) by at least the {mmin} min margin: the delivered completion held it"
        if s.stop is not None:
            if rd is not None:
                return "FAIL", f"stopped {mins_between(s.stop, rd)} min after its completion turn ended (RELEASED, read from its transcript), against the control's {cmin} min: the delivered completion did not hold it past the idle stop"
            return "FAIL", f"stopped {mins_between(s.stop, end)} min after its first turn ended with no completion turn in its transcript (no RELEASED): with no completion delivered, nothing held it"
        if not s.read:
            return "INCONCLUSIVE", f"its process state could not be read at any poll ({self.where})"
        if rd is None:
            return "INCONCLUSIVE", f"present at the end of the run, {mins_between(s.seen, end)} min after its first turn, with no completion turn in its transcript (no RELEASED): what holds it is not a delivered completion ({self.where})"
        return "INCONCLUSIVE", f"the run ended too soon to tell: last seen present {mins_between(s.seen, rd)} min after its completion turn ended, short of the control's idle duration plus the margin ({self.where})"

    def v_completion_hold_release(self, cs, cidle, cmin):
        s, end = self.st["release"], self.end("release")
        rd = s.words.get("RELEASED")
        if not s.read:
            return "INCONCLUSIVE", f"its process state could not be read at any poll ({self.where})"
        if rd is None:
            if s.stop is not None:
                return "INCONCLUSIVE", f"stopped {mins_between(s.stop, end)} min after its first turn ended with no completion turn in its transcript (no RELEASED), so it was never held by a delivered completion"
            return "INCONCLUSIVE", f"no completion turn in its transcript (no RELEASED) by the end of the run, {mins_between(self.t_end, end)} min after its first turn, so it was never held by a delivered completion ({self.where})"
        if s.stop is not None:
            return "PASS", f"stopped {mins_between(s.stop, rd)} min after its completion turn ended (RELEASED, read from its transcript {mins_between(rd, end)} min after its first turn), within the {minutes(self.cap)} min cap; the control stopped {cmin} min after its own turn"
        if s.last == "unreadable":
            return "INCONCLUSIVE", f"its process state was unreadable at the end of the run (last read, still present, {mins_between(s.seen, rd)} min after its completion turn ended), so a stop could not be seen ({self.where})"
        return "FAIL", f"still present at the end of the {minutes(self.cap)} min cap, {mins_between(s.seen, rd)} min after its completion turn ended (RELEASED, read from its transcript): a session held by a delivered completion was not stopped (the control stopped {cmin} min after its own turn)"

    # Is every watched arm decided, so the run need not wait on it? Never before the control stopped
    # in idle-holders; in completion-hold, every watched arm stopped.
    def decided(self):
        watch = self.h.get("watch") or []
        if self.case == "completion-hold":
            return all(self.st[a].stop is not None for a in watch)
        c = self.st["control"]
        if c.stop is None:
            return False
        cs, cidle = c.stop, c.stop - self.end("control")
        for a in watch:
            s = self.st[a]
            if s.stop is not None:
                continue
            if a == "shell":
                ok = s.seen_past(self.end("shell"), cidle, self.margin)
            elif a == "turn":
                ft = s.words.get("FIRED")
                ok = ft is not None and s.seen_past(ft, cidle, self.margin)
            elif a == "schedule":
                ok = s.seen_past(cs, self.margin)
            elif a == "release":
                rd = s.words.get("RELEASED")
                ok = rd is not None and s.seen_past(rd, cidle, self.margin)
            else:
                ok = False
            if not ok:
                return False
        return True


# ---- attached-stop --------------------------------------------------------------------------------

CONFIRMED = "the attachment was made and confirmed by the person at the terminal, not observed by the instrument, and the client's own display was not read"


class Attached:
    def __init__(self, header, body):
        self.h = header
        self.arms = list(header["arms"])
        self.watch = header["config"].get("watch", "")
        self.record = header["config"].get("record", "the record")
        self.pre = {a: header["arms"][a].get("pre") for a in self.arms}
        self.signs = {}
        for a in self.arms:
            stops = [x for x in body if x.get("kind") == "stop" and x["arm"] == a]
            if not stops or self.pre[a]:
                self.signs[a] = None
                continue
            s = stops[0]
            if s["term_rc"] == 1:
                self.pre[a] = {"verdict": "INCONCLUSIVE", "reason": f"the process ended but `claude rm` failed, so a listed row would say nothing: {oneline(s['term_out'])}"}
            elif s["term_rc"] != 0:
                self.pre[a] = {"verdict": "INCONCLUSIVE", "reason": f"the session could not be stopped as the fleet stops one: {oneline(s['term_out'])}"}
            if s["term_rc"] != 0:
                self.signs[a] = None
                continue
            base = s["base"]
            if base is None:
                self.pre[a] = {"verdict": "INCONCLUSIVE", "reason": "the transcript could not be found to count its lines at the stop"}
            proc = tr = row = None
            ok_p = ok_t = ok_r = False
            for w in (x for x in body if x.get("kind") == "watch" and x["arm"] == a):
                el = "%.1f" % w["el"]
                if w["process"] == "present":
                    proc = proc or el
                    ok_p = True
                elif w["process"] == "absent":
                    ok_p = True
                n = w["transcript"]
                if n != "unreadable" and base is not None:
                    ok_t = True
                    if n > base:
                        tr = tr or el
                if w["listed"] == "yes":
                    row = row or el
                    ok_r = True
                elif w["listed"] == "no":
                    ok_r = True
            noread = " ".join(k for k, ok in (("process", ok_p), ("transcript", ok_t), ("listing", ok_r)) if not ok)
            self.signs[a] = {"proc": proc, "tr": tr, "row": row, "noread": noread}

    def came(self, a):
        s, t = self.signs[a], ""
        if s["proc"]:
            t += f" a process for its session uuid ({s['proc']} s after the stop);"
        if s["tr"]:
            t += f" new lines in its transcript ({s['tr']} s after the stop);"
        if s["row"]:
            t += f" a listed row for its id or uuid ({s['row']} s after the stop);"
        return t.lstrip(" ")

    def has_sign(self, a):
        s = self.signs.get(a)
        return bool(s and (s["proc"] or s["tr"] or s["row"]))

    def unread(self, a):
        s = self.signs.get(a)
        return s["noread"] if s else ""

    def verdicts(self):
        out = []
        state = "ok"
        if self.pre["control"]:
            state = "unmeasured"
        elif self.has_sign("control"):
            return [(a, "VOID", f"an unattached session came back after the stop too ({self.came('control')}), so a respawn cannot be laid to attachment") for a in self.arms]
        if state == "unmeasured":
            p = self.pre["control"]
            out.append(("control", p["verdict"], "control: " + p["reason"]))
        elif self.unread("control"):
            out.append(("control", "INCONCLUSIVE", f"the control's {self.unread('control')} could not be read at any poll during its {self.watch}s watch, so a return could not be ruled out ({self.record})"))
            state = "unmeasured"
        else:
            out.append(("control", "PASS", f"nothing came back within {self.watch}s of the stop (process, transcript and listing each read): an unattached session stays stopped, as the fleet relies on"))
        for a in self.arms[1:]:
            p = self.pre[a]
            if p:
                out.append((a, p["verdict"], p["reason"]))
            elif state != "ok":
                out.append((a, "INCONCLUSIVE", f"the control could not be measured, so a result here cannot be laid to attachment ({CONFIRMED})"))
            elif self.has_sign(a):
                out.append((a, "FAIL", f"the session came back after the stop: {self.came(a)} while the control stayed stopped; {CONFIRMED}"))
            elif self.unread(a):
                out.append((a, "INCONCLUSIVE", f"its {self.unread(a)} could not be read at any poll during the {self.watch}s watch, so a return could not be ruled out ({self.record})"))
            else:
                out.append((a, "PASS", f"nothing came back within {self.watch}s of the stop (process, transcript and listing each read), as with the unattached control; {CONFIRMED}"))
        return out


def judge(path):
    header, body = load(path)
    case = header.get("case")
    if case in ORDER_IDLE:
        return Idle(header, body)
    if case == "attached-stop":
        return Attached(header, body)
    raise Bad(f"the record {path} is for an unknown case {case!r}")


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    verb, path, rest = argv[0], argv[1], argv[2:]
    try:
        writers = {"header": w_header, "round": w_round, "stop": w_stop, "watch": w_watch, "end": w_end}
        if verb in writers:
            writers[verb](path, rest)
            return 0
        if verb == "verdicts":
            for a, v, r in judge(path).verdicts():
                print(f"{a}\t{v}\t{r}")
            return 0
        if verb == "decided":
            j = judge(path)
            if not isinstance(j, Idle):
                raise Bad("decided is for the idle cases")
            return 0 if j.decided() else 1
        raise Bad(f"unknown verb {verb!r}")
    except Bad as e:
        print(f"classify.py {verb}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
