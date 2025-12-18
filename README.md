# dirty-review.nvim

Review uncommitted git changes in a markdown buffer with inline comments. Re-run to refresh while preserving your comments (stale comments are marked when hunks change).

## Install

Copy `install/dirty-review.lua` to `~/.config/nvim/lua/plugins/`, or add manually:

```lua
return {
  "ahmedalhulaibi/dirty-review.nvim",
  config = function()
    require("dirty-review").setup()
  end,
}
```

## Keymaps

| Key | Description |
|-----|-------------|
| `<leader>gR` | Open/refresh dirty review buffer |
| `<leader>yL` | Copy file path with line number (supports visual selection) |

## Config
```lua
require("dirty-review").setup({
  keymap_review = "<leader>gR",
  keymap_copy_path = "<leader>yL",
})
```
