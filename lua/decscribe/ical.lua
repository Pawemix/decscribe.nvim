local M = {}

---@alias ical.uid_t string

---@alias ical.ical_t string

---@class (exact) ical.vtodo_t
---@field summary string?
---@field description string?
---@field completed boolean
---@field priority number?
---@field categories string[]?
---@field parent_uid ical.uid_t?
local vtodo_t = {}

local ICAL_PROP_NAMES = {
	-- TODO: insert BEGIN:VCALENDAR
	"VERSION",
	"PRODID",
	"BEGIN", -- TODO: replace with BEGIN:VTODO
	"DTSTAMP",
	"UID",
	"CREATED",
	"LAST-MODIFIED",
	"SUMMARY",
	"DESCRIPTION",
	"PRIORITY",
	"STATUS",
	"CATEGORIES",
	"RELATED-TO",
	"X-APPLE-SORT-ORDER",
	"DUE",
	"COMPLETED",
	"PERCENT-COMPLETE",
	"END", -- TODO: replace END:VTODO
	-- TODO: insert END:VCALENDAR
}

---@enum ical.priority_t
M.priority_t = {
	undefined = 0,
	tasks_org_high = 1,
	tasks_org_medium = 5,
	tasks_org_low = 9,
	-- tasks_org_lowest = nil, -- i.e. no PRIORITY prop at all
}

M.labelled_priorities = vim.tbl_add_reverse_lookup({
	H = M.priority_t.tasks_org_high,
	M = M.priority_t.tasks_org_medium,
	L = M.priority_t.tasks_org_low,
})

