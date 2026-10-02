#!/bin/sh
# Install the pinned skills a private layer declares in ~/.dotlocal/skill-externals.yaml.
#
# Runs after EVERY base apply (run_after_, not run_onchange_): the list belongs to the private layer,
# which applies after the base, so nothing in this source changes when the list does. The tool costs
# no network when every pin matches what it recorded, so running each time is cheap. A private layer
# that changes its list re-runs the tool from its own apply (overlay-skeleton has the script).
#
# A failed entry never fails the apply: the tool reports it and keeps the previous install, and this
# script returns 0 so the rest of the apply is not marked failed for a skill.
tool="$HOME/.local/bin/skill-externals-sync"
[ -x "$tool" ] || exit 0
"$tool" || printf 'skill-externals: one or more private skills did not install (reasons above); the rest of the apply is unaffected.\n' >&2
exit 0
