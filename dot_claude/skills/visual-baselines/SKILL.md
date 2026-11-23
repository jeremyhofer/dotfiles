---
name: visual-baselines
description: Use before recording, re-recording or committing visual-regression screenshot baselines (Playwright `toHaveScreenshot`, `--update-snapshots`, a `__screenshots__` directory), when adding a size guard for them, or when a repository's history or clone has grown large from images. Covers why each re-record stores a whole new file, committing once per landed batch, the commit-path size guard, per-section images instead of full-page ones, measuring growth, and what Git LFS needs before it is safe, including why every git-based size check reads the ~130-byte pointer once images are in LFS (a size guard that never fires, a growth gauge at zero) and why a history rewrite breaks every cited commit hash.
---

# Visual-regression baselines in git

## Why baselines grow history fast

A baseline is a compressed image (usually PNG). Git stores each version of a file as a whole object and
saves space only by delta-compressing similar objects against each other. Compressed images defeat that: a
small visual change alters the compressed bytes throughout the file, so every re-record stores a near-full
new copy, forever. A full-page image amplifies it. A one-sentence copy edit can change a fraction of a percent
of a page's pixels and still commit a new multi-megabyte file. History then grows by roughly
(image size × images re-recorded × re-record commits), and a clone downloads all of it.

So the lever is how often, and how much, gets re-recorded and committed. The storage mechanism comes second.

## The practices

1. **Commit baselines once per landed batch, never once per review round.** Re-record as often as review needs,
   but review from the images the test run produced (the CI node's artifacts, or a local run's output
   directory), not from commits. Commit the final set once, when the change lands. Ten review rounds
   committed are ten full copies in history; one landed batch is one.
2. **Guard the commit path.** A pre-commit check sums the bytes of staged baseline images and refuses a commit
   over a threshold the repository sets, with an explicit override for a deliberate full re-record (an
   environment variable or a commit trailer, named in the refusal message). The guard makes the expensive
   commit a decision, not an accident. It belongs on the commit path, not in a lint lane that an unrelated
   failure can stop.
3. **Record per-section images, not one full-page image.** Screenshot each stable page section (an element
   screenshot keyed on a stable selector), so a change re-records only the section it touched. The cost: you
   lose coverage of the spacing between sections and of total page height, and the number of files to review
   goes up once. Keep a cheap structural check for layout if that coverage matters. Changes that move
   everything (a header, a design-system bump) still re-record every section, which is correct.
4. **Git LFS only once its prerequisites hold.** LFS (Large File Storage) commits a small pointer file and keeps
   the image bytes on the forge's LFS store. History and clones stop growing, but the store grows at the same
   rate, and some things move with the bytes:
   - **The store needs its own backup.** A mirror or backup made by `git fetch` or `git clone --mirror` copies
     pointers, not LFS objects, and a clone holds only the objects its checkout needed. Until the store is
     backed up on a schedule and a restore has been tested, an LFS object may exist in one place only.
   - **Every clone and the CI runner need `git-lfs` installed and its hooks active.** Without them a checkout
     contains pointer text where images should be, and tests fail confusingly.
   - **Do not assume the forge rejects a broken push.** Some forges accept a commit whose LFS object never
     arrived (Forgejo, measured on 15.0.6), so a client pushing with hooks skipped can publish dangling
     pointers that break other checkouts.
   - **Adopt forward-only.** `.gitattributes` routes new commits to LFS and leaves old history as it is.
     Converting old history (`git lfs migrate import`, `git filter-repo`) is a rewrite (see "A history
     rewrite breaks every cited commit hash" below).
   - **Every size check goes blind, and stays green.** Once an image is in LFS, its git blob is the pointer,
     about 130 bytes, so anything that sizes files through git reads the pointer and not the image:
     `git cat-file -s`, `--batch-check` with `%(objectsize)`, the sizes in `git log --raw`. The commit-path
     guard (practice 2) then sums 130 bytes per staged image and can never fire, and a growth gauge reads
     near zero. Nothing errors. Read each image's size from its pointer instead (see "Reading an image's
     size through an LFS pointer" below). Then stage an LFS image over the threshold and see the guard
     refuse it before trusting the guard again.

## Measure before and after

Bytes on disk per directory, summed over every object in history:

```sh
git rev-list --objects --all \
  | git cat-file --batch-check='%(objecttype) %(objectsize:disk) %(rest)' \
  | awk '$1 == "blob" { n = split($3, p, "/"); d = (n > 1) ? p[1] "/" p[2] : $3; s[d] += $2 }
         END { for (d in s) printf "%10.1f MB  %s\n", s[d] / 1048576, d }' \
  | sort -rn | head -20
```

The monthly growth rate is the number to track, not the total. Re-measure after each practice is adopted.
In a repository using LFS this counts what clones and history hold, which is pointers. The LFS store still
grows at the images' rate, and measuring that needs each pointer's `size` line (next section).

### Reading an image's size through an LFS pointer

A pointer is a text blob that begins with the line `version https://git-lfs.github.com/spec/v1` and
records the image's byte count on a `size <N>` line. The LFS specification requires a pointer to be under
1024 bytes, so test both: a blob of 1024 bytes or more is content, whatever its first line says.

```text
version https://git-lfs.github.com/spec/v1
oid sha256:10b38acb02c80b3951f5de8feb4b04ace9f357546461effced931ee700f37cde
size 50000
```

Git sizes that blob at 130 bytes, and the image it stands for is 50,000. To read many blobs in one
process, use `git cat-file --batch`. Each object arrives as a `<name> <type> <size>` header line, then
exactly `<size>` bytes and a newline. Walk that output by **byte** offsets. The header counts bytes, so
stepping through decoded characters falls out of alignment at the first multi-byte character and misreads
every object after it.

## A history rewrite breaks every cited commit hash

Shrinking existing history means rewriting it, and a rewrite changes every commit's hash from the first
rewritten commit onward. Commit messages, documents, issues and other repositories that cite those hashes
then point at nothing. Signed commits need re-signing, tags move, and every existing clone on every machine
has to be replaced, not pulled.

If a rewrite is done anyway, keep the old citations resolvable: `git filter-repo` writes an old-to-new map to
`.git/filter-repo/commit-map` (and `ref-map`). Commit that map next to the repository's documents in the same
sitting. It is the only record of which new commit an old hash became.

---

If `~/.dotlocal/skills/visual-baselines.md` exists, read it: it is this domain's half (its forge's LFS state,
where its baselines are recorded, and the thresholds its repositories use).
