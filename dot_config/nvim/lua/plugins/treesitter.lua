-- Extra treesitter parsers beyond the LazyVim defaults (fleet-wide).
-- list_extend augments the default ensure_installed set rather than replacing it.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, {
        "latex",
        "norg",
        "svelte",
        "typst",
      })
    end,
  },
}
