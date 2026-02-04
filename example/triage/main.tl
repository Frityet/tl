--#pragma strict_nil on
-- Ticket triage CLI (example program)
-- Demonstrates literal types, nillables, macros, and macroexp.

local type Triage = require("example.triage.types")
local type Ticket = Triage.Ticket
local type Summary = Triage.Summary
local type Maybe<T> = Triage.Maybe<T>

local data = require("example.triage.data")
local logic = require("example.triage.logic")

-- -----------------------------------------------------------------------------
-- Macros for reporting
-- -----------------------------------------------------------------------------

local macro section!(title: Expression, ...: Statement)
   local out = block("statements")
   table.insert(out, `print("\n== " .. $title .. " ==")`)
   for i = 1, select("#", ...) do
      local b = select(i, ...)
      table.insert(out, b)
   end
   return out
end

local macro metric!(label: Expression, value: Expression)
   return `print(" - " .. $label .. ":", $value)`
end

local macro bullet!(value: Expression)
   return `print(" * " .. $value)`
end

-- -----------------------------------------------------------------------------
-- Main flow
-- -----------------------------------------------------------------------------

local now = 10000
local snapshot = data.seed(now)

section!("Overview",
   metric!("tickets_total", #snapshot.tickets),
   metric!("notes", #snapshot.notes)
)

local summary: Summary = logic.summary(snapshot.tickets.items, snapshot.now)

section!("Status Counts",
   metric!("open", summary.open),
   metric!("triaged", summary.triaged),
   metric!("in_progress", summary.in_progress),
   metric!("waiting", summary.waiting),
   metric!("resolved", summary.resolved),
   metric!("closed", summary.closed),
   metric!("at_risk", summary.at_risk),
   metric!("breached", summary.breached)
)

local queue: {Ticket} = logic.triage_queue(snapshot.tickets.items, snapshot.now)

section!("Triage Queue",
   for _, t in ipairs(queue) do
      local line = logic.render_ticket(t, snapshot.now)
      local action = logic.next_action(t, snapshot.now)
      local notify = logic.should_notify(t, snapshot.now)
      bullet!(line .. " | action=" .. action .. " notify=" .. tostring(notify))
   end
)

section!("Ownership",
   for _, t in ipairs(snapshot.tickets.items) do
      local owner: Maybe<Triage.User> = logic.optional_owner(t)
      if owner then
         bullet!("#" .. tostring(t.id) .. " -> " .. owner.name)
      else
         bullet!("#" .. tostring(t.id) .. " -> (unassigned)")
      end
   end
)

section!("Escalations",
   for _, t in ipairs(snapshot.tickets.items) do
      local esc = logic.escalation_for(t, snapshot.now)
      if esc ~= "none" then
         bullet!("#" .. tostring(t.id) .. " -> " .. esc)
      end
   end
)

section!("Notes",
   for _, n in ipairs(snapshot.notes) do
      local prefix = n.kind == "internal" and "[internal]" or "[public]"
      bullet!(prefix .. " #" .. tostring(n.ticket_id) .. " " .. n.body)
   end
)
