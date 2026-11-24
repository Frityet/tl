#!/bin/sh
set -eu

tl=$1
shift
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

cat > native.tl <<'TEAL'
--#pragma strict on
local function sum(limit: integer): integer
   local result = 0
   for i = 1, limit do
      result = result + i
   end
   return result
end
print(sum(9))
TEAL

"$tl" -q check native.tl
"$tl" -q --gen-target=c gen native.tl -o native.c
"$@" -std=c11 native.c -o native
test "$(./native)" = 45

sed '1d' native.tl > nonstrict.tl
if "$tl" -q --gen-target=c gen nonstrict.tl -o nonstrict.c > diagnostic 2>&1; then
   echo "Non-strict input passed C generation" >&2
   exit 1
fi
grep -q "requires '--#pragma strict on'" diagnostic

printf 'return { value = "through LuaJIT" }\n' > helper.tl
cat > script.tl <<'TEAL'
local macro twice!(x: Expression)
   local out = block("statements")
   table.insert(out, `$x`)
   table.insert(out, `$x`)
   return out
end

local helper = require("helper")
twice!(print(helper.value .. " " .. arg[1]))
TEAL

"$tl" -q --gen-target=5.1 run script.tl passed > script.out
printf 'through LuaJIT passed\nthrough LuaJIT passed\n' > script.expected
cmp script.out script.expected
