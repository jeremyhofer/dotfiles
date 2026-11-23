# Parity: test-fleet-canonicals.py against the shell suite it replaced

`test-fleet-canonicals.py` replaced `test-fleet-canonicals.sh` (2,602 lines of zsh). This table is
the review record of that port: each check the shell suite made, by its label (the message of its
`ok` line), and the collected pytest id that now makes it. The shell suite is in this repository's
history at the commit before its deletion; the line numbers are its.

**How it was checked.** The labels were extracted from the shell suite by script: every `ok "..."`
outside a comment, a label written with a shell variable (`$dv`, in the `--dry-run --stub` check
that runs for `refresh` and for `up`) expanded to one row per value it took, plus the one bare
`bad` that guards a fixture (line 1846, a linked worktree that could not be made). The script found
**307 checks**: 305 `ok` lines, one of which takes two values, plus the fixture guard. Each label is
kept in the pytest suite as the message of the assertion that replaced it, and a second script
(`ast`, then the `--collect-only` ids) found, for each label, the one test function whose body holds
it. **307 rows below, 307 checks.** Every id was in `pytest --collect-only` output when the table
was written. The one row that is not a test function is the last check of the shell suite, that no
temp-root directory leaked into the real `/tmp`: it is a plugin of the entry point, because the
comparison must span the whole run and every xdist worker (see the docstring).

**What changed in the port**, besides the harness the suite's docstring describes:

- The cases are independent and run in parallel (pytest-xdist, `-n` set in the entry point). The
  shell suite built state in one section and reused it in the next (`GSTATE`, `GS2`, `HREPO`, a
  record that grew); each test now builds its own copy from a fixture (`Fx`, `Gate`, `Leak`, and so
  on), and a section that had several independent subjects became several tests. The checks inside
  one test that walk one evolving state (the handoff pointer cases, the git states of a placed
  handoff, the `clean` before and after) stay in order inside that test.
- The fixture pids are above any `pid_max` (4999911 and up, where the shell suite used 90111 and up),
  so a signal to one can never reach a real process. The shell suite ran `down --all` for real with
  fixture pids that were plausible real pids; the port cannot hurt one.
- The `sleep 300 &` stand-ins for a stopped session are reaped by a thread the moment they exit,
  because under Python a signaled child stays a zombie that still answers `kill -0` until its
  parent waits, which would have made the tool wait out its five-second grace for nothing.
- The functions sourced out of the tool (`claude_bin`, `rm_tmproot`, the date helpers) are run under
  `bash`, the tool's own interpreter, where the shell suite used `zsh -c`.
- A missing `uv` is a failure, not a `SKIP`: the cases that need it (the queue's `live-holders`,
  which `clean`, `up` and `status` run) are checks the suite owes, and the suite is itself run by `uv`.
- The fixture `canonical-kickoff.sh` scripts the shell suite wrote under several seats are gone: the
  tool launches from the record and reads no script, so nothing consulted them. A launch that was
  run before its stand-in launcher existed (`out2` in the stdin-isolation section) had no check and
  is gone too.
- Every case's `HOME` and XDG directories are empty directories of its own, and a teardown fails the
  case if anything appeared in them; the shell suite left `HOME` as it was.

**No shell check was found that could not fail as written.** The mutants below plant one defect at a
time and each was caught by a check of the shell suite's that the port kept; that is a statement
about the checks the mutants reach, not about every check.

