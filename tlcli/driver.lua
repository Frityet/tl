local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local os = _tl_compat and _tl_compat.os or os; local package = _tl_compat and _tl_compat.package or package; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table





local common = require("tlcli.common")
local teal = require("teal.init")


local driver = {}


local function filename_to_module_name(filename)
   local path = os.getenv("TL_PATH") or package.path
   for entry in path:gmatch("[^;]+") do
      local escaped = entry:gsub("%.", "%%.")
      local lua_pat = "^" .. escaped:gsub("%?", ".+") .. "$"
      local d_tl_pat = lua_pat:gsub("%%.lua%$", "%%.d%%.tl$")
      local tl_pat = lua_pat:gsub("%%.lua%$", "%%.tl$")

      for _, pat in ipairs({ tl_pat, d_tl_pat, lua_pat }) do
         local cap = filename:match(pat)
         if cap then
            return (cap:gsub("[/\\]", "."))
         end
      end
   end


   return (filename:gsub("%.lua$", ""):gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("[/\\]", "."))
end

function driver.setup_compiler(tlconfig, check_diagnostics)
   tlconfig._init_env_modules = tlconfig._init_env_modules or {}
   if tlconfig.global_env_def then
      table.insert(tlconfig._init_env_modules, 1, tlconfig.global_env_def)
   end

   local opts = {
      feat_arity = tlconfig["feat_arity"],
      gen_compat = tlconfig["gen_compat"],
      gen_target = tlconfig["gen_target"],
      no_stdlib = tlconfig["no_stdlib"] == true,
      diagnostics = check_diagnostics and tlconfig._diagnostics or nil,
      diagnostic_target = check_diagnostics and tlconfig._diagnostic_target or nil,
   }

   if (opts.gen_target == "5.4" or opts.gen_target == "5.5") and opts.gen_compat ~= "off" then
      common.die("gen-compat must be explicitly 'off' when gen-target is '5.4' or '5.5'")
   end

   local compiler = teal.compiler(opts)

   for _, name in ipairs(tlconfig._init_env_modules) do
      local _, _, err = compiler:require(name)
      if err then
         common.die("Error: " .. err)
      end
   end

   return compiler
end






local loaded_paths = setmetatable({}, { __mode = "k" })

local function already_loaded(compiler, input_file)
   local paths = loaded_paths[compiler]
   if not paths then
      paths = { count = 0, names = {} }
      loaded_paths[compiler] = paths
   end
   local order = compiler.env.loaded_order
   for i = paths.count + 1, #order do
      local file = order[i]
      local path = common.normalize(file)
      paths.names[path] = paths.names[path] or file
   end
   paths.count = #order

   local file = paths.names[common.normalize(input_file)]
   if file then
      return compiler:recall(file)
   end
end

function driver.process_module(compiler, filename)
   local module, check_err = already_loaded(compiler, filename)
   if module then
      return module, check_err
   end

   local is_stdin = filename == "-"
   local module_name
   local input
   local err

   if is_stdin then
      module_name = "stdin"
      input, err = compiler:input(io.input():read("*a"), "<stdin>")
   else
      module_name = filename_to_module_name(filename)
      input, err = compiler:open(filename)
   end
   if err then
      return nil, nil, err
   end

   return input:check(module_name)
end

return driver
