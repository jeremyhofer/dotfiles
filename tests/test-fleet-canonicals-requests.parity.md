# Parity: test-fleet-canonicals-requests.py against the shell suite it replaced

`test-fleet-canonicals-requests.py` replaced `test-fleet-canonicals-requests.sh` (927 lines of zsh).
This table is the review record of that port: each check the shell suite made, by its label (the
message of its `ok`/`bad` pair, or the label argument of its `expect`), and the collected pytest id
that now makes it. The shell suite is in this repository's history at the commit before its deletion;
the line numbers are its.

**How it was checked.** The labels were extracted from the shell suite by script (every `ok "..."`
and every `expect ID OUTCOME CHECK "..."`, plus the one bare `bad` that guards a fixture), a label
written with a shell variable expanded to one row per value it took (`request refuses verb '$v'` three
times, `request refuses $flag` twice, `resume of a listed '$st' row` three times). Each label is kept
in the pytest suite as the message of the assertion that replaced it, and a second script found, for
each, the test function whose body holds it; that is the id below. Every id was in `pytest
--collect-only` output when the table was written. No check was removed: 205 checks, 205 rows (the
fixture guard at line 368 is one row naming the two tests that build that fixture).

**What changed in the port**, besides the harness the suite's docstring describes:

- The cases run in parallel (pytest-xdist) and most run the queue in-process, so the shell suite's
  two minutes become about twenty seconds. The real `fleet-canonicals` verbs (`up`, `down`,
  `refresh`), `fleet-decl`, `hostname` and the `claude` stub are still processes, as the runner
  starts them.
- `test-fleet-canonicals-requests.sh:351`, "refused requests and actions over an hour old do not
  count", could not fail on its second half: beta had ONE old action, under the per-canonical limit
  of 3, so a runner that counted actions of any age passed. The port gives beta three old actions,
  and mutant `rate-hour` is caught by it.
- The waiting-request check (`:448`) slept one real second so that `since` could differ; the port
  advances the runner's clock instead.
- The respawn that brings no process up (`:698`) waited out `FLEET_RESPAWN_WAIT=4`; the port sets
  the wait to 0, since the check is that the failure is reported, not how long the runner waited. The
  refresh that finds a live process still holding the name (`:552`) waits out a fixed fifteen
  iterations of `sleep 1` in `fleet-canonicals`; that case runs with a `sleep` that returns at once.
- The shell suite's `keep-alive` check has no case, and the port has none: `keepalive_holds` returns
  an empty list until the deferred keep-alive verb exists, so the check cannot fire and has no mutant.

**New in the port, with no shell counterpart:** the tests `test_serve_age_refuses_a_request_dated_in_the_future`
(a request dated an hour ahead), `test_serve_rate_per_canonical_two_actions_are_under_the_limit` (the
boundary under the limit, so a runner refusing one action early is caught),
`test_serve_snapshot_unknown_seat_may_still_be_stopped` (control for the starting-verbs-only clause),
and `test_contract_serve_requests_prints_one_line_per_request`; within existing tests, a name with a
space (`r-space`) and a request whose `time` is a string (`r-time`) for the shape and verb checks, a
control for each of "request requires --reason", "--as cannot contradict the calling session" and
"request refuses a second request", and the failure text of a resume with no listed session. The
mutant meta-tests (`test_mutant_*`, one per row of `MUTANTS`) run in the landing lane only.

## test-fleet-canonicals-requests.sh (205 checks)