--- priority_t:
--- 0 = undefined
--- 1 = highest
--- (1-4 = CUA "HIGH")
--- (5 = normal or CUA "MEDIUM")
--- (6-9 = CUA "LOW")
--- 9 = lowest
-- (tasks.org: 9, 5, 1, ???

local UID_LENGTH = 19
local UID_FORMAT = "%0" .. UID_LENGTH .. "d"
local UID_MAX = math.pow(10, UID_LENGTH) - 1

---@param uids ical.uid_t[]
---@param seed number?
---@return ical.uid_t
function M.generate_uid(uids, seed)
	math.randomseed(seed or os.clock() * 1000000)
	while true do
		local uid = string.format(UID_FORMAT, math.random(0, UID_MAX))
		-- uid has to be unique in given context; also small risk of being negative
		if not vim.tbl_contains(uids, uid) and not vim.startswith(uid, "-") then
			---@diagnostic disable-next-line: return-type-mismatch
			return uid
		end
	end
end

---@param uid ical.uid_t
---@param vtodo ical.vtodo_t
---@return ical.ical_t
function M.create_ical_vtodo(uid, vtodo)
	local created_stamp = os.date("!%Y%m%dT%H%M%SZ")

	local priority = vtodo.priority or M.priority_t.undefined

	local description = nil
	if type(vtodo.description) == "string" then
		description = vtodo.description:gsub(
			"[\r\n]",
			function(s) return "\\" .. s end
		)
	end
	-- TODO: summary: enforce RFC 5545 compliance (no newlines, no semicolons,
	-- 75 chars maximum)
	local summary = vtodo.summary:gsub("[\r\n;]", ". ") or ""

	-- TODO: enforce no colons nor CRLFs in category names
	local categories = table.concat(vtodo.categories or {}, ",")

	local parent_uid_entry =
		(vtodo.parent_uid and "RELATED-TO;RELTYPE=PARENT:" .. vtodo.parent_uid or {})

	return table.concat(vim.tbl_flatten({
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"BEGIN:VTODO",
		"PRODID:decscribe",
		-- "PRODID:+//IDN bitfire.at//ical4android", -- NOTE: tasks.org's PRODID
		"DTSTAMP:" .. created_stamp,
		"UID:" .. uid,
		"CREATED:" .. created_stamp, -- TODO: parameterize? vtodo.created
		"LAST-MODIFIED:" .. created_stamp,
		"SUMMARY:" .. summary,
		(description and ("DESCRIPTION:" .. description) or {}),
		"PRIORITY:" .. priority,
		"STATUS:" .. (vtodo.completed and "COMPLETED" or "NEEDS-ACTION"),
		"CATEGORIES:" .. categories,
		-- "X-APPLE-SORT-ORDER:123456789",
		parent_uid_entry,
		"COMPLETED:" .. created_stamp,
		"PERCENT-COMPLETE:" .. (vtodo.completed and "100" or "0"),
		"END:VTODO",
		"END:VCALENDAR",
	}), "\r\n")
end

---Returns nothing (`nil`) if there were no matches.
---@param ical ical.ical_t
---@param prop_name string
---@return string? prop_value
---@return integer? prop_name_idx
---@return integer? prop_value_start_idx
---@return integer? prop_value_end_idx
function M.find_ical_prop(ical, prop_name)
	-- TODO: What if the property is at the beginning?
	-- It won't be prefixed with \r\n.
	local prop_name_idx = ical:find("\r\n" .. prop_name, 1, true)
	-- When no matches:
	if prop_name_idx == nil then return end

	-- ignore leading CRLF:
	prop_name_idx = prop_name_idx + 2

	-- idx + prop name + separator char (usually ":"):
	local prop_value_start_idx = prop_name_idx + #prop_name + 1

	local next_prop_name_idx = #ical
	for _, pname in ipairs(ICAL_PROP_NAMES) do
		local idx = ical:find("\r\n" .. pname, prop_value_start_idx, true)
		if idx then next_prop_name_idx = math.min(next_prop_name_idx, idx) end
	end
	-- TODO: What if the searched property is the last one?
	assert(next_prop_name_idx < #ical)

	-- NOTE: next_prop_name_idx points at CR in CRLF *before* the said prop name:
	local prop_value_end_idx = next_prop_name_idx - 1
	local prop_value = ical:sub(prop_value_start_idx, prop_value_end_idx)

	return prop_value, prop_name_idx, prop_value_start_idx, prop_value_end_idx
end

---@return ical.ical_t
local function insert_ical_prop(ical, prop_name, prop_value)
	-- find propname closest to the target propname in the ICAL_PROP_NAMES order,
	-- but still before it:
	local before_prop_order_idx = 1
	for i, pn in ipairs(ICAL_PROP_NAMES) do
		if prop_name == pn then break end
		if ical:find(pn, 1, true) then before_prop_order_idx = i end
	end
	local ical_lines = vim.split(ical, "\r\n")
	-- put the new prop *after* the line where "before prop" resides:
	local before_prop = ICAL_PROP_NAMES[before_prop_order_idx]
	local before_prop_idx = nil
	for idx, line in ipairs(ical_lines) do
		if vim.startswith(line, before_prop) then
			before_prop_idx = idx
			break
		end
	end
	assert(before_prop_idx)
	--
	table.insert(ical_lines, before_prop_idx + 1, prop_name .. ":" .. prop_value)
	-- NOTE: no "\r\n" at the end is needed due to an empty line in input end
	return table.concat(ical_lines, "\r\n")
end

---@return ical.ical_t
local function update_ical_prop(ical, prop_name, prop_value)
	local ical_lines = vim.split(ical, "\r\n")
	for idx, line in ipairs(ical_lines) do
		if vim.startswith(line, prop_name) then
			ical_lines[idx] = prop_name .. ":" .. prop_value
			break
		end
		-- TODO: remove dangling lines of prop value if it was multiline
	end
	-- NOTE: no "\r\n" at the end is needed due to an empty line in input end
	return table.concat(ical_lines, "\r\n")
end

---@param ical ical.ical_t
---@param prop_name string
---@param prop_value string
---@return ical.ical_t new_ical
function M.upsert_ical_prop(ical, prop_name, prop_value)
	local ical_lines = vim.split(ical, "\r\n")
	if
		#vim.tbl_filter(
			function(line) return vim.startswith(line, prop_name) end,
			ical_lines
		) > 0
	then
		return update_ical_prop(ical, prop_name, prop_value)
	end
	return insert_ical_prop(ical, prop_name, prop_value)
end

---@return ical.vtodo_t?
function M.parse_md_line(line)
	local checkbox_heading = line:match("^[-*]%s+[[][ x][]]%s+")
	-- there should always be a checkbox:
	if not checkbox_heading then return nil end
	-- TODO: handle more invalid entries

	local completed = checkbox_heading:match("x") ~= nil

	line = line:sub(#checkbox_heading + 1)

	local priority = nil
	local _, prio_end, prio = line:find("^!([0-9HML])%s*")
	if tonumber(prio) then
		priority = tonumber(prio)
		line = line:sub(prio_end + 1)
	elseif prio then
		priority = M.labelled_priorities[prio]
		line = line:sub(prio_end + 1)
	end

	local categories = {}
	while true do
		local cat_start, cat_end, cat = line:find("^:([-_%a]+):%s*")
		if not cat_start then break end
		table.insert(categories, cat)
		line = line:sub(cat_end + 1)
	end

	---@type ical.vtodo_t
	local vtodo = {
		summary = line,
		completed = completed,
		priority = priority or M.priority_t.undefined,
		categories = categories,
		description = nil,
	}

	return vtodo
end

---@param vtodo ical.vtodo_t
---@return string md_line a markdown line representing the todo entry
function M.to_md_line(vtodo)
	local line = "- [" .. (vtodo.completed and "x" or " ") .. "]"
	if vtodo.priority and vtodo.priority ~= M.priority_t.undefined then
		local prio_char = M.labelled_priorities[vtodo.priority] or vtodo.priority
		line = line .. " !" .. prio_char
	end
	if #vtodo.categories > 0 then
		local function in_colons(s) return ":" .. s .. ":" end
		local categories_str =
			table.concat(vim.tbl_map(in_colons, vtodo.categories), " ")
		line = line .. " " .. categories_str
	end
	if vtodo.summary then line = line .. " " .. vtodo.summary end
	-- TODO: handle newlines (\n as well as \r\n) in summary more elegantly
	line = line:gsub("\r?\n", " ")
	return line
end

return M
