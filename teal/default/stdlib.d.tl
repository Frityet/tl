--#pragma strict_nil on
-- This is the Teal standard library.
--
-- It should be recognizable as a pretty standard Lua standard
-- library, but in practice it is a "common denominator" definition,
-- which depicts the common subset of what you can get in any
-- Lua 5.1+ version when using compat-5.3. For example, there
-- are no definitions for either setfenv (5.1-specific) or
-- _ENV (5.2+-specific).
--
-- If you write code targeting the Teal standard library, it should
-- be able to run in any Lua 5.1+ version if compat53 is installed
-- and code is built with --gen-compat=on (which is the default).

local enum FileStringMode
   "a" "l" "L" "*a" "*l" "*L"
end

local enum FileNumberMode
   "n" "*n"
end

local enum FileMode
   "a" "l" "L" "*a" "*l" "*L" "n" "*n"
end

--- Create, resume and inspect cooperative Lua coroutines.
global record coroutine
   type Function = function(any...): any...

   --- Close a suspended or dead coroutine. Returns success and an error message on failure; availability depends on the runtime.
   --- @return The result values; check for nil where indicated in the signature.
   close: function(thread): boolean, string | nil
   --- Create a suspended coroutine for a function. Resume it to start execution.
   create: function(Function): thread
   --- Report whether the running coroutine can yield at this point.
   isyieldable: function(): boolean
   --- Resume a coroutine, passing values to its function or yield. Returns a success flag followed by yielded results or an error object.
   resume: function(thread, any...): boolean, any...
   --- Return the current coroutine and, where supported, whether it is the main thread. Lua 5.1 may return nil on the main thread.
   --- @return The result values; check for nil where indicated in the signature.
   running: function(): thread | nil, boolean | nil
   --- Return the coroutine state: running, suspended, normal, or dead.
   status: function(thread): string
   --- Create a function that resumes a coroutine and returns its results; errors propagate to the caller.
   wrap: function<F>(F): F
   --- Suspend the running coroutine and pass values to its resumer. Later resume arguments become the yield results.
   yield: function(any...): any...
end

--- Runtime debugging and introspection. Some operations bypass normal protection and may be unavailable in restricted hosts.
global record debug
   record GetInfoTable
      name: string
      namewhat: string
      source: string
      short_src: string
      linedefined: integer
      lastlinedefined: integer
      what: string
      currentline: integer
      istailcall: boolean
      nups: integer
      nparams: integer
      isvararg: boolean
      func: any
      activelines: {integer:boolean}
      ftransfer: integer -- TODO: what should compat be for these? (5.4+)
      ntransfer: integer
   end

   enum HookEvent
      "call" "tail call" "return" "line" "count"
   end

   type HookFunction = function(HookEvent, integer)

   type AnyFunction = function(any...):any...

   --- Enter an interactive debug prompt; availability and interaction depend on the host.
   debug: function()
   --- Return the hook function, event mask and instruction count, or nil when no hook is installed.
   --- @return The result values; check for nil where indicated in the signature.
   gethook: function(? thread): HookFunction | nil, string | nil, integer | nil

   --- Inspect a function or stack level. The optional selector chooses which fields are populated; returns nil for an invalid level.
   --- @return The result values; check for nil where indicated in the signature.
   getinfo: function(thread, AnyFunction | integer, ? string): GetInfoTable | nil
   --- Inspect a function or stack level. The optional selector chooses which fields are populated; returns nil for an invalid level.
   --- @return The result values; check for nil where indicated in the signature.
   getinfo: function(        AnyFunction | integer, ? string): GetInfoTable | nil

   --- Inspect a local variable or parameter by index. Returns its name and, for a stack frame, its value; returns nil when absent.
   --- @return The result values; check for nil where indicated in the signature.
   getlocal: function(thread, AnyFunction, integer): string | nil
   --- Inspect a local variable or parameter by index. Returns its name and, for a stack frame, its value; returns nil when absent.
   --- @return The result values; check for nil where indicated in the signature.
   getlocal: function(thread, integer, integer): string | nil, any
   --- Inspect a local variable or parameter by index. Returns its name and, for a stack frame, its value; returns nil when absent.
   --- @return The result values; check for nil where indicated in the signature.
   getlocal: function(AnyFunction, integer): string | nil
   --- Inspect a local variable or parameter by index. Returns its name and, for a stack frame, its value; returns nil when absent.
   --- @return The result values; check for nil where indicated in the signature.
   getlocal: function(integer, integer): string | nil, any

   --- Return the actual metatable, bypassing protection, or nil when none is set.
   --- @return The result values; check for nil where indicated in the signature.
   getmetatable: function<T>(T): metatable<T> | nil
   --- Return the Lua registry, a table used by the C API and runtime.
   getregistry: function(): {any:any}
   --- Return an upvalue name and value, or nil if the index is out of range.
   --- @return The result values; check for nil where indicated in the signature.
   getupvalue: function(AnyFunction, integer): string | nil, any
   --- Inspect a userdata user value; the optional index and success result depend on the Lua version.
   getuservalue: function(userdata, ? integer): any, boolean

   --- Install a debug hook for selected events and an optional instruction count.
   sethook: function(thread, HookFunction, string, ? integer)
   --- Install a debug hook for selected events and an optional instruction count.
   sethook: function(HookFunction, string, ? integer)

   --- Assign a local at a stack level and return its name, or nil if no such local exists.
   --- @return The result values; check for nil where indicated in the signature.
   setlocal: function(thread, integer, integer, any): string | nil
   --- Assign a local at a stack level and return its name, or nil if no such local exists.
   --- @return The result values; check for nil where indicated in the signature.
   setlocal: function(integer, integer, any): string | nil

   --- Set the actual metatable of a value and return that value; bypasses normal metatable protection.
   setmetatable: function<T>(T, metatable<T> | nil): T
   --- Assign an upvalue and return its name, or nil if the index is invalid.
   --- @return The result values; check for nil where indicated in the signature.
   setupvalue: function(AnyFunction, integer, any): string | nil
   --- Set a userdata user value; indexed user values depend on the runtime version.
   setuservalue: function<U>(U, any, integer): U --[[U is userdata]]

   --- Build a stack traceback from an optional message, thread and starting level. Non-string messages may pass through unchanged.
   traceback: function(thread, ? string, ? integer): string
   --- Build a stack traceback from an optional message, thread and starting level. Non-string messages may pass through unchanged.
   traceback: function(? string, ? integer): string
   --- Build a stack traceback from an optional message, thread and starting level. Non-string messages may pass through unchanged.
   traceback: function(any): any

   --- Return an identity token for a closure upvalue, allowing shared upvalues to be compared.
   upvalueid: function(AnyFunction, integer): userdata
   --- Make one Lua closure upvalue refer to the same storage as another.
   upvaluejoin: function(AnyFunction, integer, AnyFunction, integer)
