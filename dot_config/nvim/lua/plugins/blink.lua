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
          { 'kind_icon', 'label', 'label_description', gap = 1 },
          { 'kind' },
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
  },

  fuzzy = {
    implementation = 'prefer_rust_with_warning',
  },
})
