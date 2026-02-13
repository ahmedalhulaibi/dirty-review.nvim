local M = {}

M.config = {
	keymap_review = "<leader>gR",
	keymap_copy_path = "<leader>yL",
	keymap_add_comment = "<leader>grc",
	keymap_show_comments = "<leader>grs",
	keymap_yank_comments = "<leader>gry",
	keymap_clear_comments = "<leader>grx",
	keymap_toggle_inline = "<leader>gri",
}

-- Store comments in memory
M.comments = {}

-- Namespace for virtual text
local ns_id = vim.api.nvim_create_namespace("dirty_review_comments")

-- Track inline visibility state per buffer
M.inline_visible = {}

-- Get path to persist comments (in .git directory of current repo)
local function get_comments_file()
	local git_dir = vim.fn.systemlist("git rev-parse --git-dir")[1]
	if vim.v.shell_error ~= 0 or not git_dir then
		return nil
	end
	return git_dir .. "/review-comments.json"
end

-- Save comments to file
local function save_comments()
	local path = get_comments_file()
	if not path then
		return
	end
	local file = io.open(path, "w")
	if file then
		file:write(vim.fn.json_encode(M.comments))
		file:close()
	end
end

-- Load comments from file
local function load_comments()
	local path = get_comments_file()
	if not path then
		return
	end
	local file = io.open(path, "r")
	if file then
		local content = file:read("*a")
		file:close()
		if content and content ~= "" then
			local ok, data = pcall(vim.fn.json_decode, content)
			if ok and type(data) == "table" then
				M.comments = data
			end
		end
	end
end

-- Show inline comments for current buffer
local function show_inline_comments()
	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.fn.expand("%:.")

	-- Clear existing
	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

	local count = 0
	for _, c in ipairs(M.comments) do
		if c.file == filepath then
			-- Use end_line for placement so comment appears below the selection
			local line = (c.end_line or c.start_line) - 1
			if line >= 0 and line < vim.api.nvim_buf_line_count(buf) then
				vim.api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
					virt_lines = {
						{
							{ "  💬 ", "DiagnosticInfo" },
							{ c.comment, "DiagnosticInfo" },
						},
					},
					virt_lines_above = false, -- render below the line
				})
				count = count + 1
			end
		end
	end

	M.inline_visible[buf] = true
	return count
end

-- Hide inline comments for current buffer
local function hide_inline_comments()
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	M.inline_visible[buf] = false
end

function M.copy_path_with_line()
	local path = vim.fn.expand("%:.")
	local result

	if vim.fn.mode() == "n" then
		result = path .. "#L" .. vim.fn.line(".")
	else
		local start_line = vim.fn.line("v")
		local end_line = vim.fn.line(".")
		if start_line > end_line then
			start_line, end_line = end_line, start_line
		end
		result = path .. "#L" .. start_line .. "-L" .. end_line
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
	end

	vim.fn.setreg("+", result)
	vim.notify("Copied: " .. result)
end

function M.review(base, head)
	base = base or "HEAD"

	local has_neotree = pcall(require, "neo-tree")
	local has_gitsigns = pcall(require, "gitsigns")

	if has_neotree then
		local neo_cmd = require("neo-tree.command")
		neo_cmd.execute({ action = "close" })
		vim.schedule(function()
			neo_cmd.execute({ action = "focus", source = "git_status", git_base = base })
		end)
	end

	if has_gitsigns then
		require("gitsigns").change_base(base, true)
	end

	vim.notify("Review base set to: " .. base)
end

function M.reset_review()
	local has_neotree = pcall(require, "neo-tree")
	local has_gitsigns = pcall(require, "gitsigns")

	if has_neotree then
		local neo_cmd = require("neo-tree.command")
		neo_cmd.execute({ action = "close" })
		vim.schedule(function()
			neo_cmd.execute({ action = "focus", source = "git_status" })
		end)
	end

	if has_gitsigns then
		require("gitsigns").reset_base(true)
	end

	vim.notify("Review reset to defaults")
end

-- Add a comment at the current line (or visual selection)
-- Use visual=true when called from visual mode keymap
function M.add_comment(visual)
	local file = vim.fn.expand("%:.")
	local snippet
	local start_line, end_line

	if visual then
		-- Use visual selection marks
		start_line = vim.fn.line("'<")
		end_line = vim.fn.line("'>")
		if start_line > end_line then
			start_line, end_line = end_line, start_line
		end
		snippet = table.concat(vim.fn.getline(start_line, end_line), "\n")
	else
		-- Single line in normal mode
		start_line = vim.fn.line(".")
		end_line = start_line
		snippet = vim.fn.getline(".")
	end

	local comment = vim.fn.input("Comment: ")
	if comment ~= "" then
		table.insert(M.comments, {
			file = file,
			start_line = start_line,
			end_line = end_line,
			snippet = snippet,
			comment = comment,
		})
		save_comments()

		-- Refresh inline display if visible for this buffer
		local buf = vim.api.nvim_get_current_buf()
		if M.inline_visible[buf] then
			show_inline_comments()
		end

		if start_line == end_line then
			vim.notify(string.format("Comment added: %s:%d", file, start_line))
		else
			vim.notify(string.format("Comment added: %s:%d-%d", file, start_line, end_line))
		end
	end
