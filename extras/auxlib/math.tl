local tables = require("auxlib.tables")
local macro (|>)! = tables.(|>)!

local record Math end

function Math.clamp(v: number, lo: number, hi: number): number
   if v < lo then return lo end
   if v > hi then return hi end
   return v
end

function Math.clamp_int(v: number, lo: integer, hi: integer): integer
   local n = math.floor(v + 0.5)
   if n < lo then return lo end
   if n > hi then return hi end
   return n
end

function Math.lerp(a: number, b: number, t: number): number
   return a + (b - a) * (t |> Math.clamp(0.0, 1.0))
end

function Math.inv_lerp(a: number, b: number, v: number): number
   local span = b - a
   if math.abs(span) < 1e-9 then return 0.0 end
   return ((v - a) / span) |> Math.clamp(0.0, 1.0)
end

function Math.remap(v: number, in_lo: number, in_hi: number, out_lo: number, out_hi: number): number
   return v |> Math.inv_lerp(in_lo, in_hi) |> Math.lerp(out_lo, out_hi)
end

function Math.round(v: number, decimals?: integer | nil): number
   local d = decimals or 0
   if d <= 0 then
      return math.floor(v + 0.5)
   end
   local scale = math.pow(10.0, d)
   return math.floor(v * scale + 0.5) / scale
end

function Math.sigmoid(x: number): number
   return 1.0 / (1.0 + math.exp(-x))
end

function Math.smooth_damp(current: number, target: number, speed: number, dt: number): number
   if dt <= 0 then return current end
   local k = 1.0 - math.exp(-math.max(0.0, speed) * dt)
   local next_v = current + (target - current) * k
   if math.abs(target - next_v) < 0.0005 then
      return target
   end
   return next_v
end

function Math.ease_out_quad(t: number): number
   local u = t |> Math.clamp(0.0, 1.0)
   return 1.0 - (1.0 - u) * (1.0 - u)
end

function Math.ease_out_cubic(t: number): number
   local u = t |> Math.clamp(0.0, 1.0)
   local inv = 1.0 - u
   return 1.0 - inv * inv * inv
end

function Math.ease_in_out_cubic(t: number): number
   local u = t |> Math.clamp(0.0, 1.0)
   if u < 0.5 then
      return 4.0 * u * u * u
   end
   local f = -2.0 * u + 2.0
   return 1.0 - (f * f * f) * 0.5
end

return Math