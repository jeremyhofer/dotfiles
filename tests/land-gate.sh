#!/bin/sh
# land-gate -- the gate that runs before work lands on the integration branch.
#
# Set once per clone, from a terminal (git config is not committed):
#   git config land.gate 'sh tests/land-gate.sh'
# after which `land check` runs this on a clean tree and `land` moves the branch only onto a tree
# that passed.
#
# It is every suite (tests/run-all.sh) with RUN_MUTANTS=1, so the slow checks a normal run leaves out
# also run: a suite that ships mutant meta-tests (test-image-bump.py, test-fleet-canonicals-requests.py) deselects them unless it is
# given that variable. The commit gate, the pre-apply and post-apply runs and the suite run by hand
# leave them out. Arguments are passed to run-all.sh (a filter, or --only <suite>...).
# POSIX sh only.
set -u
here=$(cd "$(dirname "$0")" && pwd)
RUN_MUTANTS=1; export RUN_MUTANTS
exec sh "$here/run-all.sh" "$@"
