local M = {}
local Job = require("plenary.job")
local active_job = nil
local llm_buf = nil
local llm_win = nil
local was_cancelled = false

local function get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))
	local mode = vim.fn.mode()

	if mode == "V" then
		local start, stop = srow > erow and erow - 1 or srow - 1, srow > erow and srow or erow
		return vim.api.nvim_buf_get_lines(0, start, stop, true)
	end

	if mode == "v" then
		if srow > erow or (srow == erow and scol > ecol) then
			srow, erow, scol, ecol = erow, srow, ecol, scol
		end
		return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
	end

	if mode == "\22" then
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		local lines = {}
		for i = srow, erow do
			table.insert(lines, vim.api.nvim_buf_get_text(0, i - 1, scol - 1, i - 1, ecol, {})[1])
		end
		return lines
	end
end

local function write_to_buffer(str)
	vim.schedule(function()
		local current_window = vim.api.nvim_get_current_win()
		local cursor_position = vim.api.nvim_win_get_cursor(current_window)
		local row, col = cursor_position[1], cursor_position[2]

		local lines = vim.split(str, "\n")

		vim.cmd("undojoin")
		vim.api.nvim_put(lines, "c", true, true)

		local num_lines = #lines
		local last_line_length = #lines[num_lines]
		vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
	end)
end

-- Configuration
M.defaults = {
	window_width = 0.8,
	window_height = 0.8,
	anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"),
	model = "claude-3-5-sonnet-20241022",
	system_prompt = [[
    You are a helpful assistant. You are an expert in the field of computer science and software development.
    You have a deep understanding of the topic and are able to provide accurate and helpful information.
    You currently reside inside a Markdown file buffer in neovim - use proper markdown syntax to answer the user's question. 
    Any code examples should be formatted in markdown as well.
    Be concise and to the point.
    If you don't know the answer, just say that you don't know, don't try to make up an answer.
  ]],
	mappings = {
		send_prompt = "<C-l>",
		close_window = "q",
		toggle_window = "<leader>llm",
	},
}

-- Create the floating window
local function create_floating_window()
	local width = math.floor(vim.o.columns * M.config.window_width)
	local height = math.floor(vim.o.lines * M.config.window_height)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local opts = {
		relative = "editor",
		style = "minimal",
		row = row,
		col = col,
		width = width,
		height = height,
		border = "rounded",
	}

	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.bo[buf].filetype = "markdown"

	local win = vim.api.nvim_open_win(buf, true, opts)

	-- Set window options
	vim.wo[win].wrap = true

	llm_buf = buf
	llm_win = win

	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		M.config.mappings.send_prompt,
		[[<cmd>lua require('llm-buffer').send_prompt()<CR>]],
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		buf,
		"v",
		M.config.mappings.send_prompt,
		[[<cmd>lua require('llm-buffer').send_prompt()<CR>]],
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		M.config.mappings.close_window,
		[[<cmd>lua vim.api.nvim_win_close(0, true)<CR>]],
		{ noremap = true, silent = true }
	)

	return buf, win
end

