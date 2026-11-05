









local foreign_require = require
local bit = foreign_require("bit")
local K = {
   0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
   0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
   0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
   0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
   0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
   0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
   0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
   0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local function word(n)
   return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function sha256(source)
   local bits = #source * 8
   local data = source .. string.char(128) .. string.rep("\0", (55 - #source) % 64) .. word(math.floor(bits / 4294967296)) .. word(bits % 4294967296)
   local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
   for offset = 1, #data, 64 do
      local w = {}
      for i = 1, 16 do
         local a, b, c, d = data:byte(offset + (i - 1) * 4, offset + (i - 1) * 4 + 3)
         w[i] = bit.tobit(a * 16777216 + b * 65536 + c * 256 + d)
      end
      for i = 17, 64 do
         local a, b = w[i - 15], w[i - 2]
         local s0 = bit.bxor(bit.ror(a, 7), bit.ror(a, 18), bit.rshift(a, 3))
         local s1 = bit.bxor(bit.ror(b, 17), bit.ror(b, 19), bit.rshift(b, 10))
         w[i] = bit.tobit(w[i - 16] + s0 + w[i - 7] + s1)
      end
      local a, b, c, d, e, f, g, v = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
      for i = 1, 64 do
         local s1 = bit.bxor(bit.ror(e, 6), bit.ror(e, 11), bit.ror(e, 25))
         local ch = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g))
         local t1 = bit.tobit(v + s1 + ch + K[i] + w[i])
         local s0 = bit.bxor(bit.ror(a, 2), bit.ror(a, 13), bit.ror(a, 22))
         local maj = bit.bxor(bit.band(a, b), bit.band(a, c), bit.band(b, c))
         v, g, f, e, d, c, b, a = g, f, e, bit.tobit(d + t1), c, b, a, bit.tobit(t1 + s0 + maj)
      end
      local values = { a, b, c, d, e, f, g, v }
      for i = 1, 8 do h[i] = bit.tobit(h[i] + values[i]) end
   end
   local out = {}
   for i = 1, 8 do out[i] = string.format("%08x", h[i] < 0 and h[i] + 4294967296 or h[i]) end
   return table.concat(out)
end
return sha256