end

--- File and process streams. File operations can fail; check returned handles and error details.
global record io
   enum OpenMode
       "r"   "w"   "a"   "r+"   "w+"   "a+"
       "rb"  "wb"  "ab"  "r+b"  "w+b"  "a+b"
      "*r"  "*w"  "*a"  "*r+"  "*w+"  "*a+"
      "*rb" "*wb" "*ab" "*r+b" "*w+b" "*a+b"
   end

   enum FileType
      "file"
      "closed file"
   end

   --- Close a file, or the default output when omitted. Closing a standard stream may be restricted by the host.
   close: function(? FILE): boolean | nil, string | nil, integer | nil
   --- Get or set the default input stream; a filename opens the file for reading.
   input: function(? FILE | string): FILE
   --- Flush buffered data for the default output stream.
   flush: function(): boolean | nil, string | nil, integer | nil

   --- Iterate over lines or requested read formats. A named file is closed automatically when iteration reaches end of file.
   lines: function(? string): (function(): (string))
   --- Iterate over lines or requested read formats. A named file is closed automatically when iteration reaches end of file.
   lines: function(? string, FileNumberMode...): (function(): (number...))
   --- Iterate over lines or requested read formats. A named file is closed automatically when iteration reaches end of file.
   lines: function(? string, (number | FileStringMode)...): (function(): (string...))
   --- Iterate over lines or requested read formats. A named file is closed automatically when iteration reaches end of file.
   --- @return The result values; check for nil where indicated in the signature.
   lines: function(? string, (number | FileMode)...): (function(): ((string | number | nil)...))
   --- Iterate over lines or requested read formats. A named file is closed automatically when iteration reaches end of file.
   lines: function(? string, (number | string)...): (function(): (string...))

   --- Open a file with the selected mode (default `r`). On failure the handle is nil and an error message and system code may follow.
   ---
   --- @param filename Path to open; interpretation is host-specific.
   --- @param mode Optional mode: read (`r`), write/truncate (`w`), append (`a`), or an update/binary variant.
   --- @return A file handle on success; otherwise nil, an error message, and a system error code.
   --- ```teal
   --- local file, err = io.open("notes.txt", "r")
   --- if file ~= nil then
   ---    local line = file:read()
   ---    file:close()
   --- end
   --- ```
   open: function(string, ? OpenMode): FILE | nil, string | nil, integer | nil
   --- Get or set the default output stream; a filename opens the file for writing.
   output: function(? FILE | string): FILE
   --- Start a process and return a stream connected to it, or nil and an error message on failure. Host support varies.
   --- @return The result values; check for nil where indicated in the signature.
   popen: function(string, ? OpenMode): FILE | nil, string | nil

   --- Read from the default input using the requested formats. At end of file or on a failed conversion a result may be nil.
   ---
   --- @param formats Optional read formats such as `*l`, `*a`, `*n`, or a byte count.
   --- @return One result per requested format; a failed read produces nil.
   read: function(): string | nil
   --- Read from the default input using the requested formats. At end of file or on a failed conversion a result may be nil.
   ---
   --- @param formats Optional read formats such as `*l`, `*a`, `*n`, or a byte count.
   --- @return One result per requested format; a failed read produces nil.
   read: function(FileNumberMode...): ((number | nil)...)
   --- Read from the default input using the requested formats. At end of file or on a failed conversion a result may be nil.
   ---
   --- @param formats Optional read formats such as `*l`, `*a`, `*n`, or a byte count.
   --- @return One result per requested format; a failed read produces nil.
   read: function((number | FileStringMode)...): ((string | nil)...)
   --- Read from the default input using the requested formats. At end of file or on a failed conversion a result may be nil.
   ---
   --- @param formats Optional read formats such as `*l`, `*a`, `*n`, or a byte count.
   --- @return One result per requested format; a failed read produces nil.
   read: function((number | FileMode)...): ((string | number | nil)...)
   --- Read from the default input using the requested formats. At end of file or on a failed conversion a result may be nil.
   ---
   --- @param formats Optional read formats such as `*l`, `*a`, `*n`, or a byte count.
   --- @return One result per requested format; a failed read produces nil.
   read: function((number | string)...): ((string | nil)...)

   --- Standard error stream.
   stderr: FILE
   --- Standard input stream.
   stdin: FILE
   --- Standard output stream.
   stdout: FILE
   --- Create an anonymous temporary file. Returns nil and error details on failure; the file is removed when closed.
   --- @return The result values; check for nil where indicated in the signature.
   tmpfile: function(): FILE | nil, string | nil, integer | nil
   --- Return `file` or `closed file` for a file handle, otherwise nil.
   --- @return The result values; check for nil where indicated in the signature.
   type: function(any): FileType | nil
   --- Write strings or numbers to the default output. Returns the stream on success or nil and error details on failure.
   --- @return The result values; check for nil where indicated in the signature.
   write: function((string | number)...): FILE | nil, string | nil, integer | nil
