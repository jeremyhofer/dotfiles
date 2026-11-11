# Parity: test-image-bump.py against the five shell suites it replaced

`test-image-bump.py` replaced `test-image-bump.sh`, `test-image-bump-check.sh`,
`test-image-bump-deploy.sh`, `test-image-bump-estate.sh` and `test-image-bump-latest.sh`. This table
is the review record of that port: each check the shell suites made, by its label (the first argument
of their `ok`, `expect`, `has`, `lacks`, `logged`, `unlogged`, `before` or `try_desc`), and the
collected pytest id that now makes it. The shell suites are in this repository's history at the
commit before their deletion; the line numbers are theirs.

**How it was checked.** The labels were extracted from the shell suites by script, a label written
with a shell variable expanded to one row per value it took. Each label is kept in the pytest suite
as the message of the assertion, or the label of the table row, that replaced it, so a row can be
found by searching the suite for its label. Every id below was in `pytest --collect-only` output when
the table was written. No check was removed: 294 checks, 294 rows (two added on 2026-11-10 with the `url_ok` fix).

**What changed in the port**, besides the harness the suite's docstring describes:

- External commands are compared as whole argument lists where the shell suites matched regular
  expressions against a log.
- `deploy`'s check retries run on a virtual clock, so their count is exact (3), where the shell suite
  could only ask for at least 3.
- `test-image-bump-check.sh:285`, "equal fixable count is refused", gave the new image three fixable
  findings against the current pin's two, so the boundary it names was never tested. The port tests
  two against two, and keeps the original case as `test_check_floor[more-fixable-refused]`.
- `test-image-bump-estate.sh:343` could never fail: it searched the server log for `linux.arm64 `
  with a trailing space, which no logged path has. Line 344 made the real check; both map to it.
- The tampered-checksums case changed the first character of the checksums file to `0`, which does
  nothing when it already is `0`; the port changes it to another digit.
- Lines 408 and 431 of the estate suite checked that a record exists only through their `else`
  branch (`no "  no record"`); they are listed with that branch's meaning.

**New in the port, with no shell counterpart:** the contract tests (`test_contract_*`), the mutant
meta-tests (`test_mutant_*`, one per row of `MUTANTS`), and `test_check_floor[more-fixable-refused]`.

## test-image-bump.sh (34 checks)

| Line | Label | pytest id |
| --- | --- | --- |
| 72 | good descriptor validates | `test_a_good_descriptor_validates` |
| 73 | prints 'ok good' | `test_a_good_descriptor_validates` |
| 77 | missing field | `test_validate[missing-field]` |
| 80 | unknown gate kind | `test_validate[unknown-gate-kind]` |
| 83 | unknown migrations kind | `test_validate[unknown-migrations-kind]` |
| 86 | unknown install kind | `test_validate[unknown-install-kind]` |
| 89 | unknown release_line strategy | `test_validate[unknown-release-line]` |
| 92 | platform not os/arch | `test_validate[platform-not-os-arch]` |
| 95 | near miss: another os/arch passes | `test_validate[near-miss-another-os-arch]` |
| 98 | missing container | `test_validate[missing-container]` |
| 101 | missing service | `test_validate[missing-service]` |
| 104 | empty service | `test_validate[empty-service]` |
| 107 | wrong type | `test_validate[wrong-type]` |
| 110 | git_tag without {version} | `test_validate[git-tag-without-version]` |
| 114 | unparsable pin file | `test_validate[unparsable-pin-file]` |
| 118 | pin names another image | `test_validate[pin-names-another-image]` |
| 120 | no descriptor | `test_validate_without_a_descriptor_is_refused` |
| 125 | manual install without the deploy-only fields validates | `test_validate[manual-validates]` |
| 127 | manual without steps | `test_validate[manual-without-steps]` |
| 129 | manual with empty steps | `test_validate[manual-empty-steps]` |
| 131 | manual with an empty step | `test_validate[manual-an-empty-step]` |
| 133 | manual with a non-string step | `test_validate[manual-non-string-step]` |
| 137 | manual with volume present | `test_validate[manual-with-volume]` |
| 137 | manual with vm_unit present | `test_validate[manual-with-vm_unit]` |
| 137 | manual with container present | `test_validate[manual-with-container]` |
| 137 | manual with service present | `test_validate[manual-with-service]` |
| 137 | manual with checks present | `test_validate[manual-with-checks]` |
| 140 | manual still needs migrations (check reads it) | `test_validate[manual-needs-migrations]` |
| 142 | near miss: a vm-copy install ignores a stray steps key | `test_validate[near-miss-vm-copy-stray-steps]` |
| 146 | descriptor raising at import | `test_a_descriptor_raising_at_import_is_status_2_never_1` |
| 150 | latest on an unreachable host is an environment error | `test_latest_on_an_unreachable_host_is_an_environment_error` |
| 151 | unknown verb is a usage error | `test_an_unknown_verb_is_a_usage_error` |
| 155 | IMAGE_BUMP_ROOT is the default root | `test_image_bump_root_is_the_default_root` |
| 174 | pin reader and version helpers | `test_the_pin_reader_and_version_helpers` |

