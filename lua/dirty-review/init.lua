local M = {}

M.config = {
	keymap_review = "<leader>gR",
	keymap_copy_path = "<leader>yL",
	keymap_add_comment = "<leader>grc",
	keymap_show_comments = "<leader>grs",
	keymap_yank_comments = "<leader>gry",
	keymap_clear_comments = "<leader>grx",
	keymap_toggle_inline = "<leader>gri",
	keymap_merge_external = "<leader>grm",
	-- Auto-prompt for merge when file changes externally and buffer is modified
	auto_merge_prompt = true,
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

function M.review()
	local diff_output = vim.fn.systemlist("git diff HEAD")

	if #diff_output == 0 then
		vim.notify("No uncommitted changes")
		return
	end

	local sha = vim.fn.systemlist("git rev-parse --short HEAD")[1]
	local timestamp = os.time()
	local buffer_name = string.format("review_%s_dirty_%d.md", sha, timestamp)

	-- Parse diff into hunks
	local hunks = {}
	local current_file = ""
	local hunk_lines = {}
	local hunk_header = ""

	local function flush_hunk()
		if #hunk_lines > 0 then
			table.insert(hunks, {
				file = current_file,
				header = hunk_header,
				content = table.concat(hunk_lines, "\n"),
			})
			hunk_lines = {}
		end
	end

	for _, line in ipairs(diff_output) do
		if line:match("^diff %-%-git") then
			flush_hunk()
		elseif line:match("^%+%+%+ b/") then
			current_file = line:sub(7)
		elseif line:match("^@@") then
			flush_hunk()
			hunk_header = line:match("^(@@ .* @@)")
		elseif
			current_file ~= ""
			and not line:match("^index ")
			and not line:match("^%-%-%-")
			and not line:match("^%+%+%+")
		then
			table.insert(hunk_lines, line)
		end
	end
	flush_hunk()

	-- Build output
	local lines = {}
	for _, hunk in ipairs(hunks) do
		table.insert(lines, "### " .. hunk.file .. " " .. hunk.header)
		table.insert(lines, "")
		table.insert(lines, "```diff")
		for diff_line in hunk.content:gmatch("[^\n]+") do
			table.insert(lines, diff_line)
		end
		table.insert(lines, "```")
		table.insert(lines, "")
		table.insert(lines, "**Comments:**")
		table.insert(lines, "")
		table.insert(lines, "")
	end

	-- If in a special buffer (like NeoTree), go to previous window first
	if vim.bo.buftype ~= "" then
		vim.cmd("wincmd p")
	end

	vim.cmd("enew")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].filetype = "markdown"
	vim.wo.foldenable = false
	vim.api.nvim_buf_set_name(buf, buffer_name)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	vim.notify("Review: " .. buffer_name)
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

-- Three-way merge: buffer (yours) + disk (theirs) + git HEAD (base)
function M.merge_external()
	local buf = vim.api.nvim_get_current_buf()
	local file = vim.fn.expand("%:p")
	local relpath = vim.fn.expand("%:.")

	-- Check if buffer is modified
	if not vim.bo[buf].modified then
		-- No local changes, just reload
		vim.cmd("edit!")
		vim.notify("Reloaded (no local changes)")
		return
	end

	-- Check if file is tracked by git
	vim.fn.system("git ls-files --error-unmatch " .. vim.fn.shellescape(relpath) .. " 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		-- Not a git file, can't do three-way merge
		vim.notify("Not a git-tracked file, cannot merge", vim.log.levels.WARN)
		return
	end

	-- Save buffer content to temp file (yours)
	local yours = vim.fn.tempname()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.fn.writefile(lines, yours)

	-- Get base from git HEAD
	local base = vim.fn.tempname()
	local base_content = vim.fn.system("git show HEAD:" .. vim.fn.shellescape(relpath))
	if vim.v.shell_error ~= 0 then
		-- File is new (not in HEAD), use empty base
		base_content = ""
	end
	vim.fn.writefile(vim.split(base_content, "\n", { plain = true }), base)

	-- Theirs is the current file on disk
	-- Run git merge-file: merges theirs into yours using base
	-- -p outputs to stdout instead of modifying file
	local result = vim.fn.system(
		"git merge-file -p "
			.. vim.fn.shellescape(yours)
			.. " "
			.. vim.fn.shellescape(base)
			.. " "
			.. vim.fn.shellescape(file)
	)
	local exit_code = vim.v.shell_error

	-- Clean up temp files
	vim.fn.delete(yours)
	vim.fn.delete(base)

	if exit_code < 0 then
		vim.notify("Merge failed: " .. result, vim.log.levels.ERROR)
		return
	end

	-- Replace buffer with merged result
	local merged_lines = vim.split(result, "\n", { plain = true })
	-- Remove trailing empty line that git merge-file adds
	if #merged_lines > 0 and merged_lines[#merged_lines] == "" then
		table.remove(merged_lines)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, merged_lines)

	if exit_code == 0 then
		-- Auto-write to checkpoint the merge and avoid subsequent conflicts
		vim.cmd("silent write!")
		vim.b[buf].dirty_review_mtime = vim.fn.getftime(file)
		vim.notify("Merged cleanly and saved")
	else
		-- exit_code > 0 means conflicts (number of conflicts)
		vim.notify(string.format("Merged with %d conflict(s) - search for <<<<<<<", exit_code), vim.log.levels.WARN)
		-- Jump to first conflict marker
		vim.fn.search("<<<<<<<", "w")
	end