end

-- Show all comments in a scratch buffer
function M.show_comments()
	if #M.comments == 0 then
		vim.notify("No comments yet")
		return
	end

	local lines = { "## Review Comments", "" }
	for _, c in ipairs(M.comments) do
		local location
		if c.start_line == c.end_line then
			location = string.format("**%s:%d**", c.file, c.start_line)
		else
			location = string.format("**%s:%d-%d**", c.file, c.start_line, c.end_line)
		end
		table.insert(lines, location)
		table.insert(lines, "```")
		for snippet_line in c.snippet:gmatch("[^\n]+") do
			table.insert(lines, snippet_line)
		end
		table.insert(lines, "```")
		table.insert(lines, "> " .. c.comment)
		table.insert(lines, "")
	end

	-- Check if buffer already exists
	local buf_name = "review-comments.md"
	local existing_buf = vim.fn.bufnr(buf_name)

	if existing_buf ~= -1 then
		-- Buffer exists, find window or open in split
		local win_id = vim.fn.bufwinid(existing_buf)
		if win_id ~= -1 then
			vim.api.nvim_set_current_win(win_id)
		else
			vim.cmd("vsplit")
			vim.api.nvim_win_set_buf(0, existing_buf)
		end
		vim.api.nvim_buf_set_lines(existing_buf, 0, -1, false, lines)
	else
		-- Create new buffer
		vim.cmd("vsplit")
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].filetype = "markdown"
		vim.api.nvim_buf_set_name(buf, buf_name)
		vim.api.nvim_win_set_buf(0, buf)
	end
end

-- Yank all comments as markdown to clipboard
function M.yank_comments()
	if #M.comments == 0 then
		vim.notify("No comments to yank")
		return
	end

	local lines = { "## Review Comments", "" }
	for _, c in ipairs(M.comments) do
		local location
		if c.start_line == c.end_line then
			location = string.format("**%s:%d**", c.file, c.start_line)
		else
			location = string.format("**%s:%d-%d**", c.file, c.start_line, c.end_line)
		end
		table.insert(lines, location)
		table.insert(lines, "```")
		for snippet_line in c.snippet:gmatch("[^\n]+") do
			table.insert(lines, snippet_line)
		end
		table.insert(lines, "```")
		table.insert(lines, "> " .. c.comment)
		table.insert(lines, "")
	end

	local content = table.concat(lines, "\n")
	vim.fn.setreg("+", content)
	vim.notify(string.format("Yanked %d comments to clipboard", #M.comments))
end

-- Clear all comments
function M.clear_comments()
	local count = #M.comments
	M.comments = {}
	save_comments()
	-- Clear all inline displays
	for buf, _ in pairs(M.inline_visible) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
		end
	end
	M.inline_visible = {}
	vim.notify(string.format("Cleared %d comments", count))
end

-- Toggle inline comments for current buffer
function M.toggle_inline()
	local buf = vim.api.nvim_get_current_buf()

	if M.inline_visible[buf] then
		hide_inline_comments()
		vim.notify("Inline comments hidden")
	else
		local count = show_inline_comments()
		if count > 0 then
			vim.notify(string.format("Showing %d inline comments", count))
		else
			vim.notify("No comments for this file")
		end
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Load any persisted comments
	load_comments()

	vim.keymap.set(
		{ "n", "v" },
		M.config.keymap_copy_path,
		M.copy_path_with_line,
		{ desc = "Copy file path with line number" }
	)
	vim.keymap.set("n", M.config.keymap_review, function()
		vim.ui.input({ prompt = "Review base ref: ", default = "HEAD" }, function(input)
			if input and input ~= "" then
				M.review(input)
			end
		end)
	end, { desc = "Review local changes like a PR" })
	vim.keymap.set("n", M.config.keymap_add_comment, function()
		M.add_comment(false)
	end, { desc = "Add review comment at line" })
	vim.keymap.set("v", M.config.keymap_add_comment, function()
		-- Exit visual mode first so marks are set
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
		M.add_comment(true)
	end, { desc = "Add review comment for selection" })
	vim.keymap.set("n", M.config.keymap_show_comments, M.show_comments, { desc = "Show all review comments" })
	vim.keymap.set("n", M.config.keymap_yank_comments, M.yank_comments, { desc = "Yank comments as markdown" })
	vim.keymap.set("n", M.config.keymap_clear_comments, M.clear_comments, { desc = "Clear all comments" })
	vim.keymap.set("n", M.config.keymap_toggle_inline, M.toggle_inline, { desc = "Toggle inline comments" })
end

return M
