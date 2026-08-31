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
-- Mermaid rendering shells out to `mmdc` (mermaid-cli), which drives a headless
-- browser through puppeteer -- mermaid is a browser library, so there is no
-- browser-free path. Left alone, puppeteer downloads its OWN vendored Chrome
-- (~150MB) into ~/.cache/puppeteer, outside package management. Pointing it at
-- an already-installed browser means zero extra binaries on disk.
-- A value set in the environment always wins, so a terminal-level override or
-- a future chezmoi-templated value takes precedence over this fallback.
if vim.env.PUPPETEER_EXECUTABLE_PATH == nil or vim.env.PUPPETEER_EXECUTABLE_PATH == "" then
  local candidates = {
    "chromium", -- Arch: pacman-managed, preferred
    "google-chrome-stable",
    "brave",
    -- macOS app bundles: not on $PATH, so probe the binary directly.
    -- Brave is the one actually installed on the Mac; keep it listed here.
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  }
  for _, bin in ipairs(candidates) do
    local path = bin:find("/") and (vim.fn.executable(bin) == 1 and bin or "") or vim.fn.exepath(bin)
    if path ~= "" then
      vim.env.PUPPETEER_EXECUTABLE_PATH = path
      break
    end
  end
end

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
