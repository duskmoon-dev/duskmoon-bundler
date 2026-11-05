# Runtime components

`QuickBEAM.Application` starts the OTP support services. Each runtime owns native QuickJS state through NIF resources; Elixir provides the public runtime API and HTTP/WebSocket/event-source integration. Native sources include Zig NIF glue, QuickJS, the Lexbor DOM bridge, and WAMR WebAssembly support. Original upstream notices remain in the vendored resources.

The package contains its native sources and headers under `lib` and `priv/c_src`, and internal JavaScript/TypeScript modules under `priv/ts`. Released packages download the matching B artifact from the bundler repository. `DUSKMOON_NATIVE_MODE=source` compiles development sources, while `precompiled` rejects force-build conflicts and requires checksum-verified artifacts. Historical released packages keep their original URLs in the UI repository.

## Isolated BEAM VM

`QuickBEAM.VM` compiles JavaScript through a short-lived native QuickJS runtime, then decodes and verifies the resulting bytecode before interpreting it on the BEAM. Programs carry the vendored QuickJS bytecode version and an ABI fingerprint derived from the packaged headers; recompile programs after an incompatible native upgrade.

Each `eval/2` or `call/4` owns a fresh JavaScript heap, globals, jobs and handlers. `call/4` initializes the program before invoking its named global. Mutable state is never shared across evaluations. The fixed `:core` and `:ssr` builtin profiles implement a bounded JavaScript subset and return explicit errors for unsupported behavior.

`QuickBEAM.Application` supervises `QuickBEAM.VM.Program.Store` and `QuickBEAM.VM.TaskSupervisor` alongside the native runtime and HTTP support services. Explicit `pin/1` and `unpin/1` calls let a supervised lifecycle owner share immutable programs through lightweight handles. The store uses fixed slots and residency limits, monitored evaluation leases and restart restoration; it has no implicit eviction or native execution fallback.

Evaluation options bound steps, stack depth, timeout and deterministic logical VM allocation. Measurement APIs report logical VM allocation separately from BEAM process memory. Async handlers run under the VM task supervisor, with at most 64 operations outstanding per evaluation. The internal BEAM compiler remains a conformance and benchmark tier; the public VM API executes through the interpreter.

The optional SSR test fixtures resolve JavaScript dependencies from this application's own `node_modules`. Install the app-local Bun lockfile before running those tests; other repositories and umbrella-root dependencies are not test inputs.