end

--- An open file handle. Methods operate on the handle supplied as `self`.
global record FILE
   is userdata
   where io.type(self)

   enum SeekWhence
      "set" "cur" "end"
   end

   enum SetVBufMode
      "no" "full" "line"
   end

   --- Close this handle. Returns success, or nil with an error message and system code.
   --- @return The result values; check for nil where indicated in the signature.
   close: function(FILE): boolean | nil, string | nil, integer | nil
   --- Flush buffered output. Returns success, or nil with error details.
   --- @return The result values; check for nil where indicated in the signature.
   flush: function(FILE): boolean | nil, string | nil, integer | nil

   --- Iterate over this handle using the requested read formats. The iterator stops at end of file; it does not close the handle.
   lines: function(FILE): (function(): (string))
   --- Iterate over this handle using the requested read formats. The iterator stops at end of file; it does not close the handle.
   lines: function(FILE, FileNumberMode...): (function(): (number...))
   --- Iterate over this handle using the requested read formats. The iterator stops at end of file; it does not close the handle.
   lines: function(FILE, (number | FileStringMode)...): (function(): (string...))
   --- Iterate over this handle using the requested read formats. The iterator stops at end of file; it does not close the handle.
   --- @return The result values; check for nil where indicated in the signature.
   lines: function(FILE, (number | FileMode)...): (function(): ((string | number | nil)...))
   --- Iterate over this handle using the requested read formats. The iterator stops at end of file; it does not close the handle.
   lines: function(FILE, (number | string)...): (function(): (string...))

   --- Read using the supplied formats, defaulting to a line. A failed read or conversion returns nil at that result position.
   ---
   --- @param self Open file handle.
   --- @param formats Optional formats: line, all remaining text, number, or a byte count.
   --- @return Values in format order; test each result for nil when reading can fail.
   read: function(FILE): string | nil
   --- Read using the supplied formats, defaulting to a line. A failed read or conversion returns nil at that result position.
   ---
   --- @param self Open file handle.
   --- @param formats Optional formats: line, all remaining text, number, or a byte count.
   --- @return Values in format order; test each result for nil when reading can fail.
   read: function(FILE, FileNumberMode...): ((number | nil)...)
   --- Read using the supplied formats, defaulting to a line. A failed read or conversion returns nil at that result position.
   ---
   --- @param self Open file handle.
   --- @param formats Optional formats: line, all remaining text, number, or a byte count.
   --- @return Values in format order; test each result for nil when reading can fail.
   read: function(FILE, (number | FileStringMode)...): ((string | nil)...)
   --- Read using the supplied formats, defaulting to a line. A failed read or conversion returns nil at that result position.
   ---
   --- @param self Open file handle.
   --- @param formats Optional formats: line, all remaining text, number, or a byte count.
   --- @return Values in format order; test each result for nil when reading can fail.
   read: function(FILE, (number | FileMode)...): ((string | number | nil)...)
   --- Read using the supplied formats, defaulting to a line. A failed read or conversion returns nil at that result position.
   ---
   --- @param self Open file handle.
   --- @param formats Optional formats: line, all remaining text, number, or a byte count.
   --- @return Values in format order; test each result for nil when reading can fail.
   read: function(FILE, (number | string)...): ((string | nil)...)

   --- Move or query the file position using `set`, `cur`, or `end`; return the resulting byte offset or nil and error details.
   --- @return The result values; check for nil where indicated in the signature.
   seek: function(FILE, ? SeekWhence, ? integer): integer | nil, string | nil, integer | nil
   --- Choose no, full, or line buffering and optionally a buffer size. Returns success or nil and error details.
   --- @return The result values; check for nil where indicated in the signature.
   setvbuf: function(FILE, SetVBufMode, ? integer): boolean | nil, string | nil, integer | nil

   --- Write strings or numbers to this handle. Returns the handle on success or nil and error details on failure.
   --- @return The result values; check for nil where indicated in the signature.
   write: function(FILE, (string | number)...): FILE | nil, string | nil, integer | nil

   metamethod __close: function(FILE)