## test-image-bump-check.sh (72 checks)

| Line | Label | pytest id |
| --- | --- | --- |
| 180 | clean new image passes | `test_check_a_clean_new_image_passes` |
| 181 | index resolved with --raw on the new tag | `test_check_a_clean_new_image_passes` |
| 182 | config read on the chosen arm64 digest | `test_check_a_clean_new_image_passes` |
| 184 | database fetched exactly once | `test_check_a_clean_new_image_passes` |
| 187 | database fetched before the first scan | `test_check_a_clean_new_image_passes` |
| 188 | version read for the database timestamp | `test_check_a_clean_new_image_passes` |
| 190 | scan of $DA carries --skip-db-update and --platform | `test_check_a_clean_new_image_passes` |
| 190 | scan of $D0 carries --skip-db-update and --platform | `test_check_a_clean_new_image_passes` |
| 193 | exactly two scans | `test_check_a_clean_new_image_passes` |
| 194 | pin file rewritten | `test_check_a_clean_new_image_passes` |
| 196 | record written as <name>-<version>-<date>.txt | `test_check_a_clean_new_image_passes` |
| 197 | record name has an ISO date | `test_check_a_clean_new_image_passes` |
| 198 | checklist printed | `test_check_a_clean_new_image_passes` |
| 202 | record title line | `test_check_a_clean_new_image_passes` |
| 206 | record has 'image: $IMG:v1.3.0-rootless' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'digest: $DA' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'platform: linux/arm64' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'replaces: $D0' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'scanner: 0.99.0' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'database: 2026-10-27T06:00:00.5Z' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'gate: fixable-count-floor' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'verdict: pass' | `test_check_a_clean_new_image_passes` |
| 206 | record has 'migrates: no' | `test_check_a_clean_new_image_passes` |
| 208 | record scanned: date-time with offset and host | `test_check_a_clean_new_image_passes` |
| 209 | record lists the current pin's findings | `test_check_a_clean_new_image_passes` |
| 222 | read_record round-trips replaces, migrates, digest | `test_check_a_clean_new_image_passes` |
| 226 | an existing record is never overwritten | `test_check_never_overwrites_a_record` |
| 227 | existing record untouched | `test_check_never_overwrites_a_record` |
| 228 | pin untouched on that refusal | `test_check_never_overwrites_a_record` |
| 234 | index whose arm64 entry's config says amd64 is refused | `test_check_refuses_an_image_built_for_another_platform` |
| 235 | no scan after the platform refusal | `test_check_refuses_an_image_built_for_another_platform` |
| 236 | pin untouched | `test_check_refuses_an_image_built_for_another_platform` |
| 237 | no record | `test_check_refuses_an_image_built_for_another_platform` |
| 244 | index with no entry for the platform is refused | `test_check_refuses_an_index_without_the_platform` |
| 254 | single-manifest image resolves to the hash of its bytes | `test_check_a_single_manifest_resolves_to_the_hash_of_its_bytes` |
| 255 | pin is the manifest's own digest | `test_check_a_single_manifest_resolves_to_the_hash_of_its_bytes` |
| 263 | a tag resolving to the current digest is refused | `test_check_refuses_a_tag_that_is_already_pinned` |
| 266 | near miss: --no-write reports it and continues | `test_check_refuses_a_tag_that_is_already_pinned` |
| 267 | scans ran under --no-write | `test_check_refuses_a_tag_that_is_already_pinned` |
| 268 | --no-write wrote nothing | `test_check_refuses_a_tag_that_is_already_pinned` |
| 273 | fixable finding with a clean current pin is refused | `test_check_floor_refuses_a_fixable_finding_against_a_clean_pin` |
| 274 | refusal writes nothing | `test_check_floor_refuses_a_fixable_finding_against_a_clean_pin` |
| 278 | fewer fixable than the current pin is an exception | `test_check_floor_fewer_fixable_than_the_current_pin_is_an_exception` |
| 279 | approval line carries both counts | `test_check_floor_fewer_fixable_than_the_current_pin_is_an_exception` |
| 280 | exception recorded | `test_check_floor_fewer_fixable_than_the_current_pin_is_an_exception` |
| 281 | exception writes the pin | `test_check_floor_fewer_fixable_than_the_current_pin_is_an_exception` |
| 285 | equal fixable count is refused | `test_check_floor[equal-count-refused]` (the shell case gave the new image 3 fixable findings against 2; the port tests 2 against 2 as labeled, and keeps 3 against 2 as `test_check_floor[more-fixable-refused]`) |
| 288 | near miss: unfixed findings are not counted, so pass | `test_check_floor[unfixed-not-counted]` |
| 293 | no-new-findings with one new finding is refused | `test_check_no_new_findings[one-new-refused]` |
| 296 | near miss: an equal finding set passes | `test_check_no_new_findings[equal-set-passes]` |
| 299 | a subset of the current findings passes | `test_check_no_new_findings[subset-passes]` |
| 304 | a name only in the new listing | `test_check_a_name_only_in_the_new_listing_migrates` |
| 305 | record says migrates: yes | `test_check_a_name_only_in_the_new_listing_migrates` |
| 308 | near miss: identical listings | `test_check_migrations[identical]` |
| 311 | near miss: a file only in the OLD listing | `test_check_migrations[only-in-old]` |
| 318 | near miss: a new directory is not a new file | `test_check_migrations[new-directory]` |
| 321 | no listing at the new tag (a 404) is an environment error | `test_check_migrations[no-listing-new-tag]` |
| 322 | nothing written then | `test_check_migrations[no-listing-new-tag]` (the port checks it for all three status-2 rows of `test_check_migrations`) |
| 325 | no listing at the old tag is an environment error | `test_check_migrations[no-listing-old-tag]` |
| 328 | a non-list response is an environment error | `test_check_migrations[non-list-response]` |
| 331 | migrations kind always | `test_check_migrations_kind_always` |
| 338 | --no-write on an exception still reports it | `test_check_no_write_on_an_exception` |
| 339 | --no-write leaves pin file and scan dir identical | `test_check_no_write_on_an_exception` |
| 340 | --no-write still scanned | `test_check_no_write_on_an_exception` |
| 345 | trivy failing is an environment error | `test_check_trivy_failing_is_an_environment_error` |
| 348 | unreadable JSON from skopeo is an environment error | `test_check_unreadable_json_from_skopeo_is_an_environment_error` |
| 355 | a missing skopeo is an environment error | `test_check_a_missing_skopeo_is_an_environment_error` |
| 358 | an invalid descriptor is refused before any command runs | `test_check_refuses_an_invalid_descriptor_before_any_command` |
| 359 | no stub was called | `test_check_refuses_an_invalid_descriptor_before_any_command` |
| 367 | check passes on a manual descriptor without the deploy-only fields | `test_check_a_manual_descriptor_reads_no_deploy_only_field` |
| 368 | manual: pin file rewritten | `test_check_a_manual_descriptor_reads_no_deploy_only_field` |
| 369 | manual: record written | `test_check_a_manual_descriptor_reads_no_deploy_only_field` |

