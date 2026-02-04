--#pragma strict_nil on
--
-- Example showcase: nillables, macros, and constant (literal) types.
-- This is intentionally verbose and "maximal" to demonstrate a wide swath of features.
--

-- -----------------------------------------------------------------------------
-- Macros (compile-time)
-- -----------------------------------------------------------------------------

-- Expression macro: increment
local macro inc!(x: Expression)
   return `$x + 1`
end

-- Expression macro: nil coalescing (explicit nil check)
local macro coalesce!(value: Expression, fallback: Expression)
   return `($value ~= nil and $value or $fallback)`
end

-- Expression macro: tagged string
local macro tagged!(tag: Expression, value: Expression)
   return `($tag .. ":" .. $value)`
end

-- Statement macro: print a titled section then run statements
local macro section!(title: Expression, ...: Statement)
   local out = block("statements")
   table.insert(out, `print("\n== " .. $title .. " ==")`)
   for i = 1, select("#", ...) do
      table.insert(out, select(i, ...))
   end
   return out
end

-- macroexp: emits a print at compile time (kept as a function at type level)
local macroexp trace(label: string, value: string)
   return print("[trace]", label, value)
end

-- -----------------------------------------------------------------------------
-- Constant (literal) types
-- -----------------------------------------------------------------------------

local type Percent = 0 | 25 | 50 | 75 | 100
local type Priority = 1 | 2 | 3 | 4 | 5
local type HttpCode = 200 | 201 | 204 | 400 | 404 | 500
local type Role = "admin" | "editor" | "viewer"
local type Env = "dev" | "test" | "prod"

local type Truth = true
local type Falsity = false
local type Flag = true | false

local enum Color
   "red"
   "green"
   "blue"
   "yellow"
end

-- Generic nillable type
local type Maybe<T> = T | nil

-- Literal boolean types (used in records and simple flags)

-- -----------------------------------------------------------------------------
-- Records using literals and nillables
-- -----------------------------------------------------------------------------

local record User
   id: integer
   name: string
   nickname: string | nil
   role: Role
   favorite: Color | nil
   verified: Flag
end

local record Palette
   primary: Color
   secondary: Color | nil
   accent: Color
end

local record HttpResponse
   code: HttpCode
   body: string
   cached: Flag
end

local record AuditEvent
   kind: "login" | "logout" | "error"
   success: Flag
   user_id: integer | nil
end

-- -----------------------------------------------------------------------------
-- Functions returning literal unions
-- -----------------------------------------------------------------------------

local function role_label(r: Role): "ADMIN" | "EDITOR" | "VIEWER"
   if r == "admin" then
      return "ADMIN"
   elseif r == "editor" then
      return "EDITOR"
   else
      return "VIEWER"
   end
end

local function status_label(code: HttpCode): "ok" | "created" | "nocontent" | "bad" | "notfound" | "error"
   if code == 200 then
      return "ok"
   elseif code == 201 then
      return "created"
   elseif code == 204 then
      return "nocontent"
   elseif code == 400 then
      return "bad"
   elseif code == 404 then
      return "notfound"
   else
      return "error"
   end
end

local function percent_label(p: Percent): "0%" | "25%" | "50%" | "75%" | "100%"
   if p == 0 then
      return "0%"
   elseif p == 25 then
      return "25%"
   elseif p == 50 then
      return "50%"
   elseif p == 75 then
      return "75%"
   else
      return "100%"
   end
end

local function next_priority(p: Priority): Priority
   if p == 1 then return 2
   elseif p == 2 then return 3
   elseif p == 3 then return 4
   elseif p == 4 then return 5
   else return 5
   end
end

-- -----------------------------------------------------------------------------
-- Nillables and optional parameters
-- -----------------------------------------------------------------------------

-- Optional parameter is implicitly nilable under strict nil
local function find_user(id: integer, cache?: {integer: User}): User | nil
   if cache and cache[id] then
      return cache[id]
   end
   return nil
end

local function display_name(u: User): string
   -- coalesce! macro picks nickname when present
   return coalesce!(u.nickname, u.name)
end

local function favorite_color(u: User): Color | nil
   return u.favorite
end

local function default_palette(user_pref?: Palette): Palette
   return coalesce!(user_pref, {
      primary = "blue",
      secondary = nil,
      accent = "yellow",
   })
end

local function response_for(code: HttpCode, body?: string): HttpResponse
   return {
      code = code,
      body = coalesce!(body, ""),
      cached = false,
   }
end

-- -----------------------------------------------------------------------------
-- Example data
-- -----------------------------------------------------------------------------

local users: {integer: User} = {
   [1] = {
      id = 1,
      name = "Ada",
      nickname = nil,
      role = "admin",
      favorite = "red",
      verified = true,
   },
   [2] = {
      id = 2,
      name = "Linus",
      nickname = "lin",
      role = "editor",
      favorite = nil,
      verified = false,
   },
   [3] = {
      id = 3,
      name = "Grace",
      nickname = "amazing",
      role = "viewer",
      favorite = "green",
      verified = true,
   },
}

local env: Env = "dev"
local palette: Palette = { primary = "red", secondary = nil, accent = "green" }
local warnings: {AuditEvent} = {
   { kind = "login", success = true, user_id = 1 },
   { kind = "error", success = false, user_id = nil },
   { kind = "logout", success = true, user_id = 2 },
}

-- -----------------------------------------------------------------------------
-- Main showcase
-- -----------------------------------------------------------------------------

section!("Constants",
   do
      local p: Percent = 75
      local nextp = inc!(p) -- not a Percent; just demo of macro expression usage
      local always: Truth = true
      local never: Falsity = false
      trace("env", env)
      print("percent:", percent_label(p))
      print("nextp (raw):", nextp)
      print("flags:", always, never)
   end
)

section!("Users",
   for _, u in pairs(users) do
      local name = display_name(u)
      local label = role_label(u.role)
      trace("user", tagged!(label, name))

      local fav = favorite_color(u)
      if fav then
         print("favorite:", fav)
      else
         print("favorite: <none>")
      end
   end
)

section!("Nil Handling",
   do
      local maybe = find_user(2, users)
      if maybe then
         print("found:", display_name(maybe))
      else
         print("not found")
      end

      local p2 = default_palette(nil)
      print("palette:", p2.primary, p2.secondary, p2.accent)

      local mp: Maybe<Palette> = palette
      if mp then
         print("maybe palette accent:", mp.accent)
      end
   end
)

section!("HTTP",
   do
      local resp = response_for(404, "missing")
      print("http:", status_label(resp.code), resp.body)
   end
)

section!("Audit",
   for _, ev in ipairs(warnings) do
      if ev.user_id then
         print("event:", ev.kind, "user", ev.user_id)
      else
         print("event:", ev.kind, "user <none>")
      end
   end
)

section!("Priority",
   do
      local p: Priority = 3
      local p2 = next_priority(p)
      print("priority:", p, "->", p2)
   end
)

-- -----------------------------------------------------------------------------
-- Notes (uncomment to see type errors under strict nil)
-- -----------------------------------------------------------------------------
--
-- local bad_user: User = { id = 4, name = "X", role = "viewer", verified = true }
-- -- Error: missing required fields (nickname, favorite)
--
-- local function bad_optional(x?: integer): User
--    local u: User = { id = 9, name = "Y", nickname = nil, role = "admin", favorite = nil, verified = true }
--    u.id = x -- Error: x is integer | nil
--    return u
-- end
