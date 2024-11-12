local mc = require("decscribe.mixcoll")
local cr = require("decscribe.core")
local ic = require("decscribe.ical")
local di = require("decscribe.diff")
local md = require("decscribe.markdown")
local dt = require("decscribe.date")

local M = {}

---@class (exact) tasks.Task
---@field uid decscribe.ical.Uid
---@field vtodo decscribe.ical.Vtodo
---@field ical decscribe.ical.String

---@type fun(a: decscribe.ical.Vtodo, b: decscribe.ical.Vtodo): boolean
function M.vtodo_comp_default(vtodo1, vtodo2)
	local completed1 = vtodo1.completed and 1 or 0
	local completed2 = vtodo2.completed and 1 or 0
	if completed1 ~= completed2 then return completed1 < completed2 end

	local due1 = (vtodo1.due or {}).timestamp
	local due2 = (vtodo2.due or {}).timestamp
	-- if one of the tasks does not have a due date, it defaults to anything AFTER
	-- the other:
	if not due1 and due2 then due1 = due2 + 1 end
	if due1 and not due2 then due2 = due1 + 1 end
	if due1 ~= due2 then return due1 < due2 end

	local priority1 = tonumber(vtodo1.priority) or 0
	local priority2 = tonumber(vtodo2.priority) or 0
	if priority1 ~= priority2 then return priority1 < priority2 end

	local summary1 = vtodo1.summary or ""
	local summary2 = vtodo2.summary or ""
	if summary1 ~= summary2 then return summary1 < summary2 end

	local cats1 = table.concat(vtodo1.categories or {}, ",")
	local cats2 = table.concat(vtodo2.categories or {}, ",")
	return cats1 < cats2
end

---@param task1 tasks.Task
---@param task2 tasks.Task
---@return boolean
function M.task_comp_default(task1, task2)
	return M.vtodo_comp_default(task1.vtodo, task2.vtodo)
end

---@class (exact) decscribe.UiFacade
---@field buf_get_lines fun(start: integer, end_: integer): string[]
---@field buf_set_lines fun(start: integer, end_: integer, lines: string[])
---@field buf_set_opt fun(opt_name: string, value: any)

---@class (exact) decscribe.State
---@field main_buf_nr integer?
---@field tasks decscribe.mixcoll.MixColl<decscribe.ical.Uid, tasks.Task>
---@field lines string[]
---@field curr_coll_id string?
---@field decsync_dir string?
---@field tzid string? ICalendar timezone info, e.g.: "America/Chicago"

---XXX: Indices in `todos` will change - any data referring to those indices
---may break unless properly handled.
---@param state decscribe.State
---@param idx integer
---@return decscribe.ical.Uid to_be_removed
local function on_line_removed(state, idx)
	---@param task tasks.Task
	---@return decscribe.ical.Uid
	local function id_fn(task) return task.uid end
	local deleted_task =
		mc.delete_at(state.tasks, idx, id_fn, M.task_comp_default)
	assert(
		deleted_task,
		"Tried deleting task at index " .. idx .. "but there was nothing there"
	)
	return deleted_task.uid
end

---XXX: Indices in `todos` will change - any data referring to those indices
---may break unless properly handled.
---@param state decscribe.State
---@param idx integer
---@param line string
---@param params decscribe.WriteBufferParams
---@return decscribe.ical.Uid added_task_uid
---@return decscribe.ical.String added_task_ical
local function on_line_added(state, idx, line, params)
	params = params or {}
	local uids = {}
	for _, task in pairs(state.tasks) do
		uids[task.uid] = true
	end
	local uid = ic.generate_uid(vim.tbl_keys(uids), params.seed)
	local vtodo = ic.parse_md_line(line)
	-- TODO: add a diagnostic to the line
	assert(vtodo, "Invalid line while adding new entry")

	local ical = ic.create_ical_vtodo(uid, vtodo, {
		fresh_timestamp = params.fresh_timestamp,
		tzid = state.tzid,
	})
	---@type tasks.Task
	local todo = {
		uid = uid,
		collection = state.curr_coll_id,
		vtodo = vtodo,
		ical = ical,
	}
	mc.post_at(state.tasks, idx, todo)
	return uid, ical
