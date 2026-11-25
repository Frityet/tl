--#pragma strict_nil on

-- Summarize completed CI jobs from GitHub Actions, a TSV file, or stdin.
-- GitHub mode uses gh and the Lua module dkjson (luarocks install dkjson).
--
--   ./tl -I extras run example/showcase.tl -- --run "$RUN_ID" --budget 10m --top 5

local format = require("auxlib.format")
local macro f! = format.f!

local argparse = require("auxlib.argparse")
local macro parser! = argparse.parser!

local tables = require("auxlib.tables")
local macro (|>)! = tables.(|>)!
local macro (||>)! = tables.(||>)!
local macro (+=>)! = tables.(+=>)!

const SECONDS_PER_MINUTE = 60
const SECONDS_PER_HOUR = 60 * SECONDS_PER_MINUTE

local record Job
   conclusion: string
   seconds: number
   name: string
end

local record Assessment
   job: Job
   failed: boolean
   over_budget: boolean
end

local record Totals
   seconds: number
   attention: integer
   over_budget: integer
end

const ACCEPTABLE_CONCLUSIONS: {string: boolean} = {
   success = true,
   skipped = true,
   neutral = true,
}

local function whole_number(text: string?): number?
   if text and text:match("^%d+$") then
      local value = tonumber(text)
      if value and value < math.huge then
         return value
      end
   end
end

local function budget_option(text: string): number?, string?
   local count, unit = text:match("^(%d+)([smh]?)$")
   local value = whole_number(count)
   if value then
      if unit == "m" then value = value * SECONDS_PER_MINUTE end
      if unit == "h" then value = value * SECONDS_PER_HOUR end
      if value > 0 and value < math.huge then return value end
   end
   return nil, "--budget expects a positive duration such as 90s, 5m, or 1h"
end

local function top_option(text: string): integer?, string?
   local top = argparse.integer(text)
   if top and top >= 0 then return top end
   return nil, "--top expects a non-negative whole number"
end

local function run_option(text: string): string?, string?
   if text:match("^%d+$") then return text end
   return nil, "--run expects a numeric GitHub Actions run ID"
end

local function repo_option(text: string): string?, string?
   if text:match("^[%w][%w%-]*/[%w%._%-]+$") then return text end
   return nil, "--repo expects OWNER/REPO"
end

local record Options<parser!({
   name = "tl -I extras run example/showcase.tl --",
   description = "Summarize completed CI jobs, slowest first.",
   epilog = "Exit 0 for a clean report, 1 for jobs needing attention, or 2 for input errors.\n" ..
      "Success, skipped, and neutral conclusions pass unless they exceed the budget.",
   arguments = {
      { name = "path", args = "?", metavar = "jobs.tsv|-",
        description = "Read conclusion, whole seconds, and job name from tab-separated rows. Defaults to stdin." },
   },
   options = {
      { name = "--run", target = "run_id", metavar = "ID", convert = run_option,
        description = "Fetch a GitHub Actions run with gh and dkjson. Takes the place of the input file." },
      { name = "--repo", metavar = "OWNER/REPO", convert = repo_option,
        description = "Use this repository with --run. Defaults to the current repository." },
      { name = "--budget", metavar = "DURATION", convert = budget_option,
        description = "Flag jobs that exceed this duration (e.g. 90s, 5m, or 1h)." },
      { name = "--top", metavar = "N", default = "10", convert = top_option,
        description = "Show the N slowest jobs plus every flagged job." },
   },
})>
   path: string?
   run_id: string?
   repo: string?
   budget: number?
   top: integer
end

local function read_jobs(input: FILE): {Job}?, string?
   local jobs: {Job} = {}
   local line_number = 0
   while true do
      local line, problem = input:read("*l")
      if line == nil then
         if problem then
            return nil, problem
         end
         return jobs
      end
      line_number = line_number + 1
      if not line:match("^%s*$") then
         line = line:gsub("\r$", "")
         local conclusion, duration, name = line:match("^([a-z_]+)\t([^\t]+)\t([^\t]+)$")
         local seconds = whole_number(duration)
         if not conclusion or not name or not seconds then
            return nil, f!"line {line_number}: expected conclusion, whole seconds, and job name"
         end
         table.insert(jobs, { conclusion = conclusion, seconds = seconds, name = name })
      end
   end
