-- Two-tier spell wordlists.
--   zg  -> private.utf-8.add   (overlay, private, per-domain)   [entry 1, default]
--   2zg -> shared.utf-8.add    (base,    public,  fleet-wide)   [entry 2]
-- Both are loaded for checking; the count only picks the write target (:h {count}zg).
--
-- `zg` edits the DEPLOYED copy, which `chezmoi apply` would clobber. So after each
-- add/undo we re-import the wordlist back into the chezmoi SOURCE -- same pattern as
-- the lazy-lock `chezmoi re-add` autocmd in autocmds.lua. Capture != commit != push.
-- The overlay-specific chezmoi invocation lives in the `spell-capture` helper (shipped
-- by the base, targeting the overlay instance), so this config names only a generic command.

local spelldir = vim.fn.stdpath("config") .. "/spell" -- ~/.config/nvim/spell
local private = spelldir .. "/private.utf-8.add"      -- entry 1 (overlay, private)
local shared = spelldir .. "/shared.utf-8.add"        -- entry 2 (base, public)

vim.opt.spellfile = private .. "," .. shared

-- The capture helper (spell-capture) is on PATH via ~/.local/bin (~/.zshenv) on every machine
-- and context, so resolve it by name rather than a hardcoded path.
local function capture()
  if vim.fn.executable("chezmoi") == 1 then
    vim.fn.jobstart({ "chezmoi", "re-add", shared }) -- public list -> base source
  end
  if vim.fn.executable("spell-capture") == 1 then
    vim.fn.jobstart({ "spell-capture", private }) -- private list -> overlay source
  end
end

-- zg does not fire a write event (the .add file never becomes the current buffer),
-- so wrap the add/undo commands. zG/zW are intentionally NOT wrapped -- they write the
-- temporary internal word list, not a file (:h internal-wordlist).
for _, key in ipairs({ "zg", "zw", "zug", "zuw" }) do
  vim.keymap.set("n", key, function()
    local cnt = vim.v.count > 0 and tostring(vim.v.count) or ""
    vim.cmd("normal! " .. cnt .. key) -- preserves 2zg / 2zw
    vim.schedule(capture)
  end, { desc = "spell " .. key .. " + chezmoi re-add" })
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = capture }) -- backstop
