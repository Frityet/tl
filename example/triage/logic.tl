--#pragma strict_nil on
-- Business logic for the ticket triage example.

local type Triage = require("example.triage.types")
local type Ticket = Triage.Ticket
local type Summary = Triage.Summary
local type Percent = Triage.Percent
local type SlaState = Triage.SlaState
local type Escalation = Triage.Escalation
local type Flag = Triage.Flag
local type Maybe<T> = Triage.Maybe<T>
local type User = Triage.User

local function age_minutes(t: Ticket, now: integer): integer
   local end_at = t.resolved_at and t.resolved_at or now
   return end_at - t.opened_at
end

local function progress_percent(t: Ticket, now: integer): Percent
   local age = age_minutes(t, now)
   -- compute percent bucket based on SLA
   local pct = math.floor((age * 100) / t.sla)
   if pct <= 0 then
      return 0
   elseif pct <= 25 then
      return 25
   elseif pct <= 50 then
      return 50
   elseif pct <= 75 then
      return 75
   else
      return 100
   end
end

local function sla_state(t: Ticket, now: integer): SlaState
   local age = age_minutes(t, now)
   if age * 100 <= t.sla * 80 then
      return "on_time"
   elseif age <= t.sla then
      return "at_risk"
   else
      return "breached"
   end
end

local function escalation_for(t: Ticket, now: integer): Escalation
   local state = sla_state(t, now)
   if state == "breached" and (t.priority == 1 or t.priority == 2) then
      return "oncall"
   elseif state == "at_risk" and t.priority == 1 then
      return "lead"
   else
      return "none"
   end
end

local function should_notify(t: Ticket, now: integer): Flag
   if t.status == "open" and escalation_for(t, now) ~= "none" then
      return true
   end
   return false
end

local function assign_owner(t: Ticket, owner?: User): Ticket
   t.owner = owner
   return t
end

local function mark_acknowledged(t: Ticket): Ticket
   t.acknowledged = true
   return t
end

local function triage_queue(tickets: {Ticket}, now: integer): {Ticket}
   local out: {Ticket} = {}
   for _, t in ipairs(tickets) do
      if t.status == "open" or t.status == "triaged" then
         table.insert(out, t)
      elseif t.status == "waiting" then
         -- waiting tickets are pulled in when they are about to breach
         if sla_state(t, now) ~= "on_time" then
            table.insert(out, t)
         end
      end
   end
   return out
end

local function summary(tickets: {Ticket}, now: integer): Summary
   local s: Summary = {
      total = 0,
      open = 0,
      triaged = 0,
      in_progress = 0,
      waiting = 0,
      resolved = 0,
      closed = 0,
      at_risk = 0,
      breached = 0,
   }

   for _, t in ipairs(tickets) do
      s.total = s.total + 1

      if t.status == "open" then s.open = s.open + 1 end
      if t.status == "triaged" then s.triaged = s.triaged + 1 end
      if t.status == "in_progress" then s.in_progress = s.in_progress + 1 end
      if t.status == "waiting" then s.waiting = s.waiting + 1 end
      if t.status == "resolved" then s.resolved = s.resolved + 1 end
      if t.status == "closed" then s.closed = s.closed + 1 end

      local state = sla_state(t, now)
      if state == "at_risk" then
         s.at_risk = s.at_risk + 1
      elseif state == "breached" then
         s.breached = s.breached + 1
      end
   end

   return s
end

local function next_action(t: Ticket, now: integer): string
   local state = sla_state(t, now)
   if t.status == "open" and t.owner == nil then
      return "assign"
   elseif t.status == "open" and state == "breached" then
      return "escalate"
   elseif t.status == "triaged" and t.owner == nil then
      return "assign"
   elseif t.status == "waiting" and state ~= "on_time" then
      return "follow_up"
   elseif t.status == "resolved" and t.root_cause == nil then
      return "write_rca"
   end
   return "monitor"
end

local function render_ticket(t: Ticket, now: integer): string
   local owner_name = "(unassigned)"
   local owner = t.owner
   if owner then
      owner_name = owner.name
   end
   local p = progress_percent(t, now)
   return string.format(
      "#%d [%s] p%d %s %s %%: %s",
      t.id, t.status, t.priority, owner_name, tostring(p), t.summary
   )
end

local function optional_owner(t: Ticket): Maybe<User>
   return t.owner
end

return {
   age_minutes = age_minutes,
   progress_percent = progress_percent,
   sla_state = sla_state,
   escalation_for = escalation_for,
   should_notify = should_notify,
   assign_owner = assign_owner,
   mark_acknowledged = mark_acknowledged,
   triage_queue = triage_queue,
   summary = summary,
   next_action = next_action,
   render_ticket = render_ticket,
   optional_owner = optional_owner,
}
