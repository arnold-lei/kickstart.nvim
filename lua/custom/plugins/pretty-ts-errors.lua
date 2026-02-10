return {
  {
    'youyoumu/pretty-ts-errors.nvim',
    opts = {
      -- Add vue_ls and vtsls as supported sources
      sources = { 'typescript', 'ts', 'vtsls', 'vue_ls', 'vue' },
    },
    ft = { 'typescript', 'typescriptreact', 'javascript', 'javascriptreact', 'vue' },
    config = function()
      local diagnostic = require 'pretty-ts-errors'
      -- Show error under cursor
      vim.keymap.set('n', '<leader>ts', function()
        diagnostic.show_formatted_error()
      end, { desc = 'Show TS error' })

      -- Show all errors in file
      vim.keymap.set('n', '<leader>tS', function()
        diagnostic.open_all_errors()
      end, { desc = 'Show all TS errors' })

      -- Toggle auto-display
      vim.keymap.set('n', '<leader>te', function()
        diagnostic.toggle_auto_open()
      end, { desc = 'Toggle TS error auto-display' })
    end,
  },
}