end

const DAYS_BEFORE_MONTH: {integer} = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 }

-- GitHub's timestamps are UTC. Count days directly so the host timezone has no effect.
local function utc_seconds(timestamp: string): number?
   local y, m, d, h, mi, s, suffix = timestamp:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
   )
   local year, month, day = tonumber(y, 10), tonumber(m, 10), tonumber(d, 10)
   local hour, minute, second = tonumber(h, 10), tonumber(mi, 10), tonumber(s, 10)
   if not year or not month or not day or not hour or not minute or not second or not suffix then
      return nil
   end
   if year == 0 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59 then
      return nil
   end

   local fraction = 0.0
   if suffix ~= "Z" then
      local decimal = suffix:match("^(%.%d+)Z$")
      if not decimal then return nil end
      fraction = tonumber(decimal) or 0
   end

   local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
   local month_length = DAYS_BEFORE_MONTH[month + 1] - DAYS_BEFORE_MONTH[month]
   if leap and month == 2 then month_length = month_length + 1 end
   if day > month_length then return nil end

   local previous = year - 1
   local days = 365 * previous + math.floor(previous / 4) - math.floor(previous / 100) +
      math.floor(previous / 400) + DAYS_BEFORE_MONTH[month] + day - 1
   if leap and month > 2 then days = days + 1 end
   return (days * 24 + hour) * SECONDS_PER_HOUR + minute * SECONDS_PER_MINUTE + second + fraction
end

local record JsonDecoder
   decode: function(string, integer, {any: any}, {any: any}, {any: any}): any, integer, string?
end

const JSON_NULL: {any: any} = {}
const JSON_OBJECT: {any: any} = {}
const JSON_ARRAY: {any: any} = {}
const ZERO_TIMESTAMP = "0001-01-01T00:00:00Z"
const GH_SUCCESS_MARKER = "__SHOWCASE_GH_OK__"

local function job_seconds(started: any, completed: any, conclusion: string): number?
   if started == nil or started == JSON_NULL or started == "" or started == ZERO_TIMESTAMP then
      if conclusion == "skipped" or conclusion == "cancelled" then return 0 end
      return nil
   end
   if started is string and completed is string then
      local first, last = utc_seconds(started), utc_seconds(completed)
      if first and last and last >= first then
         return math.floor(last - first + 0.5)
      end
   end
end

local function decode_jobs(payload: string, json: JsonDecoder): {Job}?, string?
   local response, next_byte, problem = json.decode(payload, 1, JSON_NULL, JSON_OBJECT, JSON_ARRAY)
   if problem then return nil, f!"invalid job JSON: {problem}" end
   if payload:sub(next_byte):find("%S") then
      return nil, "unexpected data after the job JSON"
   end
   if not (response is table) or getmetatable(response) ~= JSON_OBJECT then
      return nil, "expected a GitHub job object"
   end
   local entries = (response as {string: any}).jobs
   if not (entries is table) or getmetatable(entries) ~= JSON_ARRAY then
      return nil, "expected a jobs list in the GitHub response"
   end

   local jobs: {Job} = {}
   for i, entry in ipairs(entries as {any}) do
      if not (entry is table) or getmetatable(entry) ~= JSON_OBJECT then
         return nil, f!"invalid job at index {i}"
      end
      local fields = entry as {string: any}
      local status = fields.status
      if not (status is string) then return nil, f!"missing status for job {i}" end
      if status == "completed" then
         local name, conclusion = fields.name, fields.conclusion
         if not (name is string) or not (conclusion is string) or conclusion == "" then
            return nil, f!"missing name or conclusion for completed job {i}"
         end
         local display_name = (name:gsub("%c", " "))
         local seconds = job_seconds(fields.startedAt, fields.completedAt, conclusion)
         if not seconds then return nil, f!"invalid timestamps for {display_name}" end
         table.insert(jobs, { name = display_name, conclusion = conclusion, seconds = seconds })
      end
   end
   return jobs
end