end

--- Numeric functions and constants. Angles are in radians unless explicitly stated.
global record math
   type Numeric = number | integer

   --- Return the absolute value, preserving the numeric type where possible.
   abs: function<N is Numeric>(N): N
   --- Return the arc cosine in radians.
   acos: function(number): number
   --- Return the arc sine in radians.
   asin: function(number): number
   --- Return the arc tangent in radians; an optional second argument selects the quadrant.
   atan: function(number, ? number): number
   --- Return the two-argument arc tangent in radians; runtime availability varies.
   atan2: function(number, number): number
   --- Round toward positive infinity.
   ceil: function(number): integer
   --- Return the cosine of an angle in radians.
   cos: function(number): number
   --- Return the hyperbolic cosine.
   cosh: function(number): number
   --- Convert radians to degrees.
   deg: function(number): number
   --- Return e raised to the supplied power.
   exp: function(number): number
   --- Round toward negative infinity.
   floor: function(number): integer

   --- Return the remainder after division with the quotient rounded toward zero.
   fmod: function(integer, integer): integer
   --- Return the remainder after division with the quotient rounded toward zero.
   fmod: function(number, number): number

   --- Split a number into a normalized fraction and an exponent in base two.
   frexp: function(number): number, integer
   --- Positive infinity.
   huge: number
   --- Multiply a fraction by two raised to an integer exponent.
   ldexp: function(number, integer): number
   --- Return a logarithm; the optional base defaults to e.
   log: function(number, ? number): number
   --- Return the base-ten logarithm.
   log10: function(number): number

   --- Return the greatest argument according to the applicable comparison.
   max: function(integer...): integer
   --- Return the greatest argument according to the applicable comparison.
   max: function((number | integer)...): number
   --- Return the greatest argument according to the applicable comparison.
   max: function<T>(T...): T
   --- Return the greatest argument according to the applicable comparison.
   max: function(any...): any

   --- Largest representable integer where supported.
   maxinteger: integer --[[needs_compat]]

   --- Return the least argument according to the applicable comparison.
   min: function(integer...): integer
   --- Return the least argument according to the applicable comparison.
   min: function((number | integer)...): number
   --- Return the least argument according to the applicable comparison.
   min: function<T>(T...): T
   --- Return the least argument according to the applicable comparison.
   min: function(any...): any

   --- Smallest representable integer where supported.
   mininteger: integer --[[needs_compat]]

   --- Split a number into its integral and fractional parts.
   modf: function(number): integer, number
   --- The mathematical constant pi.
   pi: number
   --- Raise the first argument to the second power.
   pow: function(number, number): number
   --- Convert degrees to radians.
   rad: function(number): number

   --- Generate a pseudorandom value. Without bounds return a fraction; with one or two integer bounds return an integer in the inclusive range.
   random: function(integer, ? integer): integer
   --- Generate a pseudorandom value. Without bounds return a fraction; with one or two integer bounds return an integer in the inclusive range.
   random: function(): number

   --- Initialize the pseudorandom generator. Seed handling and returned values vary by Lua version.
   randomseed: function(? integer, ? integer): integer, integer
   --- Return the sine of an angle in radians.
   sin: function(number): number
   --- Return the hyperbolic sine.
   sinh: function(number): number
   --- Return the square root.
   sqrt: function(number): number
   --- Return the tangent of an angle in radians.
   tan: function(number): number
   --- Return the hyperbolic tangent.
   tanh: function(number): number
   --- Convert an exactly representable value to an integer, or return nil if conversion fails.
   --- @return The result values; check for nil where indicated in the signature.
   tointeger: function(any): integer | nil
   --- Return the numeric representation (`integer` or `float`), or nil for a non-number.
   --- @return The result values; check for nil where indicated in the signature.
   type: function(any): string | nil
   --- Compare two integers as unsigned values.
   ult: function(number, number): boolean
