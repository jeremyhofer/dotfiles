return {
  "neovim/nvim-lspconfig",
  opts = {
    setup = {
      angularls = function(_, opts)
        opts.root_dir = require("lspconfig.util").root_pattern("angular.json", "nx.json")
        require("lspconfig").angularls.setup({ { server = opts } })
      end,
    },
  },
}
