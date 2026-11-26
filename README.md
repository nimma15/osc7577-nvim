# osc7577.nvim

A neovim plugin that implements support of the [Program Resume Protocol (OSC 7577)](https://www.superlogical.com/rex/docs/build/program-resume), with private recovery snapshots for unsaved buffer text.

Original files are never written automatically. Without `OSC7577_TOKEN` in the environment, the plugin does nothing.

## Installation

Requires Neovim 0.10 or newer. No dependencies or build needed.

### lazy.nvim

```lua
{
  "nimma15/osc7577-nvim",
  main = "osc7577",
  lazy = false,
  opts = {},
}
```

### Other plugin managers

The plugin is plain Lua on the runtimepath:

```vim
Plug "nimma15/osc7577-nvim"
```

or clone the repository into any directory on your `runtimepath`.

### Setup

```lua
require("osc7577").setup()
```

The plugin also sets itself up with defaults when loaded normally. Set `vim.g.osc7577_auto_setup = false` before it loads if you only want manual setup. All options are optional; see the `defaults()` table in `lua/osc7577/init.lua` for the full list.

### Rex

This plugin is tested with Rex only!

For Rex, add a resume rule to `~/.config/rex/init.lua`

```lua
rex.set("resume.trust.nvim", {
  command = { "nvim", "-S", rex.match.under("~/.local/state/nvim/osc7577") },
})
```

The rule is scoped to the plugin's private session directory, so a session saved anywhere else is never resumed.