## test-image-bump-deploy.sh (67 checks)

| Line | Label | pytest id |
| --- | --- | --- |
| 164 | a clean deploy exits 0 | `test_deploy_a_clean_deploy` |
| 165 | the running image is read from the container | `test_deploy_a_clean_deploy` |
| 166 | the replaced image is looked up in the VM's storage | `test_deploy_a_clean_deploy` |
| 167 | the unit is kept as .pre-<version> | `test_deploy_a_clean_deploy` |
| 168 | the applied unit, resolved to its path, is copied in | `test_deploy_a_clean_deploy` |
| 169 | systemd is reloaded | `test_deploy_a_clean_deploy` |
| 170 | the service is restarted | `test_deploy_a_clean_deploy` |
| 171 | keep before install | `test_deploy_a_clean_deploy` |
| 172 | install before reload | `test_deploy_a_clean_deploy` |
| 173 | reload before restart | `test_deploy_a_clean_deploy` |
| 174 | restart before the checks | `test_deploy_a_clean_deploy` |
| 175 | no stop and no export when the version does not migrate | `test_deploy_a_clean_deploy` |
| 176 | no restore | `test_deploy_a_clean_deploy` |
| 177 | nothing listed as rolled back | `test_deploy_a_clean_deploy` |
| 178 | the report names the kept unit | `test_deploy_a_clean_deploy` |
| 179 | reminder: tell other users | `test_deploy_a_clean_deploy` |
| 184 | refused: applied pin is already running | `test_deploy_refuses[already-running]` |
| 185 | nothing changed on that refusal | `test_deploy_refuses[already-running]` |
| 189 | refused: the running image is not the one the record replaces | `test_deploy_refuses[running-not-replaced]` |
| 190 | nothing changed on that refusal | `test_deploy_refuses[running-not-replaced]` |
| 194 | refused: the replaced image is gone from the VM | `test_deploy_refuses[replaced-image-gone]` |
| 195 | nothing changed on that refusal | `test_deploy_refuses[replaced-image-gone]` |
| 199 | refused: the digest was rolled back before | `test_deploy_refuses[rolled-back-before]` |
| 200 | nothing changed on that refusal | `test_deploy_refuses[rolled-back-before]` |
| 204 | near miss: another digest in the rolled-back list does not stop it | `test_deploy_another_rolled_back_digest_does_not_stop_it` |
| 208 | refused: no scan record for the applied digest | `test_deploy_refuses_without_a_scan_record` |
| 209 | no podman call at all | `test_deploy_refuses_without_a_scan_record` |
| 214 | no migration, checks fail: rolled back, exit 5 | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 215 | the check was retried within the wait, then re-run after the restore | `test_deploy_rolls_back_a_service_that_never_comes_back` (exact (3) on the virtual clock; the shell suite asked for at least 3) |
| 216 | restore after the failed check | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 217 | the kept unit is restored | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 218 | reload and restart ran for the install and for the restore | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 220 | the checks re-run after the restore | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 221 | the restored service's result is reported | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 222 | the applied digest is listed as rolled back | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 224 | a second deploy of that digest refuses | `test_deploy_rolls_back_a_service_that_never_comes_back` |
| 229 | rolled back but still failing: exit 6, not 5 | `test_deploy_a_rollback_that_does_not_recover_stops_for_a_person` |
| 230 | the digest is still listed, so nothing retries it | `test_deploy_a_rollback_that_does_not_recover_stops_for_a_person` |
| 233 | the restore command itself fails: exit 6 | `test_deploy_a_restore_that_fails_stops_for_a_person` |
| 238 | migrating, checks fail: exit 6 | `test_deploy_a_migrating_version_that_fails_restores_nothing` |
| 239 | nothing restored | `test_deploy_a_migrating_version_that_fails_restores_nothing` |
| 240 | no second restart | `test_deploy_a_migrating_version_that_fails_restores_nothing` |
| 241 | not listed as rolled back | `test_deploy_a_migrating_version_that_fails_restores_nothing` |
| 246 | migrating, clean: exit 0 | `test_deploy_a_migrating_version_exports_the_volume_first` |
| 247 | the service is stopped | `test_deploy_a_migrating_version_exports_the_volume_first` |
| 248 | the volume is exported to the version-named file | `test_deploy_a_migrating_version_exports_the_volume_first` |
| 249 | stop before export | `test_deploy_a_migrating_version_exports_the_volume_first` |
| 250 | export before keep | `test_deploy_a_migrating_version_exports_the_volume_first` |
| 251 | export before install | `test_deploy_a_migrating_version_exports_the_volume_first` |
| 256 | near miss: a script install that succeeds | `test_deploy_an_install_script_that_succeeds` |
| 257 | the script ran | `test_deploy_an_install_script_that_succeeds` |
| 258 | keep before the script | `test_deploy_an_install_script_that_succeeds` |
| 259 | the script before the checks | `test_deploy_an_install_script_that_succeeds` |
| 260 | a script install is not copied or restarted by the tool | `test_deploy_an_install_script_that_succeeds` |
| 264 | a failing install script counts as a failed check: rolled back | `test_deploy_a_failing_install_script_is_rolled_back` |
| 265 | the unit is restored | `test_deploy_a_failing_install_script_is_rolled_back` |
| 266 | digest listed | `test_deploy_a_failing_install_script_is_rolled_back` |
| 270 | a failing install script on a migrating version: exit 6 | `test_deploy_a_failing_install_script_on_a_migrating_version` |
| 271 | nothing restored | `test_deploy_a_failing_install_script_on_a_migrating_version` |
| 276 | near miss: a check that passes on its second try | `test_deploy_retries_a_check_within_the_wait` |
| 277 | tried twice | `test_deploy_retries_a_check_within_the_wait` |
| 296 | deploy on a manual descriptor is refused | `test_deploy_refuses_a_manual_install_before_touching_anything` |
| 297 | step one printed, indented | `test_deploy_refuses_a_manual_install_before_touching_anything` |
| 298 | step two printed, indented | `test_deploy_refuses_a_manual_install_before_touching_anything` |
| 299 | no podman call | `test_deploy_refuses_a_manual_install_before_touching_anything` |
| 300 | no state written | `test_deploy_refuses_a_manual_install_before_touching_anything` |
| 307 | a missing podman is an environment error | `test_deploy_a_missing_podman_is_an_environment_error` |

