--#pragma strict_nil off
local record model
   type Object = {string:any}
   record Case
      source: string
      profile: string
      expected: number
      seed: integer
      index: integer
   end
   record Config
      root: string
      here: string
      lua: string
      target: string
      timeout: number
      memory_mb: integer
      reference_root: string
      compiler_revision: string
   end
   record Result
      status: string
      stage: string
      message: string
      disposition: string
      tokens: integer
      generated_bytes: integer
      executed: integer
      syntax_errors: integer
      type_errors: integer
      seconds: number
      stdout: string
      stderr: string
      reference: Result
      candidate: Result
   end
end
return model
