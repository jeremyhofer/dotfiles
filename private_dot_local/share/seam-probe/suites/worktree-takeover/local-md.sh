# Case local-md, run by `seam-probe run|red worktree-takeover local-md`.
#
# A fixture repository whose root holds an untracked CLAUDE.local.md carrying a codeword, and a
# worktree made with git at <repo>/.claude/worktrees/lmd, the location under test. One headless
# session (`claude -p`, tools off, so it can learn a codeword only from its context) is started in
# the worktree and asked to list every codeword it can see. The reply is the evidence: a codeword is
# a fresh random token, so the model cannot produce it from anything but the file.
#
# Controls, in the same session: the root CLAUDE.md's codeword must be seen (positive: the model
# reports its context), a codeword in a file nothing references must not be (negative: it reports
# only its context). Either coming out otherwise makes the case VOID.
# Plants ($SEAM_PROBE_PLANT): local-moved puts CLAUDE.local.md in a directory that is not on the
# worktree's path to the root (must FAIL); positive-absent takes the codeword out of CLAUDE.md, and
# negative-referenced imports the unreferenced file from CLAUDE.md (each must make the case VOID).
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
nonce=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
cw() { printf 'SPROBE-%s-%s' "$1" "$nonce"; }
git=$(command -v git) || { "$sp" verdict SKIPPED "git is not installed"; exit 0; }

repo=$("$sp" fixture repo lmd) || { "$sp" verdict INCONCLUSIVE "the fixture could not be built"; exit 0; }
if [ "$plant" = positive-absent ]; then
  printf '# Fixture\n\nNothing to note.\n' > "$repo/CLAUDE.md"
else
  printf '# Fixture\n\nThe project codeword is %s.\n' "$(cw ROOT)" > "$repo/CLAUDE.md"
fi
[ "$plant" = negative-referenced ] && printf '\n@unreferenced.md\n' >> "$repo/CLAUDE.md"
printf 'The unreferenced codeword is %s.\n' "$(cw NEG)" > "$repo/unreferenced.md"
if ! { "$git" -C "$repo" add CLAUDE.md unreferenced.md && "$git" -C "$repo" commit -q -m "instructions" \
       && "$git" -C "$repo" push -q origin main; } >/dev/null 2>&1; then
  "$sp" verdict INCONCLUSIVE "the fixture's instruction files could not be committed"; exit 0
fi
wt=$("$sp" fixture worktree "$repo" lmd) || { "$sp" verdict INCONCLUSIVE "the worktree could not be made"; exit 0; }

# The subject: untracked, at the root, so the worktree has no copy.
dest=$repo
if [ "$plant" = local-moved ]; then dest=$repo/elsewhere; mkdir -p "$dest"; fi
printf 'The local codeword is %s.\n' "$(cw LOCAL)" > "$dest/CLAUDE.local.md"
if ! out=$("$sp" evidence path "$wt/CLAUDE.local.md" --absent); then
  "$sp" verdict INCONCLUSIVE "the worktree has a CLAUDE.local.md of its own: $out"; exit 0
fi

ask='List every token in your context that contains the text SPROBE- , whether it appears in project files or instructions. Output only those tokens, one per line, with nothing else. If there are none, output NONE.'
rc=0
reply=$("$sp" session ask lmd --regime "$SEAM_PROBE_REGIME" --cwd "$wt" -- "$ask") || rc=$?
case $rc in
  0) ;;
  4) "$sp" verdict REFUSED "the model declined the prompt"; exit 0 ;;
  *) "$sp" verdict INCONCLUSIVE "the headless session failed (exit $rc)"; exit 0 ;;
esac

neg=$("$sp" evidence codeword "$reply" "$(cw NEG)"); nrc=$?
pos=$("$sp" evidence codeword "$reply" "$(cw ROOT)"); prc=$?
loc=$("$sp" evidence codeword "$reply" "$(cw LOCAL)"); lrc=$?
if [ "$nrc" -eq 3 ] || [ "$prc" -eq 3 ] || [ "$lrc" -eq 3 ]; then
  "$sp" verdict INCONCLUSIVE "the reply could not be read"; exit 0
fi
[ "$nrc" -ne 0 ] || { "$sp" verdict VOID "negative control: the unreferenced file's codeword was seen ($neg)"; exit 0; }
[ "$prc" -eq 0 ] || { "$sp" verdict VOID "positive control: the root CLAUDE.md's codeword was not seen ($pos)"; exit 0; }
if [ "$lrc" -eq 0 ]; then
  "$sp" verdict PASS "the root's untracked CLAUDE.local.md reached a session in the nested worktree; controls behaved"
else
  "$sp" verdict FAIL "the root's CLAUDE.local.md did not reach a session in the nested worktree; controls behaved"
fi