## test-image-bump-estate.sh (89 checks)

| Line | Label | pytest id |
| --- | --- | --- |
| 304 | widget 3.1.0 passes | `test_estate_widget_passes` |
| 305 | cosign was given the bundle, the identity of this version and the issuer | `test_estate_widget_passes` |
| 306 | with the version in the identity | `test_estate_widget_passes` |
| 307 | arm pin is the verified hash at the release URL | `test_estate_widget_passes` |
| 309 | x86 pin is the verified hash at the release URL | `test_estate_widget_passes` |
| 314 | arm: exactly one line replaced | `test_estate_widget_passes` |
| 314 | x86: exactly one line replaced | `test_estate_widget_passes` |
| 315 | arm: the other pin and its comment are intact | `test_estate_widget_passes` |
| 315 | x86: the other pin and its comment are intact | `test_estate_widget_passes` |
| 318 | scan record written | `test_estate_widget_passes` |
| 320 | record names what signed what | `test_estate_widget_passes` |
| 321 | record has the arm URL and hash | `test_estate_widget_passes` |
| 322 | record has the SBOM hash | `test_estate_widget_passes` |
| 323 | record replaces 3.0.0 | `test_estate_widget_passes` |
| 324 | record says coverage | `test_estate_widget_passes` |
| 325 | record verdict | `test_estate_widget_passes` |
| 330 | an already pinned version is refused | `test_estate_widget_already_pinned` |
| 332 | near miss: --no-write continues on an already pinned version | `test_estate_widget_already_pinned` |
| 340 | a tampered checksums file is refused | `test_estate_a_tampered_checksums_file_is_refused` |
| 341 | no record | `test_estate_a_tampered_checksums_file_is_refused` |
| 342 | both pins files unchanged | `test_estate_a_tampered_checksums_file_is_refused` |
| 343 | no asset was fetched before the signature held | `test_estate_a_tampered_checksums_file_is_refused` (could never fail in the shell suite (it searched the server log for `linux.arm64 ` with a trailing space); its intent is the next row's check) |
| 344 | no asset was fetched before the signature held (server log) | `test_estate_a_tampered_checksums_file_is_refused` |
| 351 | an x86 asset with the wrong bytes is refused | `test_estate_an_asset_with_the_wrong_bytes_is_refused` |
| 352 | one architecture failing leaves both pins files unchanged | `test_estate_an_asset_with_the_wrong_bytes_is_refused` |
| 353 | no record | `test_estate_an_asset_with_the_wrong_bytes_is_refused` |
| 359 | a transfer that ends early is an environment error | `test_estate_a_transfer_cut_short_is_an_environment_error` |
| 360 | nothing written | `test_estate_a_transfer_cut_short_is_an_environment_error` |
| 372 | a validly signed file that omits an asset is refused | `test_estate_a_signed_checksums_file_that_omits_an_asset_is_refused` |
| 391 | a fixable finding with a clean current pin is refused | `test_estate_gate_a_fixable_finding_against_a_clean_pin_is_refused` |
| 392 | nothing written | `test_estate_gate_a_fixable_finding_against_a_clean_pin_is_refused` |
| 396 | a fixable finding in the x86 artifact alone is refused | `test_estate_gate_a_fixable_finding_in_one_architecture_is_refused` |
| 402 | no trivy coverage on one architecture is exit 3, never 0 | `test_estate_no_coverage_on_one_architecture_is_an_exception` |
| 405 | the record says coverage none | `test_estate_no_coverage_on_one_architecture_is_an_exception` |
| 406 | and counts the packages | `test_estate_no_coverage_on_one_architecture_is_an_exception` |
| 407 | and the verdict is exception | `test_estate_no_coverage_on_one_architecture_is_an_exception` |
| 408 | no record (else branch: the record exists) | `test_estate_no_coverage_on_one_architecture_is_an_exception` |
| 409 | the approval line says no coverage | `test_estate_no_coverage_on_one_architecture_is_an_exception` |
| 414 | a placeholder pin is moved | `test_estate_a_placeholder_pin_is_moved` |
| 416 | record: replaces none | `test_estate_a_placeholder_pin_is_moved` |
| 417 | arm line written | `test_estate_a_placeholder_pin_is_moved` |
| 423 | a first pin with a fixable finding is exit 3 | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 424 | the approval line says why | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 427 | the record's verdict is exception | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 428 | the record replaces none | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 429 | the record lists the fixable finding | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 430 | and the unfixed one | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 431 | no record (else branch: the record exists) | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 432 | the arm line is written | `test_estate_a_first_pin_with_a_fixable_finding_is_an_exception` |
| 438 | two lines for the pin in one file is refused | `test_estate_pins_files[two-lines]` |
| 442 | no line for the pin is refused | `test_estate_pins_files[no-line]` |
| 446 | pins files naming different versions are refused | `test_estate_pins_files[versions-disagree]` |
| 450 | a current pin whose bytes no longer match its hash is refused | `test_estate_pins_files[current-pin-tampered]` |
| 455 | latest: reads 3.0.0 from the arm URL and sees 3.1.0 | `test_estate_latest` |
| 457 | latest: up to date | `test_estate_latest` |
| 460 | latest: a placeholder pin has no version | `test_estate_latest_with_a_placeholder_pin` |
| 465 | deploy refuses an artifact descriptor | `test_estate_deploy_and_validate` |
| 467 | validate accepts the good descriptor | `test_estate_deploy_and_validate` |
| 471 | validate: a descriptor with no verify is refused | `test_estate_validate_refuses[no-verify]` |
| 472 | validate: an asset without {version} is refused | `test_estate_validate_refuses[asset-without-version]` |
| 473 | validate: an asset without {arch} is refused | `test_estate_validate_refuses[asset-without-arch]` |
| 474 | validate: a container field is refused | `test_estate_validate_refuses[container-field]` |
| 475 | validate: pins_files keys must match arches | `test_estate_validate_refuses[pins-files-keys]` |
| 476 | validate: a deb cannot be verified by cosign-bundle | `test_estate_validate_refuses[deb-by-cosign]` |
| 477 | validate: a cosign descriptor needs its identity | `test_estate_validate_refuses[cosign-needs-identity]` |
| 478 | validate: a missing pins line is a problem | `test_estate_validate_refuses[missing-pins-line]` |
| 484 | vector 1.1.0 passes | `test_estate_vector_passes` |
| 486 | arm deb pinned at the pool URL with the Packages hash | `test_estate_vector_passes` |
| 487 | x86 deb pinned | `test_estate_vector_passes` |
| 488 | the widget pin was left alone | `test_estate_vector_passes` |
| 490 | record names the key and the chain | `test_estate_vector_passes` |
| 491 | record: packages detected in the unpacked deb | `test_estate_vector_passes` |
| 492 | trivy scanned an unpacked directory with rootfs | `test_estate_vector_passes` |
| 494 | an already pinned deb is refused | `test_estate_vector_passes` |
| 500 | a Release signed by another key is refused | `test_estate_a_release_signed_by_another_key_is_refused` |
| 501 | nothing written | `test_estate_a_release_signed_by_another_key_is_refused` |
| 502 | no .deb was fetched | `test_estate_a_release_signed_by_another_key_is_refused` |
| 507 | a key file whose fingerprint is not the pinned one is refused | `test_estate_a_key_file_that_is_not_the_pinned_key_is_refused` |
| 514 | a Packages index that differs from the signed Release hash is refused | `test_estate_a_swapped_packages_index_is_refused` |
| 521 | an x86 .deb that does not match the signed Packages hash is refused | `test_estate_a_deb_that_does_not_match_its_packages_hash_is_refused` |
| 522 | both pins files unchanged | `test_estate_a_deb_that_does_not_match_its_packages_hash_is_refused` |
| 527 | a version absent from Packages is refused | `test_estate_a_version_absent_from_packages_is_refused` |
| 532 | a gzip-only Packages index is read | `test_estate_a_gzip_only_packages_index_is_read` |
| 533 | the .gz was the one fetched | `test_estate_a_gzip_only_packages_index_is_read` |
| 538 | InRelease is used when Release.gpg is absent | `test_estate_inrelease_is_used_without_release_gpg` |
| 541 | a clearsigned InRelease from another key is refused | `test_estate_an_inrelease_from_another_key_is_refused` |
| 556 | a gpgv that returns no signed text is refused | `test_estate_a_gpgv_that_returns_no_signed_text_is_refused` |
| 557 | and not with a traceback | `test_estate_a_gpgv_that_returns_no_signed_text_is_refused` |
| 563 | validate: an http repository is refused | `test_estate_validate_refuses_a_plain_http_repository` |
| 571 | validate: http to 127.0.0.10 is not the loopback, and is refused | `test_estate_validate_refuses_http_to_a_lookalike_of_the_loopback[127.0.0.10]` |
| 571 | validate: http to 127.0.0.1.example.invalid is not the loopback, and is refused | `test_estate_validate_refuses_http_to_a_lookalike_of_the_loopback[127.0.0.1.example.invalid]` |

## test-image-bump-latest.sh (30 checks)

| Line | Label | pytest id |
| --- | --- | --- |
| 118 | a newer patch on the pinned major | `test_latest[newer-patch]` |
| 119 | GitHub is asked per_page=50 | `test_latest[newer-patch]` |
| 124 | numeric ordering: 15.0.10 is newer than 15.0.9 | `test_latest[numeric-ordering]` |
| 129 | a newer major only is not an alert | `test_latest[newer-major-only]` |
| 134 | equal versions are up to date | `test_latest[equal]` |
| 139 | a pre-release or draft newer than current is skipped | `test_latest[prerelease-draft-skipped]` |
| 144 | a non-numeric tag is skipped, never compared | `test_latest[non-numeric-skipped]` |
| 149 | skipped tags do not hide a real newer one | `test_latest[skipped-do-not-hide]` |
| 155 | a newer patch on a Codeberg-hosted repo | `test_latest[codeberg-newer]` |
| 156 | Codeberg is asked limit=50 | `test_latest[codeberg-newer]` |
| 163 | an HTTP 500 on github | `test_latest[http-500-github]` |
| 163 | an HTTP 500 on codeberg | `test_latest[http-500-codeberg]` |
| 168 | a non-JSON body | `test_latest[non-json]` |
| 172 | a non-list releases body | `test_latest[non-list]` |
| 175 | a 404 | `test_latest[not-found]` |
| 178 | a host that does not answer | `test_latest[host-does-not-answer]` |
| 185 | a newer stable release on the latest line | `test_latest[stable-newer]` |
| 186 | the latest endpoint is asked | `test_latest[stable-newer]` |
| 191 | a newer major counts on the latest line | `test_latest[stable-newer-major]` |
| 196 | latest equal to the pin is up to date | `test_latest[stable-equal]` |
| 201 | latest line orders numerically | `test_latest[stable-numeric]` |
| 206 | a non-numeric latest tag cannot be compared | `test_latest[stable-non-numeric]` |
| 211 | the latest line on Codeberg | `test_latest[stable-codeberg]` |
| 216 | latest line: an HTTP 500 | `test_latest[stable-http-500]` |
| 220 | latest line: a body that is not a release object | `test_latest[stable-not-object]` |
| 224 | latest line: a non-JSON body | `test_latest[stable-non-json]` |
| 230 | pinned at the newest is up to date | `test_latest_with_pin` |
| 233 | --pin older makes a same-major release newer | `test_latest_with_pin` |
| 234 | --pin writes nothing | `test_latest_with_pin` |
| 236 | a non-numeric --pin is an error | `test_latest_with_pin` |
