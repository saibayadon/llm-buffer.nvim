# LLMBuffer

A Neovim plugin that provides a floating window interface for
interacting LLM models like Claude, GPT-4, and local models using Ollama.

https://github.com/user-attachments/assets/6d8e064b-2f3f-415c-be1a-131696456569

> [!WARNING]  
> This project is for personal use and in active development. Use at your own risk!
>
> The code may also be questionable since this is my first time dabbling in lua and plugin development 😅

## Features

- Floating window interface with markdown support
- Visual selection or line selection as prompt
- Streaming responses from different LLM providers
- Local model support using Ollama
- Configurable window dimensions and keybindings

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
    "saibayadon/llm-buffer.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
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
    anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"),
    openai_api_key = os.getenv("OPENAI_API_KEY"),
    ollama_api_host = "http://localhost:11434",
    provider = "anthropic", -- "anthropic" or "openai" or "ollama"
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

## Swapping providers on the fly

To swap providers on the fly, you can use the `update_options` function:

```lua
require("llm-buffer").update_options({
  provider = "openai"
  model = "gpt-4o-mini"
})
```

You can bind this to a keymap like `<leader>llo` to quickly switch between providers.

## License

MIT
