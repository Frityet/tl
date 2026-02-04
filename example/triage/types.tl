--#pragma strict_nil on
-- Types for the ticket triage example.

local record triage
   -- String literal unions (constant types)
   type Status =
       "open"
      | "triaged"
      | "in_progress"
      | "waiting"
      | "resolved"
      | "closed"

   type Tier = "free" | "pro" | "enterprise"
   type Escalation = "none" | "lead" | "oncall"
   type SlaState = "on_time" | "at_risk" | "breached"

   -- Numeric literal unions
   type Priority = 1 | 2 | 3 | 4 | 5
   type SlaMinutes = 15 | 30 | 60 | 120 | 240 | 480
   type Percent = 0 | 25 | 50 | 75 | 100

   -- Boolean literal union
   type Flag = true | false
   type NoteKind = "public" | "internal"

   -- Classic enum (string constants)
   enum Channel
      "email"
      "chat"
      "phone"
      "web"
   end

   -- Generic nillable
   type Maybe<T> = T | nil

   record User
      id: integer
      name: string
      timezone: string
   end

   record Ticket
      id: integer
      summary: string
      status: Status
      priority: Priority
      channel: Channel
      owner: User | nil
      opened_at: integer
      resolved_at: integer | nil
      sla: SlaMinutes
      escalation: Escalation
      tags: {string}
      customer_tier: Tier
      acknowledged: Flag
      root_cause: string | nil
   end

   record Note
      ticket_id: integer
      author: string
      body: string
      kind: NoteKind
      created_at: integer
   end

   record TicketSet
      items: {Ticket}

      -- macroexp: compile-time expansion for simple accessors
      metamethod __len: function(self: TicketSet): integer = macroexp(self: TicketSet): integer
         return #self.items
      end
   end

   record Summary
      total: integer
      open: integer
      triaged: integer
      in_progress: integer
      waiting: integer
      resolved: integer
      closed: integer
      at_risk: integer
      breached: integer
   end

   record Snapshot
      now: integer
      tickets: TicketSet
      notes: {Note}
   end
end

return triage
