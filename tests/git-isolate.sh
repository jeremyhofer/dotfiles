# Sourced (`. "$(dirname "$0")/git-isolate.sh"`) by run-all.sh and by every suite that fires git
# hooks (commit, merge, am, rebase, push), so each works the same alone as under the runner.
# Makes git ignore the machine's global and system config; see git-isolated.gitconfig.
#
# A suite that builds its own scratch HOME or GIT_CONFIG_GLOBAL afterwards simply overrides these.
# $0 is the suite (sh, bash) or this file (zsh); both live in tests/.
if [ -z "${TEST_GIT_ISOLATED:-}" ]; then
  GIT_CONFIG_GLOBAL=$(cd "$(dirname "$0")" && pwd)/git-isolated.gitconfig
  GIT_CONFIG_NOSYSTEM=1
  TEST_GIT_ISOLATED=1
  export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM TEST_GIT_ISOLATED
fi
