# fault-isolation — skill spec

What this skill is for and how to tell whether it works. Claude Code loads only `SKILL.md`, so this
file costs no context. Test runs and their results are logged by whoever maintains the skill, not
here; this file says what a run must show.

## Purpose

Stop a session from diagnosing a slow, broken or unreachable system at the wrong layer, and from
drawing a confident conclusion from a place that cannot see the fault. The incidents behind it: two
long-uptime devices (an access point and a server, each about seven weeks up) presented as "the
internet is slow" and "the website is slow" and were chased elsewhere first; a flaky wireless link
ran at 0% packet loss while its latency burst past two seconds; and agent sessions concluded a
service or host was down when their own sandbox had no route to it, or when a server started in one
command was unreachable from the next.

## Placement and where it applies

- **Placement:** hybrid. The public base carries the method; a private fragment
  (`~/.dotlocal/skills/fault-isolation.md`) carries one domain's hosts, links and dated incidents.
- **Applies:** every domain. The ladder's commands are Linux spellings (`systemctl`, `ip`); on macOS
  the rungs hold and the commands differ. The agent-sandbox facts are about Claude Code's Linux
  sandbox (bubblewrap).

## Effect claims

| Id | Claim | Graded on |
| --- | --- | --- |
| `host-rung` | Told a site became slow with no code change, the session checks the host (uptime, failed units, full filesystems) rather than going straight to the code | the session's actions |
| `serve` | Asked to start a server and confirm it serves, the session starts and probes it in one command (in the agent sandbox each command has its own network namespace) and reports the real status | the session's actions and its final answer |
| `loss` | Given a ping log with 0% loss and latency bursts past a second on a ~3 ms baseline, the session calls the link unhealthy | the end state: a verdict file |
| `cron-path` | Told a scheduled job cannot find a command that works by hand, the session fixes the job's environment (an absolute path, or a PATH that includes the command's directory) | the end state: the job's script and crontab |

**Not measured yet, with the reason:** "says which rungs are blind from where it stands, instead of
concluding". Grading that needs a judge model calibrated on planted answers, which this pilot has
not built.

## Should-fire situations

- A site that was fast yesterday takes about ten seconds per page today, with no code change.
- `git push` keeps timing out from this machine, though it worked an hour ago.
- A dev server started in an earlier command answers `curl` with "connection refused".
- A Lighthouse performance score dropped from 95 to 70 overnight with no code change.
- `ssh` to a build server hangs before asking for anything: server or network?
- Wi-Fi drops out for seconds at a time, but speed tests are fine and there is no packet loss.
- `npm install` fails with ETIMEDOUT while a browser reaches the registry fine.
- A nightly job fails with "command not found" for a tool that runs fine by hand.

## Near-misses

None should invoke the skill.

- Fix a function that returns the wrong total when a discount is passed.
- Make a test suite run faster.
- Write a script that pings a list of hosts and prints which did not answer.
- Explain the difference between a connection timeout and a connection refused, in two sentences.
- Add a retry with backoff to a fetch call.

## Failure signature

- A layer named as the cause before any cheaper rung was checked, or without a discriminator: a
  reading that could not have changed which layer is at fault.
- A loss figure or a mean latency taken as proof a link is healthy.
- "Down" or "unreachable" concluded from inside the agent sandbox, which has no route past the host.
- A green result after a restart reported as "fixed".

## Success measure

Written before the first effect run (2026-10-04), so a result cannot move it.

- **Reached for:** on Opus 5.5, at least 80% of should-fire trials and at most 20% of near-miss
  trials invoke the skill, at three trials per prompt, and a copy with a generic description of the
  same length fires clearly less. Where the live skill listing shows this skill by name only (the
  listing has a size budget ranked by past use), the second arm shows the description instead. Also
  run on Opus 4.8 and Sonnet 5, the models used at work, as floors.
- **Effect, per claim:** first, 5 trials with the skill removed. If all 5 pass, the claim cannot
  show an effect and its text is a candidate to cut from the body. Otherwise, 10 trials with the
  skill as deployed against 10 without, started together. The claim holds when the deployed arm passes
  more often, with Fisher's exact test one-sided p < 0.05. Split the deployed arm by whether the
  session invoked the skill: a body can work while the listing keeps sessions from reaching it.
- **Field:** invocations against sessions that hit a timeout, a refused connection, an unreachable
  host or a "slow" report, counted from session transcripts at each periodic review. The first count,
  over September 2026, was zero against the network failures the skill was written for. Any
  invocation is progress; continued zero is a finding.

## Test cases

The prompts, fixtures and graders live with the private test harness until the pilot of this spec
format is complete; they move into this directory then.
