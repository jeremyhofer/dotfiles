# My lovely dotfiles

Move commits to master:
```sh
# first HEAD~ arg should be last commit to keep in place, to -1 of commits to move
git rebase --onto master HEAD~ HEAD
git checkout -b to_merge
git checkout master
git merge to_merge
git branch -d to_merge
git checkout home
git rebase master
```

Push master:
```sh
# sanity check I didn't move over anything sensitive
git diff origin/master master
git push origin master && git push github master
```