end

--- Operating-system services. Availability and exact results depend on the host and Lua version.
global record os
   record DateTable
      year: integer
      month: integer
      day: integer
      hour: integer
      min: integer
      sec: integer
      wday: integer
      yday: integer
      isdst: boolean
   end

   enum DateMode
      "!*t" "*t"
   end

   --- Return approximate CPU time used by the program in seconds.
   clock: function(): number

   --- Format a time using a date format, or return a date table for `*t` and `!*t`. The `!` prefix selects UTC.
   date: function(DateMode, ? number): DateTable
   --- Format a time using a date format, or return a date table for `*t` and `!*t`. The `!` prefix selects UTC.
   date: function(? string, ? number): string

   --- Return the difference between two time values in seconds.
   difftime: function(integer, integer): number
   --- Pass a command to the operating system shell. Status results and their availability vary by runtime and platform.
   execute: function(string): boolean | nil, string | nil, integer | nil
   --- Terminate the host process with an optional status and optional close flag.
   exit: function(? (integer | boolean), ? boolean)
   --- Read an environment variable, returning nil when it is absent.
   ---
   --- @param name Environment variable name.
   --- @return Its string value, or nil if the name is absent.
   getenv: function(string): string | nil
   --- Remove a file or empty directory. Return success or nil, an error message and a system code.
   --- @return The result values; check for nil where indicated in the signature.
   remove: function(string): boolean | nil, string | nil, integer | nil
   --- Rename or move a file. Return success or nil, an error message and a system code.
   --- @return The result values; check for nil where indicated in the signature.
   rename: function(string, string): boolean | nil, string | nil, integer | nil
   --- Set or query the process locale for an optional category; return nil when the locale cannot be selected.
   --- @return The result values; check for nil where indicated in the signature.
   setlocale: function(string, ? string): string | nil
   --- Return the current time, or convert a date table to a time value in local time.
   time: function(? DateTable): integer
   --- Return a name suitable for a temporary file; platform-specific creation and cleanup rules apply.
   tmpname: function(): string
end

--- Module search paths, loaders and cache used by `require`.
global record package
   --- Runtime-specific directory and module path separator configuration.
   config: string
   --- Templates used to search for native modules.
   cpath: string
   --- Module cache consulted by require.
   loaded: {string:any}
   --- Load a named C symbol from a shared library. Return the function or nil with diagnostic information.
   --- @return The result values; check for nil where indicated in the signature.
   loadlib: function(string, string): function | nil, string | nil, string | nil
   --- Lua 5.1 module searchers.
   loaders: { (function(string): (function(? string, ? any): (any), any)) }
   --- Templates used to search for Lua modules.
   path: string
   --- Registered module loader functions.
   preload: {string : function(? string, ? any): (any) }
   --- Module searchers used by later Lua versions.
   searchers: { (function(string): (function(? string, ? any): (any), any)) }
   --- Search a path template for a module name. Return the filename or nil and a description of attempted paths.
   --- @return The result values; check for nil where indicated in the signature.
   searchpath: function(string, string, ? string, ? string): string | nil, string | nil
end