| Line | Label | pytest id |
| --- | --- | --- |
| 193 | request queues one file | `test_request_queues_one_file` |
| 195 | the request records verb, name, requester and reason | `test_request_queues_one_file` |
| 196 | the request records when it was written | `test_request_queues_one_file` |
| 198 | request leaves no temp file behind (written then renamed) | `test_request_queues_one_file` |
| 204 | request refuses verb 'dedupe' | `test_request_refuses_verb[dedupe]` |
| 204 | request refuses verb 'clean' | `test_request_refuses_verb[clean]` |
| 204 | request refuses verb 'place' | `test_request_refuses_verb[place]` |
| 209 | request refuses --force | `test_request_refuses_flag[--force]` |
| 209 | request refuses --stub | `test_request_refuses_flag[--stub]` |
| 212 | request refuses a canonical declared for another machine | `test_request_refuses_a_canonical_declared_for_another_machine` |
| 215 | request refuses an undeclared name | `test_request_refuses_an_undeclared_name` |
| 217 | request requires --reason | `test_request_requires_a_reason` |
| 219 | request refuses when the requester cannot be told and --as is absent | `test_request_without_a_requester_is_refused` |
| 225 | request refuses a never-touch canonical (the default list), and nothing lands | `test_request_never_touch_default` |
| 228 | the never-touch list is the config's when the key is set | `test_request_never_touch_configured` |
| 230 | request refuses a configured never-touch name | `test_request_never_touch_configured` |
| 239 | request records the calling session's canonical name as the requester | `test_request_records_the_calling_sessions_name` |
| 242 | --as cannot name someone other than the calling session | `test_request_as_cannot_contradict_the_calling_session` |
| 247 | request refuses a second request for a canonical already queued | `test_request_refuses_a_second_request_for_a_queued_canonical` |
| 255 | a valid up request is served: the verb runs | `test_serve_a_valid_request_runs_its_verb` |
| 256 | the served up launches through the verb, as declared | `test_serve_a_valid_request_runs_its_verb` |
| 258 | a served request leaves the queue | `test_serve_a_valid_request_runs_its_verb` |
| 259 | the result carries the verb's output | `test_serve_a_valid_request_runs_its_verb` |
| 263 | an audit line is appended per request | `test_serve_a_valid_request_runs_its_verb` |
| 265 | a second pass serves nothing twice | `test_serve_a_valid_request_runs_its_verb` |
| 274 | the runner refuses a verb outside the four | `test_serve_refuses_a_malformed_request_or_verb` |
| 275 | the runner refuses --force smuggled into a verb | `test_serve_refuses_a_malformed_request_or_verb` |
| 276 | the runner refuses an option in place of a name | `test_serve_refuses_a_malformed_request_or_verb` |
| 277 | the runner refuses a request missing its fields | `test_serve_refuses_a_malformed_request_or_verb` |
| 278 | the runner refuses a file that is not JSON | `test_serve_refuses_a_malformed_request_or_verb` |
| 279 | no refused request reached claude | `test_serve_refuses_a_malformed_request_or_verb` |
| 284 | a PAUSED file refuses every request | `test_serve_paused` |
| 286 | with PAUSED removed the same request runs | `test_serve_paused` |
| 292 | a request older than ten minutes is refused as stale | `test_serve_age` |
| 293 | a request nine minutes old still runs | `test_serve_age` |
| 295 | request-max-age in the config sets the limit | `test_serve_age_follows_the_config` |
| 300 | the runner refuses the never-touch canonical, whoever asks | `test_serve_never_touch` |
| 302 | an empty never-touch list lets it through | `test_serve_never_touch` |
| 308 | the runner refuses a canonical declared for another machine | `test_serve_declared_for_this_machine` |
| 309 | the runner refuses a name the record does not declare | `test_serve_declared_for_this_machine` |
| 315 | a canonical may not request another canonical's action | `test_serve_requester` |
| 316 | the director may request any canonical's action (request-any default) | `test_serve_requester` |
| 318 | request-any in the config names who may act on anyone | `test_serve_requester` |
| 323 | a canonical's request to refresh itself is refused by default | `test_serve_self_refresh` |
| 325 | allow-self-refresh = true lets a self-refresh run, for the measurement | `test_serve_self_refresh` |
| 327 | a canonical may still request its own down | `test_serve_self_down_is_allowed` |
| 333 | of two requests for one canonical, the first queued runs | `test_serve_one_per_canonical_queued` |
| 334 | the second request for the same canonical is refused | `test_serve_one_per_canonical_queued` |
| 339 | a request is refused while one for the same canonical is marked running | `test_serve_one_per_canonical_running` |
| 340 | another canonical's request is not held up by it | `test_serve_one_per_canonical_running` |
| 350 | a fourth action for one canonical within the hour is refused | `test_serve_rate_per_canonical` |
| 351 | refused requests and actions over an hour old do not count | `test_serve_rate_per_canonical` |
| 356 | an eleventh action for the fleet within the hour is refused | `test_serve_rate_fleet` |
| 358 | request-limit-fleet in the config raises the fleet limit | `test_serve_rate_fleet` |
| 368 | the 13-seat fixture | `test_serve_rate_fleet_scales_with_the_seats_declared_here`, `test_serve_rate_fleet_limit_is_twice_the_seats` |
| 374 | with 13 seats declared here, an eleventh action in the hour is not refused | `test_serve_rate_fleet_scales_with_the_seats_declared_here` |
| 379 | ...and its twenty-seventh is (26 = 2 x 13) | `test_serve_rate_fleet_limit_is_twice_the_seats` |
| 387 | a canonical cannot request another seat's init | `test_serve_init` |
| 390 | a director's init request is served | `test_serve_init` |
| 392 | the served init writes the first-launch handoff and launches the seat | `test_serve_init` |
| 404 | up is refused at 85% of the 7-day window (the highest file wins) | `test_serve_usage` |
| 405 | refresh is refused at the threshold too | `test_serve_usage` |
| 406 | down is never refused for usage | `test_serve_usage` |
| 408 | a canonical on the exempt list may still be started | `test_serve_usage` |
| 413 | a usage file whose window already reset is not read as current | `test_serve_usage_ignores_a_window_that_already_reset` |
| 421 | up is refused where claude-trust-check reports the directory untrusted | `test_serve_trust` |
| 422 | an untrusted neighbor does not refuse a trusted canonical | `test_serve_trust` |
| 423 | down needs no trust | `test_serve_trust` |
| 425 | an unknown trust state refuses up (fail closed) | `test_serve_trust_unknown_state_fails_closed` |
| 435 | down waits while the listing reports the session working | `test_serve_working_waits_until_the_session_is_idle` |
| 436 | refresh waits while the transcript's last turn has not ended | `test_serve_working_waits_until_the_session_is_idle` |
| 438 | a waiting request stays queued | `test_serve_working_waits_until_the_session_is_idle` |
| 439 | down of an idle session whose turn ended runs | `test_serve_working_waits_until_the_session_is_idle` |
| 440 | ...its result names the listed state that admitted it | `test_serve_working_waits_until_the_session_is_idle` |
| 442 | only the idle session's row was removed | `test_serve_working_waits_until_the_session_is_idle` |
| 446 | waiting is not in the audit log | `test_serve_working_waits_until_the_session_is_idle` |
| 448 | a second waiting pass keeps when the wait began | `test_serve_working_waits_until_the_session_is_idle` |
| 451 | a waiting refresh is served once the transcript's turn has ended | `test_serve_working_waits_until_the_session_is_idle` |
| 452 | a request for a session still working keeps waiting | `test_serve_working_waits_until_the_session_is_idle` |
| 454 | a waiting down is served once the listing reports the session idle | `test_serve_working_waits_until_the_session_is_idle` |
| 456 | a request that waited gets one audit line, when it is served | `test_serve_working_waits_until_the_session_is_idle` |
| 462 | a self-refresh while working waits | `test_serve_a_waiting_request_past_max_age_is_refused_stale` |
| 464 | a waiting request past request-max-age is refused stale | `test_serve_a_waiting_request_past_max_age_is_refused_stale` |
| 466 | the stale refusal names the wait and consumes the request | `test_serve_a_waiting_request_past_max_age_is_refused_stale` |
| 470 | an unreadable transcript refuses a stop (fail closed) | `test_serve_an_unreadable_transcript_refuses_a_stop` |
| 473 | an unreadable sessions list refuses a stop (fail closed) | `test_serve_an_unreadable_sessions_list_refuses_a_stop` |
| 479 | a blocked session's stop waits | `test_serve_blocked_without_waiting_for_waits_and_says_so` |
| 480 | the reason names a blocked state with no waitingFor | `test_serve_blocked_without_waiting_for_waits_and_says_so` |
| 492 | blocked with no waitingFor, idle by its own record and parked since it started, is served | `test_serve_parked_blocked_session_is_served` |
| 493 | ...its result says the parked path admitted it | `test_serve_parked_blocked_session_is_served` |
| 497 | the same, but its own record says busy, still waits | `test_serve_blocked_session_whose_record_is_busy_waits` |
| 498 | ...and the reason says the session's record is not idle | `test_serve_blocked_session_whose_record_is_busy_waits` |
| 499 | ...and quotes what its last turn asked | `test_serve_blocked_session_whose_record_is_busy_waits` |
| 504 | idle but not parked since it started (its handoff is older) still waits | `test_serve_blocked_session_parked_before_it_started_waits` |
| 505 | ...and the reason says the handoff predates the session | `test_serve_blocked_session_parked_before_it_started_waits` |
| 509 | a blocked session with a real waitingFor still waits, parked or not | `test_serve_blocked_with_a_real_waiting_for_waits` |
| 510 | ...and the reason quotes its waitingFor | `test_serve_blocked_with_a_real_waiting_for_waits` |
| 517 | blocked, no process, no roster worker, parked since it started: the refresh is served | `test_serve_stopped_and_parked_blocked_session_is_served` |
| 520 | the same, but the daemon roster lists a worker for it: waits | `test_serve_stopped_but_the_roster_lists_a_worker_waits` |
| 521 | ...and the reason names the roster worker | `test_serve_stopped_but_the_roster_lists_a_worker_waits` |
| 524 | the same, but a live pid record holds the name: waits | `test_serve_stopped_but_a_live_pid_record_holds_the_name_waits` |
| 525 | ...and the reason names the live process | `test_serve_stopped_but_a_live_pid_record_holds_the_name_waits` |
| 530 | stopped, but its handoff predates the session (never parked): waits | `test_serve_stopped_but_never_parked_waits` |
| 531 | ...and the reason says the handoff predates it | `test_serve_stopped_but_never_parked_waits` |
| 535 | stopped and parked, but a real waitingFor: waits | `test_serve_stopped_with_a_real_waiting_for_waits` |
| 538 | an unreadable daemon roster waits (fail closed) | `test_serve_an_unreadable_roster_waits` |
| 539 | ...and the reason names the roster | `test_serve_an_unreadable_roster_waits` |
| 544 | stopped, but the pointer names a file outside the placed handoffs: waits | `test_serve_a_pointer_outside_the_placed_handoffs_waits` |
| 545 | ...and the reason says it is not a placed copy | `test_serve_a_pointer_outside_the_placed_handoffs_waits` |
| 552 | a refresh whose name another live process still holds after the stop fails | `test_serve_refresh_fails_loudly_when_another_process_still_holds_the_name` |
| 554 | ...saying the stop took but another process still holds the name | `test_serve_refresh_fails_loudly_when_another_process_still_holds_the_name` |
| 560 | up is refused while a live process holds the name the list omits | `test_serve_up_is_refused_while_a_live_process_holds_the_name` |
| 561 | the refusal names the pid and nothing was launched | `test_serve_up_is_refused_while_a_live_process_holds_the_name` |
| 566 | resume is refused while a live process holds the name | `test_serve_resume_is_refused_while_a_live_process_holds_the_name` |
| 569 | a reused pid (start time differs) does not refuse up | `test_serve_a_reused_pid_does_not_refuse_up` |
| 572 | a record whose pid is gone does not refuse up | `test_serve_a_record_whose_pid_is_gone_does_not_refuse_up` |
| 575 | a live process under another name does not refuse up | `test_serve_a_live_process_under_another_name_does_not_refuse_up` |
| 579 | a live process the list does show is left to the working check | `test_serve_a_live_process_the_list_shows_is_left_to_the_working_check` |
| 587 | a working row with an idle pid record and an ended turn is served | `test_serve_stuck_working_row_with_an_idle_record_and_an_ended_turn_is_served` |
| 588 | ...its result says the stuck-working path admitted it | `test_serve_stuck_working_row_with_an_idle_record_and_an_ended_turn_is_served` |
| 591 | a working row whose pid record says shell waits | `test_serve_working_row_whose_record_says_shell_waits` |
| 593 | ...the reason names the pid record's status and nothing was stopped | `test_serve_working_row_whose_record_says_shell_waits` |
| 596 | a working row with an idle record but a turn that has not ended waits | `test_serve_working_row_with_an_idle_record_but_an_unfinished_turn_waits` |
| 597 | ...the reason names the transcript | `test_serve_working_row_with_an_idle_record_but_an_unfinished_turn_waits` |
| 600 | a working row with no pid record at all waits | `test_serve_working_row_with_no_pid_record_waits` |
| 603 | a working row whose pid record says busy waits | `test_serve_working_row_whose_record_says_busy_waits` |
| 607 | a working row with a waitingFor waits whatever its record says | `test_serve_working_row_with_a_waiting_for_waits_whatever_the_record_says` |
| 619 | a refresh of a done seat with a live, idle process is served | `test_serve_refresh_of_a_done_seat_with_an_idle_process` |
| 620 | ...its result says the unlisted-process path admitted it | `test_serve_refresh_of_a_done_seat_with_an_idle_process` |
| 622 | ...the launcher removed the unlisted job and relaunched the seat | `test_serve_refresh_of_a_done_seat_with_an_idle_process` |
| 624 | ...and stopped it before launching | `test_serve_refresh_of_a_done_seat_with_an_idle_process` |
| 627 | a refresh of a done seat whose process is busy is not served | `test_serve_refresh_of_a_done_seat_whose_process_is_busy_waits` |
| 628 | ...and nothing was stopped | `test_serve_refresh_of_a_done_seat_whose_process_is_busy_waits` |
| 631 | a down of a done seat with a background shell running is not served | `test_serve_down_of_a_done_seat_with_a_background_shell_waits` |
| 634 | a done seat whose record is idle but whose turn has not ended waits | `test_serve_done_seat_with_an_idle_record_but_an_unfinished_turn_waits` |
| 637 | a done seat whose transcript cannot be read is refused (fail closed) | `test_serve_done_seat_with_an_unreadable_transcript_is_refused` |
| 640 | a down of a done seat with a live, idle process is served | `test_serve_down_of_a_done_seat_with_an_idle_process` |
| 642 | ...it was stopped and not relaunched | `test_serve_down_of_a_done_seat_with_an_idle_process` |
| 645 | up still refuses a done seat whose process lives, idle or not | `test_serve_up_still_refuses_a_done_seat_whose_process_lives` |
| 648 | resume still refuses a done seat whose process lives | `test_serve_resume_still_refuses_a_done_seat_whose_process_lives` |
| 652 | up runs (the PATH case's control) | `test_contract_a_launch_inherits_the_callers_path` |
| 653 | a launch inherits exactly the caller's PATH, not the queue's uv environment | `test_contract_a_launch_inherits_the_callers_path` |
| 660 | resume of a stopped session runs and the session is live again | `test_serve_resume_of_a_stopped_session` |
| 661 | resume runs claude respawn on the canonical's last session | `test_serve_resume_of_a_stopped_session` |
| 664 | resume is refused while the session is running | `test_serve_resume_of_a_stopped_session` |
| 666 | resume with no listed session fails, naming up | `test_serve_resume_with_no_listed_session_fails` |
| 674 | resume of a listed 'blocked' row with no process and no roster worker is served | `test_serve_resume_of_a_listed_row_with_no_process[blocked]` |
| 674 | resume of a listed 'idle' row with no process and no roster worker is served | `test_serve_resume_of_a_listed_row_with_no_process[idle]` |
| 674 | resume of a listed 'done' row with no process and no roster worker is served | `test_serve_resume_of_a_listed_row_with_no_process[done]` |
| 676 | ...and it respawns the listed row | `test_serve_resume_of_a_listed_row_with_no_process[done]` |
| 678 | ...and confirms by a process, not by the row it already saw | `test_serve_resume_of_a_listed_row_with_no_process[done]` |
| 681 | resume of a listed 'blocked' row is refused while a live pid record holds the name | `test_serve_resume_of_a_listed_row_with_a_live_pid_record_is_refused` |
| 683 | ...naming the process, and nothing was respawned | `test_serve_resume_of_a_listed_row_with_a_live_pid_record_is_refused` |
| 686 | resume of a listed 'blocked' row is refused while the daemon roster lists its worker | `test_serve_resume_of_a_listed_row_with_a_roster_worker_is_refused` |
| 687 | ...naming the roster worker | `test_serve_resume_of_a_listed_row_with_a_roster_worker_is_refused` |
| 690 | resume is refused when the daemon roster cannot be read (fail closed) | `test_serve_resume_is_refused_when_the_roster_cannot_be_read` |
| 693 | resume is refused for a listed row with no session id to look up | `test_serve_resume_is_refused_for_a_row_with_no_session_id` |
| 697 | a respawn that brings no process up fails, though the row was listed all along | `test_serve_a_respawn_that_brings_no_process_up_fails` |
| 699 | ...saying no process appeared | `test_serve_a_respawn_that_brings_no_process_up_fails` |
| 708 | a second runner does not serve a queue another holds | `test_serve_a_second_runner_leaves_the_queue_to_the_first` |
| 711 | once the lock is free the request is served | `test_serve_a_second_runner_leaves_the_queue_to_the_first` |
| 723 | --loop serves the queue on its first pass | `test_contract_loop_serves_each_pass_and_ends_on_sigterm` |
| 725 | --loop serves a request that arrives after the first pass (a second pass ran) | `test_contract_loop_serves_each_pass_and_ends_on_sigterm` |
| 728 | SIGTERM ends --loop with status 0 | `test_contract_loop_serves_each_pass_and_ends_on_sigterm` |
| 729 | SIGTERM leaves nothing on stderr (no traceback) | `test_contract_loop_serves_each_pass_and_ends_on_sigterm` |
| 730 | --loop's per-pass output is the one-shot output, one line per served request | `test_contract_loop_serves_each_pass_and_ends_on_sigterm` |
| 739 | a failing pass is reported on stderr | `test_contract_loop_survives_a_failed_pass` |
| 740 | the loop is still running after a failed pass | `test_contract_loop_survives_a_failed_pass` |
| 742 | a later pass serves once the fault clears | `test_contract_loop_survives_a_failed_pass` |
| 744 | SIGTERM after a failed pass still ends the loop with status 0 | `test_contract_loop_survives_a_failed_pass` |
| 748 | --interval without --loop is a usage error | `test_contract_serve_requests_usage_errors` |
| 750 | --interval must be positive | `test_contract_serve_requests_usage_errors` |
| 752 | serve-requests still takes no other arguments | `test_contract_serve_requests_usage_errors` |
| 770 | snapshot: listed and pid-record seats live, the rest dead, other machines' seats absent | `test_snapshot_states` |
| 774 | snapshot: an unreadable sessions list makes an unseen seat unknown, never dead | `test_snapshot_unreadable_list_is_unknown_never_dead` |
| 780 | snapshot refuses inside a sandbox and writes nothing | `test_snapshot_refuses_inside_a_sandbox` |
| 786 | status: a fresh snapshot's live seat is LIVE-UNLISTED | `test_status_a_fresh_snapshots_live_seat_is_live_unlisted` |
| 790 | status: an unknown seat reads UNKNOWN, not MISSING | `test_status_an_unknown_seat_reads_unknown_not_missing` |
| 794 | status refuses a stale snapshot, naming the timer | `test_status_refuses_a_stale_snapshot` |
| 797 | status with no snapshot notes it and reads the sessions directly | `test_status_with_no_snapshot_notes_it_and_reads_the_sessions_directly` |
| 804 | up refuses a seat the snapshot reads UNKNOWN | `test_up_refuses_a_seat_the_snapshot_reads_unknown` |
| 808 | up refuses a seat the snapshot shows running though the list omits it | `test_up_refuses_a_seat_the_snapshot_shows_running` |
| 811 | up starts a seat the snapshot reads dead (control) | `test_up_starts_a_seat_the_snapshot_reads_dead` |
| 815 | up refuses a stale snapshot | `test_up_and_clean_refuse_a_stale_snapshot` |
| 817 | clean refuses a stale snapshot | `test_up_and_clean_refuse_a_stale_snapshot` |
| 822 | the runner refuses a request while the snapshot is stale | `test_serve_snapshot_stale` |
| 825 | the runner refuses starting a seat the snapshot reads UNKNOWN | `test_serve_snapshot_unknown_seat` |
| 828 | the runner serves it once the snapshot is fresh and the seat dead (control) | `test_serve_snapshot_fresh_and_dead_is_served` |
| 851 | refresh: a snapshot from before the stop that lists the stopped pid does not block the relaunch | `test_refresh_a_pre_stop_snapshot_listing_the_stopped_pid_does_not_block_the_relaunch` |
| 856 | refresh: a snapshot taken AFTER the stop that still shows the seat running refuses (control) | `test_refresh_a_post_stop_snapshot_that_still_shows_the_seat_running_refuses` |
| 861 | refresh: no snapshot after the stop within the wait refuses, naming the next step | `test_refresh_with_no_snapshot_after_the_stop_refuses_naming_the_next_step` |
| 883 | snapshot: a live seat's context is its last main-thread prompt against a 200k window; a later subagent reply is ignored | `test_snapshot_context_is_the_last_main_thread_prompt` |
| 885 | snapshot: a dead seat has no context figure | `test_snapshot_context_is_the_last_main_thread_prompt` |
| 889 | status: a seat at 72.8% shows its context and the CONTEXT-HIGH flag | `test_snapshot_context_is_the_last_main_thread_prompt` |
| 892 | status: 49.9% is not flagged | `test_status_context_bands` |
| 894 | status: the flag does not change the exit code (advisory) | `test_status_context_bands` |
| 897 | status: exactly 50% is CONTEXT-WATCH (a refresh at the next boundary), not HIGH | `test_status_context_bands` |
| 900 | status: 64.9% is still CONTEXT-WATCH | `test_status_context_bands` |
| 902 | status: 65% is CONTEXT-HIGH | `test_status_context_bands` |
| 904 | status: 80% is CONTEXT-CRITICAL | `test_status_context_bands` |
| 906 | status: context-high-pct moves the band | `test_status_context_bands` |
| 911 | snapshot: a seat launched on a [1m] model is measured against 1,000,000 tokens | `test_snapshot_a_1m_model_is_measured_against_a_million_tokens` |
| 918 | snapshot: a prompt larger than the window records no percent, and says so | `test_snapshot_a_prompt_larger_than_the_window_names_the_window_as_wrong` |
| 921 | status: a prompt larger than the window names the window as wrong, never CONTEXT-HIGH | `test_snapshot_a_prompt_larger_than_the_window_names_the_window_as_wrong` |
| 924 | a live seat with no readable transcript shows context ?, not a number | `test_snapshot_a_live_seat_with_no_readable_transcript_shows_a_question_mark` |
