# Case no-symlink, run by `seam-probe run|red worktree-takeover no-symlink`.
#
# Walks <repo>/.claude/worktrees for every repository the fleet manifest declares whose directory
# exists and holds a .git, and fails on any symlink from the repository root down. The manifest is
# $FLEET_RECORD, else the nearest of mani's four names at or above the directory the run was started
# from, else ~/Devel/mani.yaml, read through fleet-decl (as claude-trust-check reads it).
#
# Control: a clean fixture repository must pass the same walk, or the case is VOID.
# Plants ($SEAM_PROBE_PLANT): symlink-dotclaude and symlink-worktrees add a fixture whose .claude,
# or whose .claude/worktrees, is a symlink to the list (each must make the case FAIL);
# control-symlinked breaks the clean control (the case must come out VOID).
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
tab=$(printf '\t')

symlinked() { # <name> <component>: a fixture whose <component> (.claude or .claude/worktrees) is a symlink
  local repo
  repo=$("$sp" fixture repo "$1") || return 1
  case $2 in
    .claude) mkdir -p "$repo/seam-probe-real/worktrees"; ln -s seam-probe-real "$repo/.claude" ;;
    .claude/worktrees) mkdir -p "$repo/.claude" "$repo/seam-probe-real"; ln -s ../seam-probe-real "$repo/.claude/worktrees" ;;
  esac
  printf '%s\n' "$repo"
}

# The control, adjacent to the case.
if [ "$plant" = control-symlinked ]; then
  clean=$(symlinked clean .claude) || { "$sp" verdict INCONCLUSIVE "the clean fixture could not be built"; exit 0; }
else
  clean=$("$sp" fixture repo clean) || { "$sp" verdict INCONCLUSIVE "the clean fixture could not be built"; exit 0; }
  mkdir -p "$clean/.claude/worktrees"
fi
if ! out=$("$sp" evidence no-symlink "$clean" .claude/worktrees); then
  "$sp" verdict VOID "the clean fixture failed the walk: $out"; exit 0
fi

# The manifest.
rec=${FLEET_RECORD:-}
if [ -z "$rec" ]; then
  d=${SEAM_PROBE_CALLER_PWD:-$PWD}
  while :; do
    # mani's four names, in its order within a directory; the nearest directory wins.
    for n in mani.yaml mani.yml .mani.yaml .mani.yml; do
      if [ -f "$d/$n" ]; then rec=$d/$n; break; fi
    done
    [ -n "$rec" ] && break
    [ "$d" = / ] && break
    d=$(dirname "$d")
  done
  if [ -z "$rec" ] && [ -f "$HOME/Devel/mani.yaml" ]; then rec=$HOME/Devel/mani.yaml; fi
fi
[ -n "$rec" ] || { "$sp" verdict INCONCLUSIVE "no fleet manifest found (set FLEET_RECORD)"; exit 0; }
command -v fleet-decl >/dev/null 2>&1 || { "$sp" verdict INCONCLUSIVE "fleet-decl is not installed"; exit 0; }
mdir=$(cd "$(dirname "$rec")" && pwd)
rc=0
list=$(FLEET_RECORD=$rec fleet-decl --values path 2>&1) || rc=$?
[ "$rc" -le 1 ] || { "$sp" verdict INCONCLUSIVE "the manifest cannot be read: $list"; exit 0; }

repos=""
while IFS=$tab read -r name dir; do
  [ -n "$name" ] && [ -n "$dir" ] || continue
  case $dir in /*) ;; *) dir=$mdir/$dir ;; esac
  [ -e "$dir/.git" ] || continue
  repos="$repos$name$tab$dir
"
done <<LIST
$list
LIST
planted=""
case $plant in
  symlink-dotclaude) planted=$(symlinked planted .claude) ;;
  symlink-worktrees) planted=$(symlinked planted .claude/worktrees) ;;
esac
if [ -n "$plant" ] && [ "$plant" != control-symlinked ] && [ -z "$planted" ]; then
  "$sp" verdict INCONCLUSIVE "the planted fixture could not be built"; exit 0
fi
[ -z "$planted" ] || repos="${repos}planted$tab$planted
"
[ -n "$repos" ] || { "$sp" verdict INCONCLUSIVE "the manifest declares no repository present on this machine"; exit 0; }

n=0; bad=""; notes=""
while IFS=$tab read -r name dir; do
  [ -n "$name" ] || continue
  n=$((n + 1))
  if ! out=$("$sp" evidence no-symlink "$dir" .claude/worktrees); then
    bad="$bad $name ($(printf '%s\n' "$out" | sed -n 's/^symlink: //p'))"
  fi
  case $out in *"note: a symlink at or above"*) notes="$notes $name" ;; esac
done <<LIST
$repos
LIST
extra=""; [ -z "$notes" ] || extra="; a symlink at or above the root of:$notes"
if [ -n "$bad" ]; then
  "$sp" verdict FAIL "a symlink on the path in:$bad$extra"
else
  "$sp" verdict PASS "$n repositories checked, no symlink from the root down$extra"
fi