--- Byte-string operations and Lua pattern matching. Index positions are one-based.
global record string
   --- Return byte values from a string at the requested one-based position or inclusive range.
   byte: function(string, ? integer): integer | nil
   --- Return byte values from a string at the requested one-based position or inclusive range.
   byte: function(string, integer, ? integer): ((integer | nil)...)

   --- Build a string from byte values.
   char: function(integer...): string
   --- Serialize a Lua function to a binary chunk; the optional strip flag removes debug information where supported.
   dump: function(function(any...): (any), ? boolean): string
   --- Search for a pattern or plain substring. Return one-based start and end positions plus captures, or nil when no match exists.
   ---
   --- @param subject String to search, indexed in bytes.
   --- @param pattern Lua pattern, or a literal substring when `plain` is true.
   --- @param init Optional starting byte position; negative positions count from the end.
   --- @param plain Optional flag disabling pattern interpretation.
   --- @return Start and end byte positions followed by captures, or nil when absent.
   --- ```teal
   --- local first, last = string.find("red blue", "blue", 1, true)
   --- if first ~= nil and last ~= nil then print(first, last) end
   --- ```
   find: function(string, string, ? integer, ? boolean): integer | nil, integer | nil, string... --[[special_function]]
   --- Format arguments according to a printf-style format string.
   format: function(string, any...): string --[[special_function]]
   --- Create an iterator over successive pattern matches and their captures.
   gmatch: function(string, string, ? integer): (function(): string...) --[[special_function]]

   --- Replace pattern matches using a string, table, or callback. Return the new string and replacement count.
   gsub: function(string, string, string, ? integer): string, integer --[[special_function]]
   --- Replace pattern matches using a string, table, or callback. Return the new string and replacement count.
   gsub: function(string, string, {string:string|integer|number}, ? integer): string, integer --[[special_function]]
   --- Replace pattern matches using a string, table, or callback. Return the new string and replacement count.
   gsub: function(string, string, {integer:string|integer|number}, ? integer): string, integer --[[special_function]]
   --- Replace pattern matches using a string, table, or callback. Return the new string and replacement count.
   gsub: function(string, string, function((string|integer)...): ((string|integer|number)...), ? integer): string, integer --[[special_function]]

   --- Return the length in bytes, not Unicode characters.
   len: function(string): integer
   --- Return a lowercase copy according to the current locale.
   lower: function(string): string
   --- Return pattern captures, or the whole match if there are no captures; return nil if no match exists.
   ---
   --- @param subject String to search.
   --- @param pattern Lua pattern; parentheses define captures.
   --- @param init Optional starting byte position.
   --- @return Captures or the whole match; nil when no match is found.
   --- ```teal
   --- local word = string.match("key=oak", "=(%a+)")
   --- if word ~= nil then print(word) end
   --- ```
   match: function(string, string, ? integer): ((string | nil)...) --[[special_function]]
   --- Pack values into a binary string according to a format.
   pack: function(string, any...): string --[[special_function]]
   --- Return the fixed byte size of a binary packing format.
   packsize: function(string): integer
   --- Repeat a string a specified number of times, optionally separating copies.
   rep: function(string, integer, ? string): string
   --- Return a string with its bytes reversed.
   reverse: function(string): string
   --- Return the inclusive byte range; negative positions count backward from the end.
   sub: function(string, integer, ? integer): string
   --- Unpack binary values according to a format and return them followed by the next byte position.
   unpack: function(string, string, ? integer): any... --[[special_function]]
   --- Return an uppercase copy according to the current locale.
   upper: function(string): string
end

--- Sequence and table operations. Sequence functions generally expect consecutive integer keys.
global record table
   type SortFunction = function<A>(A, A): boolean

   record PackTable<A>
      is {A}

      n: integer
   end

   --- Join a sequence of strings or numbers, optionally choosing a separator and inclusive index range.
   concat: function({(string | number)}, ? string, ? integer, ? integer): string

   --- Insert a value at a position or at the end, shifting later elements up.
   insert: function<A>({A}, integer, A)
   --- Insert a value at a position or at the end, shifting later elements up.
   insert: function<A>({A}, A)

   --- Copy an inclusive index range into a destination table, handling overlapping ranges, and return the destination.
   move: function<A>({A}, integer, integer, integer, ? {A}): {A}

   --- Pack arguments into a table with an `n` field recording their count, including nil arguments.
   pack: function<T>(T...): PackTable<T> --[[needs_compat]]
   --- Pack arguments into a table with an `n` field recording their count, including nil arguments.
   pack: function(any...): PackTable<any> --[[needs_compat]]

   --- Remove and return an element, shifting following elements down; return nil when no element is removed.
   ---
   --- @param list Sequence to modify in place.
   --- @param position Optional one-based index; defaults to the last element.
   --- @return The removed value, or nil when there is no element to remove.
   remove: function<A>({A}, ? integer): A | nil
   --- Sort a sequence in place using an optional strict ordering callback. The sort is not stable.
   sort: function<A>({A}, ? SortFunction<A>)

   --- Return elements from an inclusive index range as separate results.
   unpack: function<A>({A}, ? number, ? number): A... --[[needs_compat]]
   --- Return elements from an inclusive index range as separate results.
   unpack: function<A1, A2>({A1, A2}): A1, A2 --[[needs_compat]]
   --- Return elements from an inclusive index range as separate results.
   unpack: function<A1, A2, A3>({A1, A2, A3}): A1, A2, A3 --[[needs_compat]]
   --- Return elements from an inclusive index range as separate results.
   unpack: function<A1, A2, A3, A4>({A1, A2, A3, A4}): A1, A2, A3, A4 --[[needs_compat]]
   --- Return elements from an inclusive index range as separate results.
   unpack: function<A1, A2, A3, A4, A5>({A1, A2, A3, A4, A5}): A1, A2, A3, A4, A5 --[[needs_compat]]
end