end

-- Open three-way diff view instead of auto-merging
function M.diff_external()
	local file = vim.fn.expand("%:p")
	local relpath = vim.fn.expand("%:.")

	-- Save buffer content to temp file (yours)
	local yours = vim.fn.tempname() .. "_YOURS"
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	vim.fn.writefile(lines, yours)

	-- Get base from git HEAD
	local base = vim.fn.tempname() .. "_BASE"
	local base_content = vim.fn.system("git show HEAD:" .. vim.fn.shellescape(relpath))
	if vim.v.shell_error ~= 0 then
		base_content = ""
	end
	vim.fn.writefile(vim.split(base_content, "\n", { plain = true }), base)

	-- Copy theirs (disk version)
	local theirs = vim.fn.tempname() .. "_THEIRS"
	vim.fn.system("cp " .. vim.fn.shellescape(file) .. " " .. vim.fn.shellescape(theirs))

	-- Open three-way diff in new tab
	vim.cmd("tabnew " .. vim.fn.fnameescape(yours))
	vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(base))
	vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(theirs))
	vim.cmd("wincmd t") -- go to first window (yours)

	vim.notify("Left: yours | Middle: base (HEAD) | Right: theirs (disk)")
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
	vim.keymap.set("n", M.config.keymap_review, M.review, { desc = "Review local changes like a PR" })
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
	vim.keymap.set("n", M.config.keymap_merge_external, M.merge_external, { desc = "Merge external changes" })

	-- Create user commands
	vim.api.nvim_create_user_command("DirtyMerge", M.merge_external, { desc = "Three-way merge external changes" })
	vim.api.nvim_create_user_command("DirtyDiff", M.diff_external, { desc = "Three-way diff external changes" })

	-- Auto-prompt for merge when file changes externally
	if M.config.auto_merge_prompt then
		-- Periodically check for external changes (when cursor is idle)
		vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
			pattern = "*",
			callback = function()
				if vim.bo.buftype == "" then
					vim.cmd("silent! checktime")
				end
			end,
		})

		-- Also check before writing to catch changes missed by checktime
		vim.api.nvim_create_autocmd("BufWritePre", {
			pattern = "*",
			callback = function(ev)
				local file = vim.fn.expand("%:p")
				if vim.fn.filereadable(file) == 0 then
					return
				end

				-- Compare file mtime with buffer changedtick
				local buf_time = vim.b[ev.buf].dirty_review_mtime or 0
				local file_time = vim.fn.getftime(file)

				if file_time > buf_time and vim.bo[ev.buf].modified then
					-- File changed since we last checked, trigger checktime
					vim.cmd("checktime")
				end
			end,
		})

		-- Track file mtime when buffer is read
		vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
			pattern = "*",
			callback = function(ev)
				local file = vim.fn.expand("%:p")
				vim.b[ev.buf].dirty_review_mtime = vim.fn.getftime(file)
			end,
		})

		vim.api.nvim_create_autocmd("FileChangedShell", {
			pattern = "*",
			callback = function(ev)
				local buf = ev.buf
				-- Only prompt if buffer is modified
				if not vim.bo[buf].modified then
					return
				end

				-- Set v:fcs_choice to prevent default dialog
				vim.v.fcs_choice = ""

				vim.schedule(function()
					local choice = vim.fn.confirm(
						"File changed externally. You have unsaved changes.",
						"&Merge (3-way)\n&Diff view\n&Reload (lose changes)\n&Ignore",
						1
					)
					if choice == 1 then
						M.merge_external()
					elseif choice == 2 then
						M.diff_external()
					elseif choice == 3 then
						vim.cmd("edit!")
					end
					-- choice == 4 or 0: do nothing
				end)
			end,
		})
	end
end

return M
