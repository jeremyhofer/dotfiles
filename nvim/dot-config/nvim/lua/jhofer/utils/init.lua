local M = {}

-- helper function for key bindings
local function bind(op, outer_opts)
  outer_opts = outer_opts or {noremap = true}
  return function(lhs, rhs, opts)
    opts = vim.tbl_extend(
      "force",
      outer_opts,
      opts or {}
    )
    vim.keymap.set(op, lhs, rhs, opts)
  end
end

M.nnoremap = bind('n')
M.vnoremap = bind('v')
M.tnoremap = bind('t')

return M