--- UTF-8 encoding, decoding and traversal. Positions are byte offsets.
global record utf8
   --- Encode Unicode code points as a UTF-8 string.
   char: function(number...): string
   --- Pattern matching one UTF-8 byte sequence; it does not validate a string.
   charpattern: string
   --- Decode code points in an inclusive byte range; invalid input raises an error unless supported lax mode is selected.
   codepoint: function(string, ? number, ? number, ? boolean): integer...
   --- Iterate over byte positions and code points in a UTF-8 string.
   codes: function(string, ? boolean): (function(string, ? integer): (integer, integer), string, integer)
   --- Count UTF-8 code points in a byte range; return nil and the first invalid byte position on invalid input.
   ---
   --- @param text UTF-8 byte string to inspect.
   --- @param first Optional first byte position.
   --- @param last Optional last byte position.
   --- @return Code-point count, or nil and the invalid byte position.
   len: function(string, ? number, ? number, ? boolean): integer | nil, integer | nil
   --- Find the byte position of a code point relative to a starting byte; return nil when it is outside the string.
   --- @return The result values; check for nil where indicated in the signature.
   offset: function(string, number, ? number): integer | nil
end

--- Core global functions and values exposed directly in the Lua environment.
local record StandardLibrary
   enum CollectGarbageCommand
      "collect"
      "count"
      "stop"
      "restart"
   end

   enum CollectGarbageSetValue
      "step"
      "setpause"
      "setstepmul"
   end

   enum CollectGarbageIsRunning
      "isrunning"
   end

   type LoadFunction = function(): string | nil

   enum LoadMode
      "b" "t" "bt"
   end

   type XpcallMsghFunction = function(any): any...

   --- Command-line arguments supplied by the host.
   arg: {string}
   --- Return the first argument when it is truthy; otherwise raise an error using the optional message.
   --- @return The result values; check for nil where indicated in the signature.
   assert: function<A, B>(A | nil, ? B, ...: any): A --[[special_function]]

   --- Control or query garbage collection using a command and optional numeric parameter. Supported commands vary by runtime.
   collectgarbage: function(? CollectGarbageCommand): number
   --- Control or query garbage collection using a command and optional numeric parameter. Supported commands vary by runtime.
   collectgarbage: function(CollectGarbageSetValue, integer): number
   --- Control or query garbage collection using a command and optional numeric parameter. Supported commands vary by runtime.
   collectgarbage: function(CollectGarbageIsRunning): boolean
   --- Control or query garbage collection using a command and optional numeric parameter. Supported commands vary by runtime.
   collectgarbage: function(string, ? number): (boolean | number)

   --- Load and execute a file, or standard input when omitted, returning the chunk results. Errors propagate.
   dofile: function(? string): any...

   --- Raise an error with an optional object and stack level; this function does not normally return.
   error: function(? any, ? integer)
   --- Return a value’s metatable, its protected `__metatable` value, or nil when no metatable exists.
   --- @return The result values; check for nil where indicated in the signature.
   getmetatable: function<T>(T): metatable<T> | nil
   --- Iterate consecutive integer keys starting at one until the first nil value.
   ipairs: function<A>({A}): (function({A}, integer): (integer, A), {A}, integer) --[[special_function]]

   --- Compile a chunk from a string or reader function. Return the function or nil and a syntax error message.
   ---
   --- @param chunk Source text or a reader returning successive pieces and nil at the end.
   --- @param chunkname Optional name used in diagnostics.
   --- @param mode Optional allowed chunk formats: text, binary, or both.
   --- @param env Optional environment for the compiled chunk where supported.
   --- @return Compiled function on success, otherwise nil and an error message.
   load: function((string | LoadFunction), ? string, ? LoadMode, ? {any:any}): (function | nil, string | nil)
   --- Compile a chunk from a string or reader function. Return the function or nil and a syntax error message.
   ---
   --- @param chunk Source text or a reader returning successive pieces and nil at the end.
   --- @param chunkname Optional name used in diagnostics.
   --- @param mode Optional allowed chunk formats: text, binary, or both.
   --- @param env Optional environment for the compiled chunk where supported.
   --- @return Compiled function on success, otherwise nil and an error message.
   load: function((string | LoadFunction), ? string, ? string,   ? {any:any}): (function | nil, string | nil)

   --- Compile a chunk from a file or standard input. Return the function or nil and an error message.
   --- @return The result values; check for nil where indicated in the signature.
   loadfile: function(? string, ? LoadMode, ? {any:any}): (function | nil, string | nil)
   --- Compile a chunk from a file or standard input. Return the function or nil and an error message.
   --- @return The result values; check for nil where indicated in the signature.
   loadfile: function(? string, ? string,   ? {any:any}): (function | nil, string | nil)

   --- Return the next key and value in unspecified order, or nil at the end of traversal.
   ---
   --- @param table Table to traverse.
   --- @param key Previous key, or nil to begin.
   --- @return The next key and its value, or nil when traversal is complete.
   next: function<K, V>({K:V}, ? K): (K | nil, V | nil)
   --- Return the next key and value in unspecified order, or nil at the end of traversal.
   ---
   --- @param table Table to traverse.
   --- @param key Previous key, or nil to begin.
   --- @return The next key and its value, or nil when traversal is complete.
   next: function<A>({A}, ? integer): (integer | nil, A | nil)

   --- Return an iterator, state and initial key for traversal. Order is unspecified and metamethod behavior depends on the runtime.
   pairs: function<K, V>({K:V}): (function({K:V}, ? K):(K, V), {K:V}, K) --[[special_function]]
   --- Call a function in protected mode. Return true and its results, or false and an error object.
   pcall: function(function(any...):(any...), any...): boolean, any... --[[special_function]]
   --- Convert arguments to text and write them to standard output, separated by tabs.
   print: function(any...)
   --- Compare values without invoking an equality metamethod.
   rawequal: function(any, any): boolean

   --- Read a table entry without invoking `__index`; return nil for an absent key.
   --- @return The result values; check for nil where indicated in the signature.
   rawget: function<K, V>({K:V}, K): V | nil --[[special_function]]
   --- Read a table entry without invoking `__index`; return nil for an absent key.
   rawget: function({any:any}, any): any
   --- Read a table entry without invoking `__index`; return nil for an absent key.
   rawget: function(any, any): any

   --- Return the raw length without invoking `__len`.
   rawlen: function<A>({A}): integer

   --- Write a table entry without invoking `__newindex`, and return the table. A nil value removes the key.
   rawset: function<K, V>({K:V}, K, V): {K:V}
   --- Write a table entry without invoking `__newindex`, and return the table. A nil value removes the key.
   rawset: function({any:any}, any, any): {any:any}
   --- Write a table entry without invoking `__newindex`, and return the table. A nil value removes the key.
   rawset: function(any, any, any): any

   --- Load a module by name, using the module cache and configured searchers. Errors propagate.
   require: function(string): any --[[special_function]]

   --- Return arguments from the specified index, or the argument count when the selector is `#`.
   select: function<T>(integer, T...): T...
   --- Return arguments from the specified index, or the argument count when the selector is `#`.
   select: function(integer, any...): any...
   --- Return arguments from the specified index, or the argument count when the selector is `#`.
   select: function(string, any...): integer

   --- Set a table metatable and return the table; a protected metatable prevents the change.
   setmetatable: function<T>(T, metatable<T> | nil): T

   --- Convert a value to a number, optionally parsing an integer in the given base. Return nil when conversion fails.
   ---
   --- @param value Value to convert; a string is interpreted as a numeric representation.
   --- @param base Optional integer base used when parsing a string.
   --- @return The converted number or nil if conversion fails.
   --- ```teal
   --- local value = tonumber("24")
   --- if value ~= nil then print(value + 1) end
   --- ```
   tonumber: function(any): number | nil
   --- Convert a value to a number, optionally parsing an integer in the given base. Return nil when conversion fails.
   ---
   --- @param value Value to convert; a string is interpreted as a numeric representation.
   --- @param base Optional integer base used when parsing a string.
   --- @return The converted number or nil if conversion fails.
   --- ```teal
   --- local value = tonumber("24")
   --- if value ~= nil then print(value + 1) end
   --- ```
   tonumber: function(any, integer): integer | nil

   --- Convert a value to a string, honoring its `__tostring` metamethod.
   tostring: function(any): string
   --- Return the Lua type name of a value.
   type: function(any): string
   --- Emit a warning message when the runtime supports warnings.
   warn: function(string, string...)
   --- Call a function in protected mode with an error handler. Return a success flag and results or the handled error.
   xpcall: function(function(any...):(any...), XpcallMsghFunction, any...): boolean, any... --[[special_function]]
   --- Runtime version string.
   _VERSION: string
end

global arg <const> = StandardLibrary.arg
global assert <const> = StandardLibrary.assert
global collectgarbage <const> = StandardLibrary.collectgarbage
global dofile <const> = StandardLibrary.dofile
global error <const> = StandardLibrary.error
global getmetatable <const> = StandardLibrary.getmetatable
global load <const> = StandardLibrary.load
global loadfile <const> = StandardLibrary.loadfile
global next <const> = StandardLibrary.next
global pairs <const> = StandardLibrary.pairs
global pcall <const> = StandardLibrary.pcall
global print <const> = StandardLibrary.print
global rawequal <const> = StandardLibrary.rawequal
global rawget <const> = StandardLibrary.rawget
global rawlen <const> = StandardLibrary.rawlen
global rawset <const> = StandardLibrary.rawset
global require <const> = StandardLibrary.require
global select <const> = StandardLibrary.select
global setmetatable <const> = StandardLibrary.setmetatable
global tostring <const> = StandardLibrary.tostring
global tonumber <const> = StandardLibrary.tonumber
global ipairs <const> = StandardLibrary.ipairs
global type <const> = StandardLibrary.type
global xpcall <const> = StandardLibrary.xpcall
global _VERSION <const> = StandardLibrary._VERSION
