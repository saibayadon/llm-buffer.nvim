# LLMBuffer

A Neovim plugin that provides a floating window interface for
interacting with Anthropic's Claude AI Model.

> [!WARNING]  
> This project is for personal use and in active development. Use at your own risk!

## Features

- Floating window interface with markdown support
- Visual selection support for prompts
- Streaming responses from Claude
- Configurable window dimensions and keybindings
- Automatic session cleanup

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
    "saibayadon/llm-buffer.nvim",
    name = "llm-buffer.nvim",
    config = function()
      require("llm-buffer").setup()
    end,
}
```

## Configuration

Ensure you have an Anthropic API key set as an environment variable.

```bash
export ANTHROPIC_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

```lua
require("llm-buffer").setup({
    window_width = 0.8, -- Width as percentage of editor width
    window_height = 0.8, -- Height as percentage of editor height
    anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"), -- Your Anthropic API key
    model = "claude-3-5-sonnet-20241022", -- Claude model to use
    mappings = {
      send_prompt = "<C-l>",
      close_window = "q",
      toggle_window = "<leader>llm"
    }
})
```

## Default Keybindings

- `<leader>llm` Toggle the LLM buffer window
- `<C-l>` Send current line or visual selection as the prompt.
- `q` Close the buffer window.
- `<Esc>` Cancel ongoing request (closing the buffer will do this as well).

You can also use the `:LLMBuffer` command to toggle the window.

## License

MIT