-- Function to stream response from Anthropic API
local function stream_anthropic_response(prompt)
	-- Ensure we have an API key
	if not M.config.anthropic_api_key then
		vim.notify("Anthropic API key not set. Please set it in your Neovim config file.", vim.log.levels.ERROR)
		return
	end

	-- Create request body
	local body = {
		system = M.config.system_prompt,
		messages = {
			{
				role = "user",
				content = prompt,
			},
		},
		model = M.config.model,
		max_tokens = 2000,
		stream = true,
	}

	-- Make the request
	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"x-api-key: " .. M.config.anthropic_api_key,
		"-H",
		"anthropic-version: 2023-06-01",
		"-d",
		vim.fn.json_encode(body),
		"https://api.anthropic.com/v1/messages",
	}

	-- Parse response
	local c_event = nil
	local function parse_response_line(line)
		local event = line:match("^event: (.+)$")
		if event then
			c_event = event
			return
		end
		local data = line:match("^data: (.+)$")
		if data then
			if c_event == "content_block_delta" then
				local json = vim.json.decode(data)
				if json.delta and json.delta.text then
					write_to_buffer(json.delta.text)
				end
			end
		end
	end

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	active_job = Job:new({
		command = "curl",
		args = args,
		on_start = function()
			vim.notify("LLM Request Started", vim.log.levels.DEBUG)
		end,
		on_stdout = function(_, out)
			parse_response_line(out)
		end,
		on_stderr = function(_, _) end,
		on_exit = function(_, code)
			-- If the job was cancelled, don't log anything
			if was_cancelled == false then
				if code ~= 0 then
					vim.notify("LLM Request Failed", vim.log.levels.ERROR)
				else
					vim.notify("LLM Request Completed", vim.log.levels.INFO)
				end
			else
				vim.notify("LLM Request Cancelled", vim.log.levels.INFO)
			end
			active_job = nil
			was_cancelled = false
		end,
	})

	active_job:start()

	-- Cancel the job if the user closes the window
	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = llm_buf,
		callback = function()
			if active_job then
				was_cancelled = true
				active_job:shutdown()
				active_job = nil
			end
		end,
	})

	-- Cancel the job if the user presses <Esc> in any mode
	local modes = { "n", "i", "v", "x" }
	for _, mode in ipairs(modes) do
		vim.keymap.set(mode, "<Esc>", function()
			if active_job then
				was_cancelled = true
				active_job:shutdown()
				active_job = nil
			end
			-- Exit insert mode if we're in it
			if mode == "i" then
				vim.cmd("stopinsert")
			end
			-- Clear visual selection if in visual mode
			if mode == "v" or mode == "x" then
				vim.cmd("normal! <Esc>")
			end
		end, { buffer = llm_buf, noremap = true, silent = true })
	end
end

function M.toggle_window()
	if not llm_buf or not vim.api.nvim_buf_is_valid(llm_buf) then
		create_floating_window()
		return
	end

	local wins = vim.api.nvim_list_wins()
	local is_visible = false
	for _, win in ipairs(wins) do
		if vim.api.nvim_win_get_buf(win) == llm_buf then
			vim.api.nvim_win_close(win, true)
			is_visible = true
			break
		end
	end

	if not is_visible then
		local width = math.floor(vim.o.columns * M.config.window_width)
		local height = math.floor(vim.o.lines * M.config.window_height)
		local row = math.floor((vim.o.lines - height) / 2)
		local col = math.floor((vim.o.columns - width) / 2)

		local opts = {
			relative = "editor",
			style = "minimal",
			row = row,
			col = col,
			width = width,
			height = height,
			border = "rounded",
		}

		llm_win = vim.api.nvim_open_win(llm_buf, true, opts)
		vim.wo[llm_win].wrap = true
		vim.wo[llm_win].cursorline = true
	end
end

function M.send_prompt()
	local prompt

	-- Get the visual selection or selected line
	local lines = get_visual_selection()

	if lines then
		prompt = table.concat(lines, "\n")
	else
		prompt = vim.api.nvim_get_current_line()
	end

	-- Exit visual mode
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

	-- Move to the end of the buffer
	local last_line = vim.api.nvim_buf_line_count(0)
	local last_line_length = #vim.api.nvim_buf_get_lines(0, last_line - 1, last_line, false)[1]
	vim.api.nvim_win_set_cursor(0, { last_line, last_line_length })

	if prompt and prompt ~= "" then
		write_to_buffer("\n\n")
		stream_anthropic_response(prompt)
	else
		vim.notify("No prompt found. Ensure you have a valid selection or line selected.", vim.log.levels.ERROR)
	end
end

-- Setup function to create keymaps
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	-- Create the LLMBuffer command
	vim.api.nvim_create_user_command("LLMBuffer", function()
		M.toggle_window()
	end, {})

	-- Set up the global keybinding
	vim.keymap.set("n", M.config.mappings.toggle_window, function()
		M.toggle_window()
	end, { noremap = true, silent = true, desc = "Toggle LLM Buffer" })

	-- If the buffer is open before exiting Neovim, close it (helps with session management)
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			if llm_buf and vim.api.nvim_buf_is_valid(llm_buf) then
				vim.api.nvim_buf_delete(llm_buf, { force = true })
			end
		end,
	})
end

return M
