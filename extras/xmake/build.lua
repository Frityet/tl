import("core.base.option")
import("lib.detect.find_tool")

local function luajit(target)
   local prog = target and target:data("tl.luajit")
   if prog then
      return prog
   end
   local tool = assert(find_tool("luajit"), "Teal requires LuaJIT 2.1 or later on PATH")
   prog = tool.program
   if target then
      target:data_set("tl.luajit", prog)
   end
   return prog
end

local function outputdir(target)
   return path.absolute(path.join(target:autogendir(), "rules", "tl", "lua"), os.projectdir())
end

local function noconfigdir(target)
   return path.absolute(path.join(target:autogendir(), "rules", "tl", "noconfig"), os.projectdir())
end

local function lua_path(roots, inherited, with_init)
   local entries = {}
   for _, root in ipairs(roots) do
      table.insert(entries, path.join(root, "?.lua"))
      if with_init then
         table.insert(entries, path.join(root, "?/init.lua"))
      end
   end
   table.insert(entries, inherited)
   return table.concat(entries, ";")
end

local function runtime_roots(target)
   local roots = { outputdir(target) }
   for _, dep in ipairs(target:orderdeps()) do
      local dir = dep:data("tl.outputdir")
      if dir then
         table.insert(roots, dir)
      end
   end
   return roots
end

local function output_for_source(target, sourcefile)
   local root = target:data("tl.root")
   local abs_source = path.absolute(sourcefile, os.projectdir())
   local relative = path.relative(abs_source, root)
   assert(not path.is_absolute(relative) and not relative:startswith(".." .. path.sep()),
      "%s is outside the Teal source root %s. Set tl.root to a common directory.", abs_source, root)
   local outputfile = path.join(outputdir(target), (relative:gsub("%.tl$", ".lua")))
   return abs_source, outputfile
end

local function find_tlconfig(startdir)
   local dir = startdir
   for _ = 1, 20 do
      local config = path.join(dir, "tlconfig.lua")
      if os.isfile(config) then
         return config
      end
      local parent = path.directory(dir)
      if not parent or parent == "" or parent == dir then
         break
      end
      dir = parent
   end
end

local function load_tlconfig_info(configfile)
   if not configfile then
      return nil
   end
   local info = try { function() return io.load(configfile) end }
   if type(info) == "table" then
      return info
   end
end

local function resolve_module(modname, roots)
   local modpath = modname:gsub("%.", "/")
   local exts = { ".d.tl", ".tl", ".lua" }
   for _, ext in ipairs(exts) do
      for _, dir in ipairs(roots) do
         local cand = path.join(dir, modpath .. ext)
         if os.isfile(cand) then
            return cand
         end
         local init_cand = path.join(dir, modpath, "init" .. ext)
         if os.isfile(init_cand) then
            return init_cand
         end
      end
   end
end

local function collect_depfiles(abs_source, roots, extra_modules)
   local seen_files = {}
   local seen_mods = {}
   local deps = {}

   local function scan_file(filepath)
      if seen_files[filepath] or not os.isfile(filepath) then
         return
      end
      seen_files[filepath] = true
      table.insert(deps, filepath)

      local content = io.readfile(filepath)
      if not content then
         return
      end
      for modname in content:gmatch("require%s*%(?%s*[\"']([^\"']+)[\"']") do
         if not seen_mods[modname] then
            seen_mods[modname] = true
            local resolved = resolve_module(modname, roots)
            if resolved then
               scan_file(resolved)
            end
         end
      end
   end

   scan_file(abs_source)
   if extra_modules then
      for _, modname in ipairs(extra_modules) do
         if type(modname) == "string" and not seen_mods[modname] then
            seen_mods[modname] = true
            local resolved = resolve_module(modname, roots)
            if resolved then
               scan_file(resolved)
            end
         end
      end
   end

   table.sort(deps)
   return table.unique(deps)
end

function prepare_noconfig(target)
   if option.get("dry-run") then return end
   local dir = noconfigdir(target)
   local config = path.join(dir, "tlconfig.lua")
   if not os.isfile(config) then
      os.mkdir(dir)
      io.writefile(config, "return {}\n")
   end
end

function load_compiler(target)
   target:data_set("tl.root", target:scriptdir())
   target:data_set("tl.outputdir", outputdir(target))
end

