-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "runtime-analysis",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "h",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "lib.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  -- Here "file": the :RA* commands, autocmds, buffers and highlight groups that setup() and the
  -- views leave behind must not leak into the next file (this keeps the state guard clean without
  -- an allowlist), and the plugin's cache writes land in the child's own sandbox.
  isolated = "file",
  -- Environment variables the specs read; a child editor inherits an allowlist only (never secrets).
  env_allow = { "MAGICK_*" },
  -- Guards (safety nets, see testing.nvim docs/GUARDS.md): the suite passes all of them cleanly.
  guards = {
    fs = "error",
    state = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "error",
  },
  -- What the specs start on purpose.
  guard_allow = {
    spawn = {
      -- The plugin's own HTTP runner shells out to curl; the specs aim it at 127.0.0.1 servers they start.
      "curl",
      -- startup_profile_spec measures `nvim --clean --startuptime` of a real child editor.
      "nvim",
      -- setup_all_spec removes its own temp directory via os.execute("rm -rf ...").
      "rm",
    },
  },
}