end

---@param state decscribe.State
---@param idx integer
---@param new_line string
---@return decscribe.ical.Uid?, decscribe.ical.String?
local function on_line_changed(state, idx, new_line)
	local changed_todo = mc.get_at(state.tasks, idx, M.task_comp_default)
	assert(
		changed_todo,
		"Expected an existing task at " .. idx .. " but found nothing"
	)

	local new_vtodo = ic.parse_md_line(new_line)
	assert(new_vtodo)

	if vim.deep_equal(changed_todo.vtodo, new_vtodo) then return end

	-- XXX: any vtodo properties, that cannot be evaluated from line parsing, will
	-- be lost, unless we explicitly assign them! e.g. parent vtodo uid:
	new_vtodo.parent_uid = new_vtodo.parent_uid or changed_todo.vtodo.parent_uid
	changed_todo.vtodo = new_vtodo

	mc.put_at(state.tasks, idx, changed_todo)
	local uid = changed_todo.uid
	local ical = changed_todo.ical
	local vtodo = changed_todo.vtodo

	-- TODO: what if as a user I e.g. write into my description "STATUS:NEEDS-ACTION" string? will I inject metadata into the iCal?

	---@type table<string, string|false|{ opts: decscribe.ical.Options, value: string}>
	---a dict on what fields to change; if value is a string, the field should be
	---updated to that; if it's `false`, the field should be removed if present
	local changes = {}

	local new_status = vtodo.completed and "COMPLETED" or "NEEDS-ACTION"
	changes["STATUS"] = new_status

	---@type string|false
	local summary = vtodo.summary or false
	if summary == "" then summary = false end
	changes["SUMMARY"] = summary

	local categories = vtodo.categories
	if not categories or #categories == 0 then
		changes["CATEGORIES"] = false
	else
		local new_cats = { unpack(categories) }
		-- NOTE: there is a convention (or at least tasks.org follows it) to sort
		-- categories alphabetically:
		table.sort(new_cats)
		local new_cats_str = table.concat(new_cats, ",")
		changes["CATEGORIES"] = new_cats_str
	end

	local priority = vtodo.priority
	if not priority or priority == ic.Priority.undefined then
		changes["PRIORITY"] = false
	else
		changes["PRIORITY"] = tostring(priority)
	end

	local parent_uid = vtodo.parent_uid
	if parent_uid then
		changes["RELATED-TO"] =
			{ value = parent_uid, opts = { RELTYPE = "PARENT" } }
	end

	local dtstart = vtodo.dtstart
	if not dtstart then
		changes["DTSTART"] = false
	elseif dtstart.precision == dt.Precision.Date then
		local dtstart_date_str = os.date("%Y%m%d", dtstart.timestamp)
		---@cast dtstart_date_str string
		changes["DTSTART"] = { value = dtstart_date_str, opts = { VALUE = "DATE" } }
	elseif dtstart.precision == dt.Precision.DateTime then
		local dtstart_date_str = os.date("%Y%m%dT%H%M%S", dtstart.timestamp)
		local tzid = state.tzid
		assert(tzid, "Cannot write timezone-specific datetime without tzid")
		---@cast dtstart_date_str string
		changes["DTSTART"] = { value = dtstart_date_str, opts = { TZID = tzid } }
	else
		error("Unhandled state of DTSTART property")
	end

	local due = vtodo.due
	if not due then
		changes["DUE"] = false
	elseif due.precision == dt.Precision.Date then
		local due_date_str = os.date("%Y%m%d", vtodo.due.timestamp)
		---@cast due_date_str string
		changes["DUE"] = { value = due_date_str, opts = { VALUE = "DATE" } }
	elseif due.precision == dt.Precision.DateTime then
		local due_date_str = os.date("%Y%m%dT%H%M%S", due.timestamp)
		local tzid = state.tzid
		assert(tzid, "Cannot write timezone-specific datetime without tzid")
		---@cast due_date_str string
		changes["DUE"] = { value = due_date_str, opts = { TZID = tzid } }
	else
		error("Unhandled state of DUE property")
	end

	local ical_entries = ic.ical_parse(ical)

	-- remove all entries marked for deletion:
	for i = #ical_entries, 1, -1 do
		local key = ical_entries[i].key
		if changes[key] == false then
			changes[key] = nil
			table.remove(ical_entries, i)
		end
	end
	-- discard all deletion changes that weren't applied due to the entry not
	-- being there at all:
	for key, value in pairs(changes) do
		if value == false then changes[key] = nil end
	end

	-- update all existing entries:
	for _, entry in ipairs(ical_entries) do
		local change = changes[entry.key]
		if change ~= nil then
			if type(change) == "string" then
				entry.value = change
			elseif type(change) == "table" then
				entry.value = change.value
				entry.opts = change.opts -- TODO: overwrite or merge?
			else
				error("unexpected type of change: " .. vim.inspect(change))
			end
			changes[entry.key] = nil
		end
	end

	-- insert new entries right before "END:VTODO"
	for i, entry in ipairs(ical_entries) do
		if entry.key == "END" and entry.value == "VTODO" then
			for key, change in pairs(changes) do
				---@type decscribe.ical.Entry?
				local new_entry = nil
				if type(change) == "string" then
					new_entry = { key = key, value = change }
				elseif type(change) == "table" then
					new_entry = { key = key, value = change.value, opts = change.opts }
				else
					error("unexpected type of change: " .. vim.inspect(change))
				end
				table.insert(ical_entries, i, new_entry)
			end
			break
		end
	end
	assert(#changes == 0, "some changes were unexpectedly not applied")

	local out_ical = ic.ical_show(ical_entries)
	return uid, out_ical
end

---@class decscribe.ReadBufferParams
---@field icals table<decscribe.ical.Uid, decscribe.ical.String>

---@deprecated
---@param state decscribe.State
---@param params decscribe.ReadBufferParams
---@return string[] lines
function M.read_buffer(state, params)
	-- tasklist has to be recreated from scratch, so that there are no leftovers,
	-- e.g. from a different collection/dsdir
	state.tasks = {}

	local uid_to_icals = params.icals

	for todo_uid, todo_ical in pairs(uid_to_icals) do
		---@type decscribe.ical.Vtodo
		local vtodo = ic.vtodo_from_ical(todo_ical)

		---@type tasks.Task
		local todo = {
			vtodo = vtodo,
			ical = todo_ical,
			uid = todo_uid,
			collection = state.curr_coll_id,
		}

		state.tasks[todo_uid] = todo
	end

	state.lines = {}
	for _, task in ipairs(mc.to_sorted_list(state.tasks, M.task_comp_default)) do
		local line = ic.to_md_line(task.vtodo)
		if line then table.insert(state.lines, line) end
	end

	return state.lines
end

---@class decscribe.WriteBufferParams
---@field new_lines string[]
---@field fresh_timestamp? integer
---TODO: Decouple domain from timestamps - return closure
---@field seed? integer used for random operations
---TODO: Decouple domain from random operations - return closure

---@class (exact) decscribe.WriteBufferOutcome
---@field changes table<decscribe.ical.Uid, decscribe.ical.String|false>
---FIXME: Decouple domain from Ical format!

---Load new state from ICal database and adapt the application state to it.
---@param icals { [decscribe.ical.Uid]: decscribe.ical.String } just read from the persistent database
---@return string[] next_lines to be rendered in a visual buffer
---@return decscribe.core.SavedTodo[] store to be put into memory
function M.read_icals(icals)
	local uid_to_tree = {}
	for uid, str in pairs(icals) do
		uid_to_tree[uid] = ic.str2tree(str, { lists = { CATEGORIES = true }})
	end
	local store = ic.trees2sts(uid_to_tree)
	local lines = {}
	-- for _, todo in ipairs(store) do lines[#lines+1] = ic.to_md_line(todo) end
	for _, todo in ipairs(store) do
		lines[#lines + 1] = md.todo2str(cr.unuid(todo))
	end
	return lines, store
end

---@param curr_store decscribe.core.SavedTodo[] saved currently in memory
---@param curr_view string the buffer content; one big string with newlines
---@return decscribe.core.SavedTodo[] next_store
function M.read_view(curr_store, curr_view)
	-- Load new state from the Markdown buffer:
	local next_todos = md.decode(curr_view)
	assert(next_todos, "Failed to parse the Markdown buffer!")
	-- Sync the buffer with the store internally:
	local db_changes, on_db_changed = cr.sync_buffer(curr_store, next_todos)
	-- Commit the changes to the DB
	--db_icals.bar = ic.todo2tree(cr.with_uid(db_changes[1], "bar"))
	-- TODO: implement patch_trees
	-- local patched_ic_trees = ic.patch_trees(ic_trees, db_changes)
	-- eq(ic_trees.foo, patched_ic_trees.foo) -- parent hasn't changed
	-- TODO: don't forget to add UID - UIDs are there in the ICal JSONs
	-- 5. Apply the requested DB changes to internal store
	local next_store = on_db_changed({ [1] = "bar" })
	return next_store
end

---@param state decscribe.State
---@param params decscribe.WriteBufferParams
---@return decscribe.WriteBufferOutcome
function M.write_buffer_new(state, params)
	local old_sorted_tasks = mc.to_sorted_list(state.tasks, M.task_comp_default)

	---@type decscribe.ical.Uid[] all recorded UIDs, in order to properly create new ones
	local all_uids = {}
	for id, _ in pairs(old_sorted_tasks) do
		if type(id) == "string" then all_uids[#all_uids + 1] = id end
	end

	local old_todos = md.decode(table.concat(state.lines, "\n"))
	local new_todos = md.decode(table.concat(params.new_lines, "\n"))

	---@param todo_diff table
	---@return decscribe.ical.Uid
	---@return table
	local function mk_vtodo(todo_diff)
		local new_uid = ic.generate_uid(all_uids, params.seed)
		all_uids[#all_uids + 1] = new_uid
		-- error("TODO: map core.Todo to ical.Todo")
		ic.ical_vtodo.from_todo(new_uid, todo_diff)
		local new_ical = ic.create_ical_vtodo(
			new_uid,
			todo_diff,
			{ tzid = state.tzid, fresh_timestamp = params.fresh_timestamp }
		)
		return new_uid, new_ical
	end

	---@cast old_todos table<integer, decscribe.core.Todo>
	---@cast new_todos table<integer, decscribe.core.Todo>
	local todos_diff = di.diff(old_todos, new_todos)
	---@type decscribe.WriteBufferOutcome
	local out = { changes = {} }
	for pos, todo_diff in pairs(todos_diff) do
		local old_task = old_sorted_tasks[pos]
		if old_task then
			if todo_diff == di.Removal then -- task has been removed
				out.changes[old_task.uid] = false
			else -- task has been modified
				--repo.upsert_todos(todo_diff + uids) -- (dependency injection)
				--out.changes[uid] = upd_todo_diff; out.changes[#out.changes+1] =  (dependency rejection)

				local updated_ical = ic.patch(old_task.ical, todo_diff)

				-- for _, subtask_diff in ipairs(todo_diff.subtasks) do
				-- local new_uid, new_vtodo = mk_vtodo(subtask_diff)
				-- out.changes[new_uid] = new_vtodo
				-- end
				error("TODO: get old icals & make updates based on diff")
				-- out.changes[old_task.uid] = todo_change
				out.changes[old_task.uid] = ic.ical_show(updated_ical)
			end
		else -- new task was created
			local new_uid, new_vtodo = mk_vtodo(todo_diff)
			out[new_uid] = new_vtodo
		end
	end

	return out
end

---@deprecated
---@param state decscribe.State
---@param params decscribe.WriteBufferParams
---@return decscribe.WriteBufferOutcome
function M.write_buffer(state, params)
	local old_contents = state.lines
	local new_contents = params.new_lines
	local hunks = vim.diff(
		table.concat(old_contents, "\n"),
		table.concat(new_contents, "\n"),
		{ result_type = "indices" }
	)
	assert(type(hunks) == "table", "Decscribe: unexpected diff output")
	---@type decscribe.WriteBufferOutcome
	local out = { changes = {} }
	local lines_to_affect = {}
	for _, hunk in ipairs(hunks) do
		local old_start, old_count, new_start, new_count = unpack(hunk)

		if old_count == 0 and new_count == 0 then
			error('It is not possible that "absence of lines" moved.')
		end

		local start
		local count
		-- something was added:
		if old_count == 0 and new_count > 0 then
			--
			-- NOTE: vim.diff() provides, which index the hunk will move into,
			-- based on *the previous hunks*. E.g. given a one-line deletion at
			-- #100 and a two-line deletion at #200, the hunks will be:
			--
			-- { 100, 1, 99, 0 } and { 200, 2, >>197<<, 0 }
			--
			-- Therefore, the second hunk's destination index takes into account
			-- the one line deleted in the first hunk.
			--
			-- NOTE: This is not yet utilized here, but may be useful when
			-- complexity of this logic grows.
			--
			start = new_start
			count = new_count
			for idx = start, start + count - 1 do
				table.insert(lines_to_affect, { idx = idx, line = new_contents[idx] })
			end
		-- something was removed:
		elseif old_count > 0 and new_count == 0 then
			start = old_start
			count = old_count
			for idx = start, start + count - 1 do
				table.insert(lines_to_affect, { idx = idx, line = nil })
			end
		-- something changed, size remained the same:
		elseif old_count == new_count and old_start == new_start then
			start = old_start -- since they're both the same anyway
			count = old_count -- since they're both the same anyway
			assert(count > 0, "decscribe: diff count in this hunk cannot be 0")
			for idx = start, start + count - 1 do
				local new_line = new_contents[idx]
				local new_uid, new_ical = on_line_changed(state, idx, new_line)
				if new_uid and new_ical then
					assert(
						not out.changes[new_uid],
						"when collecting new tasks to create, some have colliding UIDs"
					)
					out.changes[new_uid] = new_ical
				end
			end
		-- different scenario
		else
			error("decscribe: some changes could not get handled")
		end
	end
	-- sort pending changes in reversed order to not break indices when
	-- removing/adding entries:
	table.sort(lines_to_affect, function(a, b) return a.idx > b.idx end)
	-- apply pending changes
	for _, change in ipairs(lines_to_affect) do
		local idx = change.idx
		if change.line == nil then
			local removed_uid = on_line_removed(state, idx)
			assert(type(removed_uid) == "string")
			out.changes[removed_uid] = false
		else
			local added_uid, added_ical =
				on_line_added(state, idx, change.line, params)
			assert(
				not out.changes[added_uid],
				"when collecting new tasks to create, some have colliding UIDs"
			)
			out.changes[added_uid] = added_ical
		end
	end

	-- updating succeeded
	state.lines = new_contents

	return out
end

---@alias decscribe.CollLabel string
---@alias decscribe.CollId string
---@alias decscribe.Collections table<decscribe.CollLabel, decscribe.CollId>

---@class (exact) decscribe.CompleteCommandlineParams
---@field is_decsync_dir_fn fun(path: string): boolean
---@field list_collections_fn fun(ds_dir_path: string): decscribe.Collections
---@field complete_path_fn fun(path_prefix: string): string[]

---@param arg_lead string
---@param cmd_line string
---@param params decscribe.CompleteCommandlineParams
---@return string[]
function M.complete_commandline(arg_lead, cmd_line, params)
	local cmd_line_comps = vim.split(cmd_line, "%s+")
	-- if this is the 1st argument (besides the cmd), provide path completion:
	if arg_lead == cmd_line_comps[2] then
		return params.complete_path_fn(arg_lead)
	end
	-- otherwise, this is the second argument:
	local ds_dir = vim.fn.expand(cmd_line_comps[2])
	if not params.is_decsync_dir_fn(ds_dir) then return {} end

	local coll_names = vim.tbl_keys(params.list_collections_fn(ds_dir))
	return vim.tbl_filter(
		function(s) return vim.startswith(s, arg_lead) end,
		coll_names
	)
end

return M