function compile_bootstrap_file(target, batchcmds, sourcefile, opt)
   if sourcefile:endswith(".d.tl") then
      return
   end
   local root = target:data("tl.root")
   local lua = luajit(target)
   local bootstrap = path.join(root, "tl")
   local cwd = noconfigdir(target)
   local abs_source, outputfile = output_for_source(target, sourcefile)

   batchcmds:show_progress(opt.progress, "${color.build.object}compiling.tl %s", sourcefile)
   batchcmds:mkdir(path.directory(outputfile))
   batchcmds:vrunv(lua, {
      path(bootstrap), "--quiet", "--gen-target=5.1", "gen",
      "--root", path(root), "-o", path(outputfile), "--", path(abs_source)
   }, {
      curdir = cwd,
      envs = { TL_PATH = path.join(root, "?.lua"), PWD = cwd }
   })

   local deps = collect_depfiles(abs_source, { root })
   table.insert(deps, bootstrap)
   table.insert(deps, path.join(root, "teal.lua"))
   table.insert(deps, path.join(root, "teal/precompiled/default_env.lua"))
   table.insert(deps, path.join(root, "teal/reader_api.lua"))
   table.insert(deps, lua)
   table.sort(deps)
   deps = table.unique(deps)

   batchcmds:add_depfiles(deps)
   batchcmds:add_depvalues(os.getenv("LUA_PATH") or false, os.getenv("LUA_CPATH") or false)
   batchcmds:set_depmtime(os.mtime(outputfile))
   batchcmds:set_depcache(target:dependfile(outputfile))
end

function bundle_compiler(target, batchcmds, opt)
   local dir = outputdir(target)
   local root = target:data("tl.root")
   local lua = luajit(target)
   local bootstrap = path.join(root, "tl")
   local default_env = "teal/precompiled/default_env.lua"
   local reader_api = "teal/reader_api.lua"

   local out_tl = path.join(dir, "tl")
   local out_tl_lua = path.join(dir, "tl.lua")
   local out_teal_lua = path.join(dir, "teal.lua")
   local generated_env = path.join(dir, default_env)
   local generated_env_tmp = generated_env .. ".tmp"
   local out_reader_api = path.join(dir, reader_api)

   local sourcebatch = target:sourcebatches()["tl.compiler"]
   local generated_files = {}
   for _, sourcefile in ipairs(sourcebatch and sourcebatch.sourcefiles or {}) do
      if not sourcefile:endswith(".d.tl") then
         local _, outputfile = output_for_source(target, sourcefile)
         table.insert(generated_files, outputfile)
      end
   end

   local envs = { TL_PATH = path.join(root, "?.lua"), PWD = dir }
   batchcmds:show_progress(opt.progress, "${color.build.target}bundling.tl %s", target:name())
   batchcmds:mkdir(path.directory(generated_env))
   batchcmds:cp(path.join(root, default_env), generated_env)
   batchcmds:cp(path.join(root, reader_api), out_reader_api)
   batchcmds:vrunv(lua, { "precompiler.lua" }, { curdir = dir, envs = envs, stdout = generated_env_tmp })
   batchcmds:mv(generated_env_tmp, generated_env)
   batchcmds:vrunv(lua, { "extras/combine.lua", "teal.api.v2", "tl.lua" }, { curdir = dir })
   batchcmds:vrunv(lua, { "extras/combine.lua", "teal.init", "teal.lua" }, { curdir = dir })
   batchcmds:cp(bootstrap, out_tl)

   local deps = table.join(generated_files, {
      bootstrap, path.join(root, default_env), path.join(root, reader_api), lua
   })
   table.sort(deps)
   deps = table.unique(deps)

   local written_outputs = { out_tl_lua, out_teal_lua, generated_env }
   local min_mtime = os.mtime(written_outputs[1])
   for i = 2, #written_outputs do
      local mtime = os.mtime(written_outputs[i])
      if mtime < min_mtime then
         min_mtime = mtime
      end
   end
   if not os.isfile(out_tl) or not os.isfile(out_reader_api) then
      min_mtime = 0
   end

   batchcmds:add_depfiles(deps)
   batchcmds:add_depvalues(os.getenv("LUA_PATH") or false, os.getenv("LUA_CPATH") or false)
   batchcmds:set_depmtime(min_mtime)
   batchcmds:set_depcache(target:dependfile(out_teal_lua))
end

