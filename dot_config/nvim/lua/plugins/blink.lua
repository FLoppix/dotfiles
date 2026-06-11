require('blink.cmp').setup({
  keymap = {
    preset = 'default',
    ['<C-space>'] = { 'show', 'show_documentation', 'hide_documentation' },
    ['<C-e>'] = { 'hide', 'fallback' },
    ['<Tab>'] = { 'select_next', 'fallback' },
    ['<S-Tab>'] = { 'select_prev', 'fallback' },
    ['<CR>'] = { 'accept', 'fallback' },
    ['<C-b>'] = { 'scroll_documentation_up', 'fallback' },
    ['<C-f>'] = { 'scroll_documentation_down', 'fallback' },
  },

  appearance = {
    nerd_font_variant = 'normal',
    kind_icons = {
      Text = '󰉿',
      Method = '󰊕',
      Function = '󰊕',
      Constructor = '󰒓',
      Field = '󰜢',
      Variable = '󰆦',
      Property = '󰖷',
      EnumMember = '󰦨',
      Enum = '󰦨',
      Constant = '󰏿',
      Class = '󱉟',
      Interface = '󰜢',
      Struct = '󱉟',
      Module = '󰅩',
      Unit = '󰪚',
      Value = '󰦨',
      Keyword = '󰻠',
      Snippet = '󱄽',
      Color = '󰏘',
      File = '󰈔',
      Reference = '󰬲',
      Folder = '󰉋',
      Event = '󱐋',
      Operator = '󰪚',
      TypeParameter = '󰬛',
    },
  },

  completion = {
    menu = {
      border = 'rounded',
      draw = {
        columns = {
          { 'kind_icon' },
          { 'label', 'label_description', gap = 1 },
        },
      },
    },
    documentation = {
      auto_show = true,
      auto_show_delay_ms = 200,
      window = { border = 'rounded' },
    },
  },

  sources = {
    default = { 'lsp', 'path', 'snippets', 'buffer' },
    providers = {
      lsp = {
        name = 'LSP',
        module = 'blink.cmp.sources.lsp',
        score_offset = 100,
        transform_items = function(_, items)
          -- Filter: only show functions, methods, classes, constructors, interfaces, structs
          local allowed_kinds = {
            [vim.lsp.protocol.CompletionItemKind.Function] = true,
            [vim.lsp.protocol.CompletionItemKind.Method] = true,
            [vim.lsp.protocol.CompletionItemKind.Class] = true,
            [vim.lsp.protocol.CompletionItemKind.Constructor] = true,
            [vim.lsp.protocol.CompletionItemKind.Interface] = true,
            [vim.lsp.protocol.CompletionItemKind.Struct] = true,
          }
          local filtered = {}
          for _, item in ipairs(items) do
            if allowed_kinds[item.kind] then
              table.insert(filtered, item)
            end
          end
          return filtered
        end,
      },
    },
  },

  fuzzy = {
    implementation = 'prefer_rust_with_warning',
  },
})
