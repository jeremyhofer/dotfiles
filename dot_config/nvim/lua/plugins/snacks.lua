-- Pinned to a fork carrying the fix for upstream snacks.nvim issue #2896:
-- `placement:update()` calls `hide()` (setting `hidden = true`) when a buffer
-- has no visible windows, but nothing cleared the flag when the buffer came
-- back into view. `_render()` strips virt_text/conceal while `hidden` is set,
-- so the image went blank after a buffer switch, and opening a second image
-- blanked the first. Upstream PRs #2793 and #2635 both fix it; neither is
-- merged. The `pending-upstream` branch carries local patches on top of
-- upstream main. REMOVE this pin (and the fork) once one of those lands.
--
-- Hosted on GITHUB deliberately, and it is the one plugin here that is: lazy.nvim clones this
-- on every machine including the work laptop, where no personal account can be logged into --
-- so the URL must resolve to an ANONYMOUS, unauthenticated HTTPS clone. That is the same
-- constraint that puts the public dotfiles base on github, and it is the reason this line did
-- not simply follow everything else to the self-hosted forge.
--
-- Moved off sourcehut 2026-08-30, whose terms now prohibit LLM-produced content. Note the fork
-- itself was a clean fork of upstream, so the `pending-upstream` branch had to be pushed to it
-- separately -- swapping the URL alone would either fail on a missing branch or, worse, silently
-- fall back to plain upstream and bring the image bug back with nothing to indicate why.
return {
  "snacks.nvim",
  url = "https://github.com/jeremyhofer/snacks.nvim",
  branch = "pending-upstream",
  opts = {
    image = {
      -- opt-in (LazyVim/snacks default it off). Enables the image viewer: direct-open
      -- image files + inline images in docs (needs a kitty-graphics terminal like ghostty).
      enabled = true,
    },
    words = {
      enabled = false,
    },
  },
}