function load(target)
   if target:is_phony() then
      target:set("kind", "object")
   end
   local root = target:values("tl.root") or target:scriptdir()
   target:data_set("tl.root", path.absolute(root, target:scriptdir()))
   target:data_set("tl.outputdir", outputdir(target))
   target:add("deps", "tl", { inherit = false })
   target:set("policy", "build.fence", true)
end

function prepare(target)
   if target:name() == "tl.auxlib" then
      prepare_noconfig(target)
   end
end

function compile_file(target, batchcmds, sourcefile, opt)
   if sourcefile:endswith(".d.tl") then
      return
   end
   local root = target:data("tl.root")
   local compiler = target:dep("tl")
   local compiler_dir = compiler:scriptdir()
   local auxlib = target:name() == "tl.auxlib"
   local projectdir = os.projectdir()

   local roots = { root }
   for _, dir in ipairs(table.wrap(target:values("tl.includedirs"))) do
      table.insert(roots, path.absolute(dir, target:scriptdir()))
   end
   for _, dep in ipairs(target:orderdeps()) do
      local dep_root = dep:data("tl.root")
      if dep_root then
         table.insert(roots, dep_root)
      end
   end
   roots = table.unique(table.join(roots, { compiler_dir }))

   local tlconfig_file
   local tlconfig_info
   local dep_roots = table.clone(roots)
   local extra_modules = {}
   if not auxlib then
      tlconfig_file = find_tlconfig(projectdir)
      tlconfig_info = load_tlconfig_info(tlconfig_file)
      if tlconfig_info then
         local config_dir = path.directory(tlconfig_file)
         if type(tlconfig_info.source_dir) == "string" then
            table.insert(dep_roots, path.absolute(tlconfig_info.source_dir, config_dir))
         end
         if type(tlconfig_info.include_dir) == "table" then
            for _, dir in ipairs(tlconfig_info.include_dir) do
               if type(dir) == "string" then
                  table.insert(dep_roots, path.absolute(dir, config_dir))
               end
            end
         end
         if type(tlconfig_info.global_env_def) == "string" then
            table.insert(extra_modules, tlconfig_info.global_env_def)
         end
      end
   end
   dep_roots = table.unique(dep_roots)

   local lua = luajit(target)
   local script = path.join(outputdir(compiler), "tl")
   local abs_source, outputfile = output_for_source(target, sourcefile)

   local tl_path = auxlib and "" or os.getenv("TL_PATH")
   if tl_path then
      tl_path = lua_path(roots, tl_path, false)
   end
   local search_path = lua_path(table.unique(table.join(roots, runtime_roots(target))),
      os.getenv("LUA_PATH") or ";", true)

   local cwd = auxlib and noconfigdir(target) or projectdir
   local flags = auxlib and { "--gen-target=5.1" } or {}
   local args = table.join({ path(script), "--quiet" }, flags, {
      "gen", "--root", path(root), "-o", path(outputfile), "--", path(abs_source)
   })

   batchcmds:show_progress(opt.progress, "${color.build.object}compiling.tl %s", sourcefile)
   batchcmds:mkdir(path.directory(outputfile))
   batchcmds:vrunv(lua, args, {
      curdir = cwd,
      envs = { LUA_PATH = search_path, TL_PATH = tl_path, PWD = cwd }
   })

   local deps = collect_depfiles(abs_source, dep_roots, extra_modules)
   table.insert(deps, script)
   table.insert(deps, path.join(outputdir(compiler), "teal.lua"))
   table.insert(deps, lua)
   if tlconfig_file then
      table.insert(deps, tlconfig_file)
   end
   table.sort(deps)
   deps = table.unique(deps)

   batchcmds:add_depfiles(deps)
   batchcmds:add_depvalues(flags, search_path, tl_path or false, os.getenv("LUA_CPATH") or false)
   batchcmds:set_depmtime(os.mtime(outputfile))
   batchcmds:set_depcache(target:dependfile(outputfile))
end

function runenv(target)
   os.setenv("LUA_PATH", lua_path(runtime_roots(target), os.getenv("LUA_PATH") or ";", true))
end

function run_compiler(target)
   local script = path.join(outputdir(target), "tl")
   assert(os.isfile(script), "Build the Teal compiler with xmake build tl")
   local args = table.join({ script }, table.wrap(option.get("arguments")))
   os.execv(luajit(target), args, { curdir = os.projectdir(), envs = { PWD = os.projectdir() } })
end