local function fetch_jobs(run_id: string, repo: string?): {Job}?, string?
   local module_name = "dkjson"
   local ok, json = pcall(require, module_name)
   if not ok then return nil, "GitHub mode requires dkjson (luarocks install dkjson)" end

   -- The argument converters validate both values before they enter the shell command.
   local command = f!"gh run view {run_id} --json jobs"
   if repo then command = command .. " --repo " .. repo end
   -- On Lua 5.1, closing a pipe can succeed even when its child failed.
   local pipe, open_error = io.popen(command .. " && echo " .. GH_SUCCESS_MARKER, "r")
   if not pipe then return nil, open_error or "could not start gh" end
   local output, read_error = pipe:read("*a")
   local closed = pipe:close()
   if not output then return nil, read_error or "could not read gh output" end
   local payload = output:match("^(.*)" .. GH_SUCCESS_MARKER .. "%s*$")
   if not closed or not payload then return nil, "gh run view failed" end
   return decode_jobs(payload, json as JsonDecoder)
end

local function elapsed(seconds: number): string
   local whole_minutes = math.floor(seconds / SECONDS_PER_MINUTE)
   return f!"{whole_minutes}m {seconds % SECONDS_PER_MINUTE:02.0f}s"
end

local function assess(job: Job, budget: number?): Assessment
   return {
      job = job,
      failed = not ACCEPTABLE_CONCLUSIONS[job.conclusion],
      over_budget = budget ~= nil and job.seconds > budget,
   }
end

local function add_totals(totals: Totals, row: Assessment): Totals
   totals.seconds = totals.seconds + row.job.seconds
   if row.failed or row.over_budget then
      totals.attention = totals.attention + 1
   end
   if row.over_budget then
      totals.over_budget = totals.over_budget + 1
   end
   return totals
end

local function print_report(jobs: {Job}, options: Options): integer
   -- table.sort rearranges jobs in place.
   jobs |> table.sort(|a, b| -> do
      if a.seconds ~= b.seconds then return a.seconds > b.seconds end
      if a.name ~= b.name then return a.name < b.name end
      return a.conclusion < b.conclusion
   end)

   local rows = jobs ||> |job, _| -> assess(job, options.budget)
   local initial: Totals = { seconds = 0, attention = 0, over_budget = 0 }
   local totals = rows +=> { initial, add_totals }
   local shown = 0
   print("Conclusion          Time  Job")
   for i, row in ipairs(rows) do
      if i <= options.top or row.failed or row.over_budget then
         local job = row.job
         local note = row.over_budget and "  [over budget]" or ""
         print(f!"{job.conclusion:-15s} {elapsed(job.seconds):8s}  {job.name}{note}")
         shown = shown + 1
      end
   end
   if shown < #jobs then
      print(f!"Showing {shown} of {#jobs} jobs")
   end
   print()
   local job_count = #jobs
   local noun = job_count == 1 and "job" or "jobs"
   print(f!"{job_count} {noun}, {totals.attention} needing attention, {elapsed(totals.seconds)} total job time")
   local budget = options.budget
   if budget then
      print(f!"Budget {elapsed(budget)} per job, {totals.over_budget} over")
   end
   return totals.attention
end

local function input_error(message: string): integer
   io.stderr:write("showcase: ", message, "\n")
   return 2
end

local function main(): integer
   local options, message, status = Options.parse(arg)
   if not options then
      if status ~= 0 then return input_error(message or Options.usage()) end
      print(message or Options.help())
      return status
   end

   local run_id, path, repo = options.run_id, options.path, options.repo
   if run_id and path then
      return input_error("--run and an input file are mutually exclusive")
   end
   if repo and not run_id then
      return input_error("--repo requires --run")
   end

   local source: string
   local jobs, problem: {Job}?, string?
   if run_id then
      source = f!"GitHub run {run_id}"
      jobs, problem = fetch_jobs(run_id, repo)
   else
      local input = io.stdin
      source = "stdin"
      if path and path ~= "-" then
         local file, open_error = io.open(path, "r")
         if not file then
            return input_error(open_error or f!"could not open {path}")
         end
         input, source = file, path
      end
      jobs, problem = read_jobs(input)
      if input ~= io.stdin then
         input:close()
      end
   end
   if not jobs then
      return input_error(f!"{source}: {problem or 'could not read jobs'}")
   end
   if #jobs == 0 then
      return input_error(f!"{source}: no completed jobs")
   end
   if print_report(jobs, options) > 0 then
      return 1
   end
   return 0
end

os.exit(main())
