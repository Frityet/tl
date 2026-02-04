--#pragma strict_nil on
-- Sample data for the ticket triage example.

local type Triage = require("example.triage.types")
local type User = Triage.User
local type Ticket = Triage.Ticket
local type TicketSet = Triage.TicketSet
local type Snapshot = Triage.Snapshot

local users: {integer: User} = {
   [1] = { id = 1, name = "Ada", timezone = "UTC" },
   [2] = { id = 2, name = "Linus", timezone = "UTC+2" },
   [3] = { id = 3, name = "Grace", timezone = "UTC-5" },
}

local function ticket_set(items: {Ticket}): TicketSet
   return { items = items }
end

local function seed(now: integer): Snapshot
   local tickets: {Ticket} = {
      {
         id = 1001,
         summary = "Checkout fails with 500",
         status = "open",
         priority = 1,
         channel = "web",
         owner = nil,
         opened_at = now - 80,
         resolved_at = nil,
         sla = 120,
         escalation = "none",
         tags = { "payments", "backend" },
         customer_tier = "enterprise",
         acknowledged = false,
         root_cause = nil,
      },
      {
         id = 1002,
         summary = "Unable to reset password",
         status = "triaged",
         priority = 2,
         channel = "email",
         owner = users[2],
         opened_at = now - 45,
         resolved_at = nil,
         sla = 60,
         escalation = "lead",
         tags = { "auth", "email" },
         customer_tier = "pro",
         acknowledged = true,
         root_cause = nil,
      },
      {
         id = 1003,
         summary = "Mobile app crash on launch",
         status = "in_progress",
         priority = 3,
         channel = "chat",
         owner = users[1],
         opened_at = now - 220,
         resolved_at = nil,
         sla = 240,
         escalation = "lead",
         tags = { "mobile" },
         customer_tier = "enterprise",
         acknowledged = true,
         root_cause = nil,
      },
      {
         id = 1004,
         summary = "Billing page slow",
         status = "waiting",
         priority = 4,
         channel = "phone",
         owner = users[3],
         opened_at = now - 300,
         resolved_at = nil,
         sla = 480,
         escalation = "none",
         tags = { "performance" },
         customer_tier = "free",
         acknowledged = true,
         root_cause = nil,
      },
      {
         id = 1005,
         summary = "Webhook signature mismatch",
         status = "resolved",
         priority = 2,
         channel = "web",
         owner = users[1],
         opened_at = now - 180,
         resolved_at = now - 30,
         sla = 120,
         escalation = "none",
         tags = { "integrations", "security" },
         customer_tier = "pro",
         acknowledged = true,
         root_cause = "rotated secret",
      },
   }

local notes: {Triage.Note} = {
      {
         ticket_id = 1001,
         author = "system",
         body = "Auto-detected spike in 500s",
         kind = "internal",
         created_at = now - 79,
      },
      {
         ticket_id = 1002,
         author = "support",
         body = "Asked customer to verify email domain",
         kind = "public",
         created_at = now - 40,
      },
      {
         ticket_id = 1005,
         author = "ops",
         body = "Root cause identified and fixed",
         kind = "internal",
         created_at = now - 35,
      },
   }

   return {
      now = now,
      tickets = ticket_set(tickets),
      notes = notes,
   }
end

return {
   seed = seed,
   users = users,
}
