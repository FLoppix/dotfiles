local wk = require("which-key")

wk.setup({
  delay = 500,
})

wk.add({
  { "<leader>f", group = "Find" },
  { "<leader>c", group = "Code" },
  { "<leader>t", group = "Terminal" },
})
