-- Two-tier spell wordlists.
--   zg  -> personal.utf-8.add  (overlay, private, per-domain)   [entry 1, default]
--   2zg -> shared.utf-8.add    (base,    public,  fleet-wide)   [entry 2]
-- Both are loaded for checking; the count only picks the write target (:h {count}zg).
--
-- `zg` edits the DEPLOYED copy, which `chezmoi apply` would clobber. So after each
-- add/undo we re-import the wordlist back into the chezmoi SOURCE -- same pattern as
-- the lazy-lock `chezmoi re-add` autocmd in autocmds.lua. Capture != commit != push.
-- The overlay-specific chezmoi invocation lives in the overlay-shipped `spell-capture`
-- helper, so this public-base config names only a generic command.

local spelldir = vim.fn.stdpath("config") .. "/spell" -- ~/.config/nvim/spell
local personal = spelldir .. "/personal.utf-8.add"    -- entry 1 (overlay, private)
local shared = spelldir .. "/shared.utf-8.add"        -- entry 2 (base, public)

vim.opt.spellfile = personal .. "," .. shared

-- The overlay always deploys the private-capture helper to this fixed path; call it
-- by absolute path rather than via $PATH (which isn't guaranteed on every machine).
local spell_capture = vim.fn.expand("~/.dotlocal/bin/spell-capture")

local function capture()
  if vim.fn.executable("chezmoi") == 1 then
    vim.fn.jobstart({ "chezmoi", "re-add", shared }) -- public list -> base source
  end
  if vim.fn.executable(spell_capture) == 1 then
    vim.fn.jobstart({ spell_capture, personal }) -- private list -> overlay source
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
