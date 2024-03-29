local M = {}

function M.get_domain_config()
  local base_config = {
    plugins = {
      projections = {
        workspaces = {
        }
      }
    }
  }

  local config = vim.deepcopy(base_config)
  local has_home, home = pcall(require, 'domain.home')
  local has_work, work = pcall(require, 'domain.work')

  if has_home then
    config = vim.tbl_deep_extend("force", config, home)
    home.setup_autocmds()
  end

  if has_work then
    config = vim.tbl_deep_extend("force", config, work)
    work.setup_autocmds()
  end

  return config
end

return M