**New in the port, with no shell counterpart:** the case `test_the_leak_check_names_a_new_root_and_spares_what_it_should`
(the end check's own logic, so it can be seen to fail) and the per-case `HOME` teardown above.

## Mutants: each seen red, then green

A mutant is a scratch COPY of `executable_fleet-canonicals` (with its queue script beside it) with
one exact find-and-replace; `FLEET_CANONICALS_TOOL` points the suite at it. The tool in the
repository was never edited: `git diff main -- private_dot_local/bin/` is empty. Each run below is
the whole suite at `-n 2`; "green" is the unchanged tool, run the same way before and after.

| Mutant | Defect planted | Failing tests |
| --- | --- | --- |
| `gate-stale` | the freshness gate's `PREDATES` refusal can never fire (`&& false` on its condition) | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one`, `test_the_gate_reads_a_sessions_true_start_from_its_transcript`, `test_force_does_not_lift_the_no_pointer_refusal_and_the_equal_second_boundary` |
| `up-stdin` | `up`'s launch no longer redirects stdin from `/dev/null` | `test_up_hands_a_launched_session_no_stdin_to_swallow` |
| `self-refresh` | `refresh` no longer refuses the session it runs inside (`continue` before the `die`) | `test_a_done_seats_guards_still_hold`, `test_refresh_refuses_the_session_it_runs_inside`, `test_the_self_refusal_cites_what_was_measured` |
| `work-limit` | the work-since-park refusal fires at 40 calls, not 41 (`-gt` to `-ge`) | `test_the_gate_counts_only_main_thread_calls_after_the_document`, `test_the_work_since_park_check_fails_closed` |
| `rm-symlink` | `rm_tmproot` no longer refuses a symlink (the `! -L` test removed) | `test_rm_tmproot_never_follows_a_symlink` |
| `recheck-holder` | `up` no longer re-reads the live holder just before launching | `test_up_rechecks_the_holder_just_before_launching` |
| `autostart-gate` | a bare `up` starts a seat whose `canonicalAutostart` is false | `test_autostart_a_bare_up_skips_a_seat_set_false`, `test_autostart_default_comes_from_the_env_or_the_config_and_a_seats_key_wins`, `test_autostart_with_no_config_and_no_key_every_seat_starts` |
| `init-pointer` | `init` no longer refuses a seat that already has a pointer | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |

The two checks outside the tool were also seen red: the `HOME` teardown (a scratch copy of one case
that creates `~/.cache` fails at teardown) and the end check (a `c-<name>-XXXXXX` directory made
during a run, in a scratch directory the check was pointed at with `FLEET_SUITE_WATCH_TMP`, fails the
run with exit status 1; the same run with the directory present before it passes).

**HOME probe.** The suite was run with `HOME` set to an empty scratch directory (and `UV_CACHE_DIR`
at the real uv cache so the offline `uv run` still resolves); afterwards the directory held 0
entries.

**Time.** The shell suite took 97 s alone. This suite, run through its own entry point at its default
`-n 8` on a 16-CPU machine, took 20.3 s, 21.5 s and 21.1 s on three runs in a row (92 tests, all
passing); through Nx (`npx nx run suite-fleet-canonicals:test --skip-nx-cache`) 30.8 s. The slowest
single test is about 9 s at `-n 2`, which is what bounds the wall time from below.

## test-fleet-canonicals.sh (307 checks)

| Line | Label | pytest id |
| --- | --- | --- |
| 277 | single live session reports OK | `test_status_reports_each_session_state` |
| 278 | two sessions with one name report DUPLICATE | `test_status_reports_each_session_state` |
| 279 | rostered but absent reports MISSING | `test_status_reports_each_session_state` |
| 281 | status exits non-zero when the fleet is not healthy | `test_status_reports_each_session_state` |
| 285 | dedupe targets the older duplicate's pid | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 286 | dedupe spares the newest session | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 287 | dedupe spares an unduplicated session | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 290 | dedupe names the row id it will delete, not just the pid | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 297 | dedupe <name> targets that canonical's older duplicate | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 300 | dedupe <name> leaves every OTHER canonical alone | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 302 | dedupe on an already-clean name reports 0 targets | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 308 | dedupe refuses a name that is not on the roster | `test_dedupe_refuses_what_it_cannot_scope` |
| 310 | a refused name does not report a target count | `test_dedupe_refuses_what_it_cannot_scope` |
| 312 | the refusal lists the valid names | `test_dedupe_refuses_what_it_cannot_scope` |
| 315 | dedupe refuses two names at once | `test_dedupe_refuses_what_it_cannot_scope` |
| 319 | dedupe with no name still sweeps the fleet | `test_dedupe_dry_run_targets_only_the_older_duplicate` |
| 331 | discovers canonicals from the fleet record | `test_discovery_reads_the_fleet_record` |
| 339 | list prints every declared canonical with its identity, fleet-wide | `test_discovery_reads_the_fleet_record` |
| 342 | list fails closed on an unreadable record (exit 2) | `test_discovery_reads_the_fleet_record` |
| 345 | list refuses arguments | `test_discovery_reads_the_fleet_record` |
| 352 | a deeply nested launch directory is still discovered | `test_discovery_reads_the_fleet_record` |
| 360 | a canonical declared for another machine is not expected here | `test_discovery_reads_the_fleet_record` |
| 367 | up --dry-run names the missing session it would start | `test_up_dry_run_names_the_missing_and_spares_the_running` |
| 375 | up refuses loudly for a rostered name that is not declared | `test_up_dry_run_names_the_missing_and_spares_the_running` |
| 381 | up leaves an already-running session alone | `test_up_dry_run_names_the_missing_and_spares_the_running` |
| 383 | up leaves a duplicated-but-present name alone | `test_up_dry_run_names_the_missing_and_spares_the_running` |
| 398 | claude_bin resolves to claude by default | `test_claude_bin_resolves` |
| 405 | claude_bin honors FLEET_CLAUDE_CMD | `test_claude_bin_resolves` |
| 412 | resume-at --dry-run does not sleep or launch | `test_resume_at_argument_handling` |
| 416 | resume-at refuses an unparseable time | `test_resume_at_argument_handling` |
| 420 | resume-at refuses an unknown argument | `test_resume_at_argument_handling` |
| 438 | handoff fails loudly when no pointer exists | `test_handoff_pointer_never_guesses` |
| 443 | handoff --set refuses a pointer to a missing file | `test_handoff_pointer_never_guesses` |
| 448 | handoff --set records an absolute path and echoes it | `test_handoff_pointer_never_guesses` |
| 453 | handoff resolves a recorded pointer | `test_handoff_pointer_never_guesses` |
| 460 | handoff fails when the pointer names a file that is gone | `test_handoff_pointer_never_guesses` |
| 466 | handoff fails on an empty pointer file | `test_handoff_pointer_never_guesses` |
| 471 | handoff refuses a missing name | `test_handoff_pointer_never_guesses` |
| 483 | up refuses an unrecognized name instead of launching | `test_up_refuses_an_unrecognized_word` |
| 485 | up launches nothing when it refuses | `test_up_refuses_an_unrecognized_word` |
| 496 | up <name> starts that canonical | `test_up_and_start_name_a_canonical` |
| 499 | start is an alias for up | `test_up_and_start_name_a_canonical` |
| 508 | up: a record whose pid is not running does not refuse (control) | `test_a_live_process_the_listing_omits_holds_the_name` |
| 514 | up refuses a name a live process holds though the sessions list omits it | `test_a_live_process_the_listing_omits_holds_the_name` |
| 518 | status names a live, unlisted holder instead of MISSING | `test_a_live_process_the_listing_omits_holds_the_name` |
| 520 | the live holder's line does not say MISSING | `test_a_live_process_the_listing_omits_holds_the_name` |
| 539 | up launches when no holder appears (race control) | `test_up_launches_when_no_holder_appears` |
| 543 | up re-checks the holder just before launching, and refuses one that appeared | `test_up_rechecks_the_holder_just_before_launching` |
| 572 | refresh acts on a done seat whose process lives: stops that process and job, then starts | `test_a_done_seat_whose_process_lives_is_stopped_and_refreshed` |
| 576 | down acts on a done seat whose process lives | `test_a_done_seat_whose_process_lives_is_stopped_and_refreshed` |
| 579 | up still refuses a done seat whose process lives | `test_a_done_seat_whose_process_lives_is_stopped_and_refreshed` |
| 586 | refresh refuses a done seat whose process is the session running it | `test_a_done_seats_guards_still_hold` |
| 589 | down skips a done seat whose process is the session running it | `test_a_done_seats_guards_still_hold` |
| 595 | refresh of a done seat still runs the handoff gate before stopping | `test_a_done_seats_guards_still_hold` |
| 603 | up refuses a misspelled name instead of starting everything | `test_up_refuses_a_misspelled_name` |
| 605 | up starts nothing when a name is refused | `test_up_refuses_a_misspelled_name` |
| 611 | down refuses with no name (never closes the fleet by accident) | `test_down_needs_a_name_and_refuses_all_with_names` |
| 615 | down refuses names and --all together | `test_down_needs_a_name_and_refuses_all_with_names` |
| 622 | down <name> targets that session | `test_down_names_the_session_it_closes` |
| 626 | down reports a name that is not running rather than passing silently | `test_down_names_the_session_it_closes` |
| 630 | stop is an alias for down | `test_down_names_the_session_it_closes` |
| 648 | down identifies its own session by process ancestry, with no CLAUDE_SESSION_ID | `test_down_identifies_its_own_session_by_process_ancestry` |
| 653 | down skips the session it is running inside | `test_down_skips_the_session_it_runs_inside` |
| 657 | down --all also skips the running session | `test_down_skips_the_session_it_runs_inside` |
| 699 | refresh pre-flights the declaration and refuses to stop what it cannot restart | `test_refresh_preflights_the_declaration` |
| 701 | refresh stops nothing when the pre-flight refuses | `test_refresh_preflights_the_declaration` |
| 711 | refresh of a NOT-RUNNING name still runs the handoff gate (no handoff -> refused) | `test_refresh_of_a_name_that_is_not_running_launches_and_still_gates` |
| 727 | refresh launches a not-running name instead of making the operator retype it as 'up' | `test_refresh_of_a_name_that_is_not_running_launches_and_still_gates` |
| 730 | refresh of a not-running name stops nothing (there is nothing to stop) | `test_refresh_of_a_name_that_is_not_running_launches_and_still_gates` |
| 742 | refresh refuses a pointer whose handoff file is missing | `test_a_pointer_whose_handoff_file_is_gone_is_refused` |
| 747 | --force does not carry a missing handoff through | `test_a_pointer_whose_handoff_file_is_gone_is_refused` |
| 752 | up --dry-run refuses a missing handoff rather than rehearsing a blind launch | `test_a_pointer_whose_handoff_file_is_gone_is_refused` |
| 758 | up --dry-run refuses a name with no pointer at all | `test_a_pointer_whose_handoff_file_is_gone_is_refused` |
| 769 | up's missing-pointer refusal prints the handoff --set next step | `test_up_names_the_next_step_when_no_pointer_exists` |
| 774 | with exactly one candidate, the next step names it | `test_up_names_the_next_step_when_no_pointer_exists` |
| 780 | with several candidates, none is named | `test_up_names_the_next_step_when_no_pointer_exists` |
| 783 | up never records a pointer itself | `test_up_names_the_next_step_when_no_pointer_exists` |
| 792 | init refuses an undeclared name | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 797 | init refuses a seat with a transcript under its launch directory | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 805 | init refuses a seat whose own project has a fleet-decl --check finding | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 809 | init --dry-run checks and writes nothing | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 814 | init writes a first-launch handoff from the record and records the pointer | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 818 | after init, up accepts the seat | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 821 | init refuses a seat that has a pointer | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 826 | init --up launches the seat | `test_init_writes_a_first_launch_handoff_for_a_never_launched_seat` |
| 833 | refresh refuses with no name | `test_refresh_refuses_a_missing_or_second_name_and_the_force_self_flag_is_gone` |
| 837 | refresh refuses two names rather than half-refreshing a fleet | `test_refresh_refuses_a_missing_or_second_name_and_the_force_self_flag_is_gone` |
| 849 | --force-self is gone: the self-refusal has no escape hatch | `test_refresh_refuses_a_missing_or_second_name_and_the_force_self_flag_is_gone` |
| 860 | the self-refusal cites what was measured, not just a refusal | `test_the_self_refusal_cites_what_was_measured` |
| 867 | gate refuses when no handoff is recorded at all | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 868 | gate names the stub escape hatch in its refusal | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 870 | gate refusal stops nothing | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 876 | a stale pointer still RESOLVES -- which is why the gate is needed | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 880 | gate refuses a handoff recorded before the session it would replace | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 887 | gate passes a handoff recorded after the session started | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 889 | refresh --dry-run names both halves: what it would stop and what it would start | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 891 | refresh prints the handoff age it will resume from | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 898 | gate converts startedAt ms to seconds before comparing | `test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one` |
| 924 | gate refuses a pointer, recorded after the start, naming a document stamped before it | `test_the_gate_refuses_a_document_stamped_before_the_session` |
| 927 | --force skips the document-stamp refusal | `test_the_gate_refuses_a_document_stamped_before_the_session` |
| 932 | --stub passes over the document-stamp refusal (dry run) | `test_the_gate_refuses_a_document_stamped_before_the_session` |
| 937 | gate passes a standard target stamped in the same minute as the start | `test_the_gate_refuses_a_document_stamped_before_the_session` |
| 945 | gate refuses a standard target while a newer one is placed, naming it and the command | `test_the_gate_refuses_a_target_while_a_newer_handoff_exists` |
| 948 | --force skips the newer-handoff refusal | `test_the_gate_refuses_a_target_while_a_newer_handoff_exists` |
| 953 | gate refuses a non-standard target when a standard file is stamped after the pointer was set | `test_the_gate_refuses_a_target_while_a_newer_handoff_exists` |
| 964 | gate refuses a non-standard target committed before the session started | `test_the_gate_dates_a_non_standard_target_by_its_first_commit` |
| 967 | --force skips the committed-before-start refusal | `test_the_gate_dates_a_non_standard_target_by_its_first_commit` |
| 973 | gate passes a non-standard target committed after the session started | `test_the_gate_dates_a_non_standard_target_by_its_first_commit` |
| 983 | gate dates a moved non-standard target by the commit that first added it, not the move | `test_the_gate_dates_a_non_standard_target_by_its_first_commit` |
| 991 | an uncommitted non-standard target in a repository is refused before the gate | `test_the_gate_dates_a_non_standard_target_by_its_first_commit` |
| 998 | gate refuses a non-standard target outside any repository, saying it cannot be dated and naming --force | `test_the_gate_dates_a_non_standard_target_by_its_first_commit` |
| 1001 | --force passes an undatable non-standard target | `test_the_gate_dates_a_non_standard_target_by_its_first_commit` |
| 1007 | gate passes a non-standard target committed after the start with no newer standard file | `test_the_gate_controls_that_must_pass` |
| 1012 | a placed and a staged copy sharing the target's basename do not trigger the newer check | `test_the_gate_controls_that_must_pass` |
| 1020 | another seat's newer file, including one whose name ends with this seat's, is ignored | `test_the_gate_controls_that_must_pass` |
| 1025 | a name that is not exactly standard (...-park-notes.md) is not read | `test_the_gate_controls_that_must_pass` |
| 1033 | gate refuses rather than skips when no session start is known | `test_the_gate_refuses_when_no_session_start_is_known` |
| 1036 | --force passes a session with no known start | `test_the_gate_refuses_when_no_session_start_is_known` |
| 1078 | gate refuses a session with 41 main-thread tool calls after the document date | `test_the_gate_refuses_a_session_that_kept_working_after_its_park` |
| 1081 | --force skips the work-since-park refusal | `test_the_gate_refuses_a_session_that_kept_working_after_its_park` |
| 1085 | gate passes exactly 40 tool calls after the document date (the boundary) | `test_the_gate_counts_only_main_thread_calls_after_the_document` |
| 1090 | gate counts only tool calls AFTER the document date (41+ in all, 40 after) | `test_the_gate_counts_only_main_thread_calls_after_the_document` |
| 1095 | gate does not count isSidechain tool calls | `test_the_gate_counts_only_main_thread_calls_after_the_document` |
| 1100 | gate counts distinct tool_use ids, not lines (one message split across lines) | `test_the_gate_counts_only_main_thread_calls_after_the_document` |
| 1107 | with no transcript the work-since-park check refuses (fails closed), naming --force | `test_the_work_check_fails_closed_without_a_transcript` |
| 1120 | --stub satisfies the gate with no prior handoff | `test_stub_satisfies_the_gate_and_repoints_the_pointer` |
| 1122 | --stub writes a real, non-empty handoff file | `test_stub_satisfies_the_gate_and_repoints_the_pointer` |
| 1124 | --stub records the reason it was given | `test_stub_satisfies_the_gate_and_repoints_the_pointer` |
| 1127 | --stub tells the successor outright that there is nothing to inherit | `test_stub_satisfies_the_gate_and_repoints_the_pointer` |
| 1132 | --stub repoints the handoff pointer at the stub it wrote | `test_stub_satisfies_the_gate_and_repoints_the_pointer` |
| 1139 | handoff --set stamps when it was recorded | `test_handoff_set_stamps_when_it_was_recorded` |
| 1141 | the stamp does not break pointer resolution (reader strips #-comments) | `test_handoff_set_stamps_when_it_was_recorded` |
| 1148 | an unstamped legacy pointer falls back to file mtime rather than failing | `test_a_pointer_written_before_stamping_falls_back_to_the_file_mtime` |
| 1157 | down <name> gates the session that holds the name | `test_down_gates_the_holder_but_not_all_or_dedupe` |
| 1158 | down closes nothing when the gate refuses | `test_down_gates_the_holder_but_not_all_or_dedupe` |
| 1165 | down --all is exempt from the gate (ramp-down, not a handover) | `test_down_gates_the_holder_but_not_all_or_dedupe` |
| 1173 | dedupe is exempt from the gate (it closes rows that were already superseded) | `test_down_gates_the_holder_but_not_all_or_dedupe` |
| 1192 | refresh refuses to refresh the session it runs inside | `test_refresh_refuses_the_session_it_runs_inside` |
| 1194 | refresh stops nothing when it refuses itself | `test_refresh_refuses_the_session_it_runs_inside` |
| 1198 | self-refusal precedes the handoff gate, so the error names the real problem | `test_refresh_refuses_the_session_it_runs_inside` |
| 1215 | file_mtime returns an epoch on this platform (GNU or BSD stat) | `test_file_mtime_returns_an_epoch` |
| 1220 | fmt_epoch formats an epoch on this platform (GNU or BSD date) | `test_fmt_epoch_formats_an_epoch` |
| 1228 | parse_time parses a date-time on this platform (GNU or BSD date) | `test_parse_time_parses_a_real_time_and_refuses_junk` |
| 1232 | parse_time still refuses junk on this platform | `test_parse_time_parses_a_real_time_and_refuses_junk` |
| 1302 | up hands a launched session no stdin to swallow into its prompt | `test_up_hands_a_launched_session_no_stdin_to_swallow` |
| 1307 | up starts every missing canonical, not just the first | `test_up_hands_a_launched_session_no_stdin_to_swallow` |
| 1310 | up's reported count matches what it actually started | `test_up_hands_a_launched_session_no_stdin_to_swallow` |
| 1332 | the launch carries the DECLARED model tier | `test_the_launch_carries_the_declared_tier_and_a_prompt_that_describes` |
| 1335 | the identity sentence is composed from the declared role | `test_the_launch_carries_the_declared_tier_and_a_prompt_that_describes` |
| 1341 | the launch prompt names the handoff as the previous session's record of work | `test_the_launch_carries_the_declared_tier_and_a_prompt_that_describes` |
| 1344 | the launch prompt carries no persona line and no follow-the-file instruction | `test_the_launch_carries_the_declared_tier_and_a_prompt_that_describes` |
| 1358 | with remote-control unset, a launch carries no --remote-control | `test_remote_control_follows_the_machine_key_and_the_seats_override` |
| 1362 | remote-control = true: the launch carries --remote-control <its own name>, before the prompt | `test_remote_control_follows_the_machine_key_and_the_seats_override` |
| 1366 | a value other than true or false launches without Remote Control, and says so | `test_remote_control_follows_the_machine_key_and_the_seats_override` |
| 1371 | a canonical's canonicalRemoteControl: false overrides the machine's true | `test_remote_control_follows_the_machine_key_and_the_seats_override` |
| 1374 | a canonical's canonicalRemoteControl: true turns it on where the machine has it off | `test_remote_control_follows_the_machine_key_and_the_seats_override` |
| 1377 | BOTH resume --fork invocations carry the Remote Control arguments | `test_resume_forks_carry_the_remote_control_arguments` |
| 1409 | macOS: a launch with SSH_CONNECTION set is refused, and nothing is started | `test_macos_over_ssh_a_launch_is_refused_and_nothing_starts` |
| 1413 | macOS: the dry run refuses over SSH, as the real launch would | `test_macos_over_ssh_a_launch_is_refused_and_nothing_starts` |
| 1417 | macOS, not over SSH: a launch fragment variable reaches the launched claude's environment | `test_the_launch_fragment_reaches_the_launched_environment` |
| 1420 | a fragment value is taken literally: no quote removal, no expansion | `test_the_launch_fragment_reaches_the_launched_environment` |
| 1424 | Linux: SSH_CONNECTION set does not refuse a launch (the refusal is macOS-only) | `test_linux_over_ssh_launches_without_reading_the_fragment` |
| 1427 | over SSH the launch fragment is not read | `test_linux_over_ssh_launches_without_reading_the_fragment` |
| 1431 | Linux, not over SSH: the fragment is read too (the base reads it wherever a domain puts it) | `test_the_launch_fragment_reaches_the_launched_environment` |
| 1435 | with no fragment a launch proceeds unchanged | `test_the_launch_fragment_reaches_the_launched_environment` |
| 1440 | a fragment line that is not KEY=VALUE refuses the launch, naming the file and line | `test_a_malformed_fragment_refuses_the_launch` |
| 1445 | a fragment line with no = refuses the launch | `test_a_malformed_fragment_refuses_the_launch` |
| 1452 | macOS: refresh over SSH refuses before it stops anything | `test_refresh_and_resume_refuse_over_ssh_before_acting` |
| 1458 | macOS: resume over SSH is refused before it wakes or forks | `test_refresh_and_resume_refuse_over_ssh_before_acting` |
| 1461 | resume applies the launch fragment to the wake and to BOTH fork invocations | `test_resume_applies_the_launch_fragment_to_every_launch` |
| 1469 | macOS: with the launchd-domain hook set, a launch outside Aqua is refused | `test_the_launchd_domain_hook_decides_where_a_macos_launch_may_run` |
| 1473 | macOS: with the launchd-domain hook set, a launch in Aqua proceeds | `test_the_launchd_domain_hook_decides_where_a_macos_launch_may_run` |
| 1477 | Linux: the launchd-domain hook is not consulted | `test_the_launchd_domain_hook_decides_where_a_macos_launch_may_run` |
| 1491 | macOS: unset, the hook runs launchctl managername and refuses a launch outside Aqua | `test_the_default_launchd_domain_hook_runs_launchctl` |
| 1495 | macOS: unset, the hook lets a launch in Aqua proceed | `test_the_default_launchd_domain_hook_runs_launchctl` |
| 1499 | macOS: FLEET_MANAGERNAME_CMD set empty turns the check off | `test_the_default_launchd_domain_hook_runs_launchctl` |
| 1503 | Linux: unset, the hook still runs nothing | `test_the_default_launchd_domain_hook_runs_launchctl` |
| 1545 | a staged handoff launches (location check only) | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1548 | a stub handoff written by --stub launches | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1550 | a staged handoff launches where no handoffs directory is configured | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1554 | a handoff outside the staging and handoffs trees is refused | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1557 | a path that climbs out of staging with .. is refused | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1560 | a symlink in staging is refused, wherever it points | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1564 | with no handoffs directory configured, a file in an unconfigured tree is refused | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1567 | a placed handoff outside any git repository launches | `test_a_launch_names_only_a_handoff_inside_the_handoff_trees` |
| 1572 | a placed handoff in a git repository but never committed is refused | `test_a_placed_handoff_in_git_must_be_committed_and_unchanged` |
| 1576 | a placed handoff staged in git but not committed is refused | `test_a_placed_handoff_in_git_must_be_committed_and_unchanged` |
| 1579 | a committed handoff launches | `test_a_placed_handoff_in_git_must_be_committed_and_unchanged` |
| 1583 | a committed handoff edited since its commit is refused | `test_a_placed_handoff_in_git_must_be_committed_and_unchanged` |
| 1596 | up's launch carries --settings with a CLAUDE_CODE_TMPDIR env override | `test_every_launch_gets_a_temp_root_that_is_recorded_and_passed` |
| 1600 | up records the launched session's temp root under FLEET_STATE | `test_every_launch_gets_a_temp_root_that_is_recorded_and_passed` |
| 1605 | the recorded root matches the /tmp/c-<short>-XXXXXX shape (under the test prefix) | `test_every_launch_gets_a_temp_root_that_is_recorded_and_passed` |
| 1609 | the root named in --settings is the SAME root that got recorded | `test_every_launch_gets_a_temp_root_that_is_recorded_and_passed` |
| 1613 | the launch actually created its temp root as a real directory (not a symlink) | `test_every_launch_gets_a_temp_root_that_is_recorded_and_passed` |
| 1628 | wakes an existing session via attach rather than forking it | `test_resume_prefers_waking_over_forking` |
| 1632 | forking is opt-in (--fork), not the default | `test_resume_prefers_waking_over_forking` |
| 1639 | the fork path reads the --all listing, so a stopped session is visible | `test_resume_prefers_waking_over_forking` |
| 1652 | --fork on a LIVE session is refused, with stop-then-fork named as the way through | `test_resume_prefers_waking_over_forking` |
| 1656 | the fork launches from the SOURCE session's cwd, not the caller's | `test_resume_prefers_waking_over_forking` |
| 1666 | the fork path records its own temp root, same as launch_canonical | `test_resume_prefers_waking_over_forking` |
| 1674 | BOTH fork invocations (cd-into-src-cwd and the fallback) carry --settings | `test_resume_prefers_waking_over_forking` |
| 1708 | transcript fixture carries a real timestamp on this platform | `test_the_gate_reads_a_sessions_true_start_from_its_transcript` |
| 1722 | gate reads the session's TRUE start from its transcript, so a resume does not fake staleness | `test_the_gate_reads_a_sessions_true_start_from_its_transcript` |
| 1725 | the gate SAYS it substituted the transcript start, naming both times | `test_the_gate_reads_a_sessions_true_start_from_its_transcript` |
| 1733 | a handoff older than the transcript start is still refused | `test_the_gate_reads_a_sessions_true_start_from_its_transcript` |
| 1741 | an unreadable transcript falls back to startedAt rather than disabling the gate | `test_the_gate_reads_a_sessions_true_start_from_its_transcript` |
| 1748 | --force carries a refusal through | `test_force_carries_a_refusal_through_and_keeps_the_pointer` |
| 1750 | --force records the operator's reason in the output | `test_force_carries_a_refusal_through_and_keeps_the_pointer` |
| 1752 | --force leaves the recorded handoff pointer untouched | `test_force_carries_a_refusal_through_and_keeps_the_pointer` |
| 1755 | --force did not rewrite the pointer to a generated stub | `test_force_carries_a_refusal_through_and_keeps_the_pointer` |
| 1761 | --stub and --force together are refused | `test_force_carries_a_refusal_through_and_keeps_the_pointer` |
| 1768 | the gate's refusal names BOTH hatches and what each one does | `test_force_carries_a_refusal_through_and_keeps_the_pointer` |
| 1796 | one name declared by two projects is reported, not silently tie-broken | `test_one_canonical_name_declared_by_two_projects_is_reported` |
| 1801 | a reader asked about an ambiguous name refuses and names both projects | `test_one_canonical_name_declared_by_two_projects_is_reported` |
| 1834 | refresh warns when the canonical is sitting in a linked worktree | `test_refresh_warns_when_the_canonical_sits_in_a_linked_worktree` |
| 1837 | the worktree warning does not block the refresh -- it is a warning, not a gate | `test_refresh_warns_when_the_canonical_sits_in_a_linked_worktree` |
| 1843 | no warning for a canonical in its primary checkout | `test_refresh_warns_when_the_canonical_sits_in_a_linked_worktree` |
| 1846 | fixture: could not create a linked worktree, so the warning was never exercised | `test_refresh_warns_when_the_canonical_sits_in_a_linked_worktree` |
| 1871 | an unplaced staged handoff is reported | `test_status_reports_staged_handoffs_nobody_placed` |
| 1876 | one placed in handoffs/ is not reported | `test_status_reports_staged_handoffs_nobody_placed` |
| 1882 | one placed outside handoffs/ is not a false orphan | `test_status_reports_staged_handoffs_nobody_placed` |
| 1895 | a staged file DECLARING it was placed is not an orphan | `test_status_reports_staged_handoffs_nobody_placed` |
| 1901 | a staged file DECLARING it is superseded is not an orphan | `test_status_reports_staged_handoffs_nobody_placed` |
| 1911 | a marker below the header does NOT excuse a file | `test_status_reports_staged_handoffs_nobody_placed` |
| 1916 | the count reflects real orphans only | `test_status_reports_staged_handoffs_nobody_placed` |
| 1947 | rm_tmproot removes a recorded root that matches the exact shape | `test_rm_tmproot_removes_a_recorded_root_of_the_exact_shape` |
| 1950 | rm_tmproot clears the record once its root is gone | `test_rm_tmproot_removes_a_recorded_root_of_the_exact_shape` |
| 1960 | rm_tmproot removes the exact recorded root | `test_rm_tmproot_leaves_a_sibling_it_was_not_told_about` |
| 1963 | a sibling directory NOT named in the record survives untouched | `test_rm_tmproot_leaves_a_sibling_it_was_not_told_about` |
| 1973 | a recorded path outside the expected shape is left untouched | `test_rm_tmproot_refuses_a_path_outside_the_expected_shape` |
| 1976 | a mismatched record is left in place too, rather than silently cleared | `test_rm_tmproot_refuses_a_path_outside_the_expected_shape` |
| 1986 | rm_tmproot refuses a recorded path that is a symlink, even to a real directory | `test_rm_tmproot_never_follows_a_symlink` |
| 1995 | a recorded root that never existed on disk does not error | `test_rm_tmproot_accepts_a_root_that_is_already_gone` |
| 1998 | an already-gone root's record is cleared | `test_rm_tmproot_accepts_a_root_that_is_already_gone` |
| 2001 | ...and its note says already gone, not a refusal | `test_rm_tmproot_accepts_a_root_that_is_already_gone` |
| 2051 | down actually signals the session's process | `test_down_deletes_the_recorded_root_and_only_that` |
| 2054 | down removes the recorded temp root once the session is gone | `test_down_deletes_the_recorded_root_and_only_that` |
| 2057 | down clears the .tmproot record along with the root | `test_down_deletes_the_recorded_root_and_only_that` |
| 2060 | down leaves an unrelated sibling directory alone | `test_down_deletes_the_recorded_root_and_only_that` |
| 2100 | dedupe signals the OLDER duplicate's process | `test_dedupe_never_deletes_the_survivors_root` |
| 2103 | dedupe leaves the NEWER survivor's process running | `test_dedupe_never_deletes_the_survivors_root` |
| 2106 | dedupe never deletes the survivor's recorded temp root | `test_dedupe_never_deletes_the_survivors_root` |
| 2109 | the record still points at the survivor's root, untouched | `test_dedupe_never_deletes_the_survivors_root` |
| 2165 | refresh completes successfully end to end | `test_refresh_deletes_the_old_root_only_never_the_new_one` |
| 2167 | refresh removes the OLD session's recorded temp root | `test_refresh_deletes_the_old_root_only_never_the_new_one` |
| 2172 | refresh records a NEW root, distinct from the old one | `test_refresh_deletes_the_old_root_only_never_the_new_one` |
| 2175 | the new root is a real directory on disk | `test_refresh_deletes_the_old_root_only_never_the_new_one` |
| 2180 | the relaunch's --settings carries the SAME new root that got recorded | `test_refresh_deletes_the_old_root_only_never_the_new_one` |
| 2184 | the old session's process was actually terminated by the refresh | `test_refresh_deletes_the_old_root_only_never_the_new_one` |
| 2214 | resume finds the transcript under FLEET_TRANSCRIPT_DIR | `test_resume_fork_advisory_fires_only_for_a_newer_handoff` |
| 2217 | the advisory fires for a stamped pointer naming a handoff newer than the transcript | `test_resume_fork_advisory_fires_only_for_a_newer_handoff` |
| 2223 | the advisory stays quiet when the handoff is older than the transcript | `test_resume_fork_advisory_fires_only_for_a_newer_handoff` |
| 2265 | clean --dry-run names what it would remove and removes nothing | `test_clean_removes_the_roots_of_gone_sessions_and_only_those` |
| 2272 | clean removes the roots of names with no running session | `test_clean_removes_the_roots_of_gone_sessions_and_only_those` |
| 2274 | clean clears the record of a root it removed | `test_clean_removes_the_roots_of_gone_sessions_and_only_those` |
| 2277 | clean keeps every root a running session may own, and every path of another shape | `test_clean_removes_the_roots_of_gone_sessions_and_only_those` |
| 2280 | a kept root's contents are untouched | `test_clean_removes_the_roots_of_gone_sessions_and_only_those` |
| 2281 | clean never follows a symlink of the root's shape | `test_clean_removes_the_roots_of_gone_sessions_and_only_those` |
| 2284 | clean leaves the records of running sessions alone | `test_clean_removes_the_roots_of_gone_sessions_and_only_those` |
| 2289 | clean refuses, removing nothing, when the sessions list cannot be read | `test_clean_fails_closed_and_refuses_unknown_arguments` |
| 2292 | clean refuses an unknown argument | `test_clean_fails_closed_and_refuses_unknown_arguments` |
| 2306 | clean keeps the roots of a seat the listing omits while its process lives | `test_clean_keeps_the_roots_of_a_seat_the_listing_omits_while_its_process_lives` |
| 2309 | ...and says a live process holds the name | `test_clean_keeps_the_roots_of_a_seat_the_listing_omits_while_its_process_lives` |
| 2314 | with no live process behind it, an unlisted seat's roots are removed | `test_clean_keeps_the_roots_of_a_seat_the_listing_omits_while_its_process_lives` |
| 2324 | clean refuses inside a sandbox, removing nothing | `test_clean_refuses_where_it_cannot_see_live_processes` |
| 2327 | clean refuses, removing nothing, when the live-process check cannot run | `test_clean_refuses_where_it_cannot_see_live_processes` |
| 2386 | a: bare up skips a seat with canonicalAutostart: false | `test_autostart_a_bare_up_skips_a_seat_set_false` |
| 2388 | a: bare up still starts the seat with no key and the one set true | `test_autostart_a_bare_up_skips_a_seat_set_false` |
| 2392 | b: autostart-default = false skips a seat that sets no key | `test_autostart_default_comes_from_the_env_or_the_config_and_a_seats_key_wins` |
| 2393 | b: a seat set true still starts under autostart-default = false | `test_autostart_default_comes_from_the_env_or_the_config_and_a_seats_key_wins` |
| 2395 | b: the false seat stays off under default false | `test_autostart_default_comes_from_the_env_or_the_config_and_a_seats_key_wins` |
| 2401 | b: autostart-default is read from the config file | `test_autostart_default_comes_from_the_env_or_the_config_and_a_seats_key_wins` |
| 2406 | b: a seat's false beats a default of true | `test_autostart_default_comes_from_the_env_or_the_config_and_a_seats_key_wins` |
| 2409 | c: up --dry-run <name> starts an optional seat | `test_autostart_naming_a_seat_starts_it_wherever_the_default_points` |
| 2411 | c: naming one seat starts only that seat | `test_autostart_naming_a_seat_starts_it_wherever_the_default_points` |
| 2414 | c: a named seat starts even where the default is false | `test_autostart_naming_a_seat_starts_it_wherever_the_default_points` |
| 2419 | d: up --all --dry-run starts every declared seat | `test_autostart_up_all_starts_every_declared_seat` |
| 2421 | d: up --all with names is refused | `test_autostart_up_all_starts_every_declared_seat` |
| 2426 | e: a down optional seat reads 'off (on demand)' | `test_autostart_status_reads_a_down_optional_seat_as_off_not_missing` |
| 2427 | e: an off seat is not missing: status exits 0 | `test_autostart_status_reads_a_down_optional_seat_as_off_not_missing` |
| 2431 | e: a down autostart seat is still MISSING, and status exits 1 | `test_autostart_status_reads_a_down_optional_seat_as_off_not_missing` |
| 2436 | e: a live optional seat still reads OK | `test_autostart_status_reads_a_down_optional_seat_as_off_not_missing` |
| 2438 | e: the default applies to status too (no key, default false) | `test_autostart_status_reads_a_down_optional_seat_as_off_not_missing` |
| 2444 | g: with no config and no key, bare up starts every seat | `test_autostart_with_no_config_and_no_key_every_seat_starts` |
| 2446 | g: with no config and no key, nothing reads off | `test_autostart_with_no_config_and_no_key_every_seat_starts` |
| 2450 | g: a bad autostart-default is reported and treated as true | `test_autostart_with_no_config_and_no_key_every_seat_starts` |
| 2454 | g: a bad canonicalAutostart is reported and treated as true | `test_autostart_with_no_config_and_no_key_every_seat_starts` |
| 2478 | up refuses a dead seat whose last session started after its park's stamp | `test_up_refuses_a_dead_seat_whose_park_predates_its_last_session` |
| 2485 | up starts a dead seat whose park follows its last session (control) | `test_up_refuses_a_dead_seat_whose_park_predates_its_last_session` |
| 2490 | up --force proceeds on the stale case, saying FORCED | `test_up_refuses_a_dead_seat_whose_park_predates_its_last_session` |
| 2494 | up --stub --dry-run passes the stale pointer and would proceed (writes nothing) | `test_up_refuses_a_dead_seat_whose_park_predates_its_last_session` |
| 2497 | up refuses --force with --stub | `test_up_refuses_a_dead_seat_whose_park_predates_its_last_session` |
| 2499 | up still refuses an unknown option | `test_up_refuses_a_dead_seat_whose_park_predates_its_last_session` |
| 2508 | up with two seats: the stale one is refused, the other would start, the status is nonzero | `test_up_with_several_seats_refuses_the_stale_one_and_starts_the_other` |
| 2515 | refresh --force of a stale stopped seat is not undone by up's gate | `test_refresh_runs_the_gate_once_and_up_does_not_undo_it` |
| 2518 | refresh runs the gate once, not once more through up | `test_refresh_runs_the_gate_once_and_up_does_not_undo_it` |
| 2523 | refresh --stub of a stale stopped seat is not refused by up's gate | `test_refresh_runs_the_gate_once_and_up_does_not_undo_it` |
| 2535 | refresh --dry-run --stub writes no stub and leaves the pointer alone | `test_a_dry_run_stub_writes_nothing[refresh]` |
| 2535 | up --dry-run --stub writes no stub and leaves the pointer alone | `test_a_dry_run_stub_writes_nothing[up]` |
| 2546 | down refuses a listed seat whose transcript cannot be read (work-since-park fails closed) | `test_the_work_since_park_check_fails_closed` |
| 2549 | --force lifts the unreadable-transcript refusal | `test_the_work_since_park_check_fails_closed` |
| 2553 | a transcript with 40 calls after the document passes (control) | `test_the_work_since_park_check_fails_closed` |
| 2561 | refresh --force with no pointer is refused | `test_force_does_not_lift_the_no_pointer_refusal_and_the_equal_second_boundary` |
| 2565 | --stub stays the hatch for no pointer (dry run: writes nothing) | `test_force_does_not_lift_the_no_pointer_refusal_and_the_equal_second_boundary` |
| 2572 | a pointer recorded at exactly the session's start second is refused | `test_force_does_not_lift_the_no_pointer_refusal_and_the_equal_second_boundary` |
| 2576 | a pointer one second after the start is not refused as predating (control) | `test_force_does_not_lift_the_no_pointer_refusal_and_the_equal_second_boundary` |
| 2598 | no temp-root directories leaked into the real /tmp during this suite | `TmpRootLeakCheck` (the entry point's plugin); its comparison is `test_the_leak_check_names_a_new_root_and_spares_what_it_should` |
