#!/bin/sh
# Creates mise's state directory, mode 700, before each apply on a machine where mise is switched on
# and installed (.chezmoiignore holds both conditions). mise keeps its trust records there, so the
# directory is made here, by an apply, rather than by whichever mise command first needs it: an
# agent's sandbox may not write it, and an existing directory created wider is narrowed. The
# directory is found as mise finds it.
set -eu
dir=${MISE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mise}
mkdir -p "$dir"
chmod 700 "$dir"
