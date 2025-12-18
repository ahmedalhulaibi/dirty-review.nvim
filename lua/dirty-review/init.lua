local M = {}

M.config = {
	keymap_review = "<leader>gR",
	keymap_copy_path = "<leader>yL",
}

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

local function parse_review_buffer(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local hunks = {}
	local current_key = nil
	local in_diff = false
	local in_comments = false
	local diff_lines = {}
	local comment_lines = {}

	local function save_hunk()
		if current_key then
			local comments = vim.trim(table.concat(comment_lines, "\n"))
			hunks[current_key] = {
				content = table.concat(diff_lines, "\n"),
				comments = comments ~= "" and comments or nil,
			}
		end
	end

	for _, line in ipairs(lines) do
		if line:match("^### ") then
			save_hunk()
			current_key = line:sub(5)
			diff_lines = {}
			comment_lines = {}
			in_diff = false
			in_comments = false
		elseif line:match("^```diff") then
			in_diff = true
		elseif line:match("^```$") and in_diff then
			in_diff = false
		elseif in_diff then
			table.insert(diff_lines, line)
		elseif line:match("^%*%*Comments") then
			in_comments = true
		elseif in_comments and line:match("^### ") == nil then
			table.insert(comment_lines, line)
		end
	end
	save_hunk()

	return hunks
end

function M.review()
	local diff_output = vim.fn.systemlist("git diff HEAD")

	if #diff_output == 0 then
		vim.notify("No uncommitted changes")
		return
	end

	local sha = vim.fn.systemlist("git rev-parse --short HEAD")[1]
	local buffer_name = "Review " .. sha .. "-dirty"

	local existing_buf = nil
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if name:match("Review " .. sha .. "%-dirty$") then
			existing_buf = buf
			break
		end
	end

	local old_hunks = {}
	if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
		old_hunks = parse_review_buffer(existing_buf)
	end

	local new_hunks = {}
	local hunk_order = {}
	local current_file = ""
	local hunk_lines = {}
	local hunk_header = ""

	local function flush_hunk()
		if #hunk_lines > 0 then
			local key = current_file .. " " .. hunk_header
			table.insert(hunk_order, key)
			new_hunks[key] = {
				content = table.concat(hunk_lines, "\n"),
				file = current_file,
				header = hunk_header,
			}
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

	local lines = {}
	for _, key in ipairs(hunk_order) do
		local hunk = new_hunks[key]
		local old = old_hunks[key]

		table.insert(lines, "### " .. key)
		table.insert(lines, "")
		table.insert(lines, "```diff")
		for diff_line in hunk.content:gmatch("[^\n]+") do
			table.insert(lines, diff_line)
		end
		table.insert(lines, "```")
		table.insert(lines, "")

		if old and old.comments then
			local is_stale = old.content ~= hunk.content
			if is_stale then
				table.insert(lines, "**Comments:** ⚠️ STALE (hunk changed)")
			else
				table.insert(lines, "**Comments:**")
			end
			table.insert(lines, "")
			for comment_line in old.comments:gmatch("[^\n]*") do
				table.insert(lines, comment_line)
			end
		else
			table.insert(lines, "**Comments:**")
			table.insert(lines, "")
		end
		table.insert(lines, "")
	end

	local orphaned = {}
	for key, old in pairs(old_hunks) do
		if old.comments and not new_hunks[key] then
			table.insert(orphaned, { key = key, comments = old.comments })
		end
	end

	if #orphaned > 0 then
		table.insert(lines, "---")
		table.insert(lines, "")
		table.insert(lines, "## 🗑️ Orphaned Comments (hunks no longer exist)")
		table.insert(lines, "")
		for _, o in ipairs(orphaned) do
			table.insert(lines, "### " .. o.key)
			table.insert(lines, "")
			for comment_line in o.comments:gmatch("[^\n]*") do
				table.insert(lines, comment_line)
			end
			table.insert(lines, "")
		end
	end

	if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
		vim.api.nvim_set_current_buf(existing_buf)
		vim.bo.modifiable = true
		vim.api.nvim_buf_set_lines(existing_buf, 0, -1, false, lines)
	else
		vim.cmd("enew")
		local buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].modifiable = true
		vim.wo.foldenable = false
		vim.api.nvim_buf_set_name(buf, buffer_name)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end

	vim.notify("Review updated!")
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set(
		{ "n", "v" },
		M.config.keymap_copy_path,
		M.copy_path_with_line,
		{ desc = "Copy file path with line number" }
	)
	vim.keymap.set("n", M.config.keymap_review, M.review, { desc = "Review local changes like a PR" })
end

return M
