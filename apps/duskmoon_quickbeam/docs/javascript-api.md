# JavaScript runtime API

Create an isolated runtime with `QuickBEAM.start/1`, evaluate JavaScript with `QuickBEAM.eval/3`, and stop it with `QuickBEAM.stop/1`.

```elixir
{:ok, runtime} = QuickBEAM.start()
{:ok, 42} = QuickBEAM.eval(runtime, "21 * 2")
QuickBEAM.stop(runtime)
```

The public runtime supports module loading, compiled bytecode, function calls, globals, DOM operations and Web APIs backed by OTP. See the module documentation for options and return values. Source development must compile the same vendored QuickJS/native sources as the Elixir wrappers; released consumers load the versioned precompiled NIF and verify its checksum.

## Isolated BEAM execution

Use `QuickBEAM.VM` when each evaluation should own fresh JavaScript state:

```elixir
{:ok, program} = QuickBEAM.VM.compile("function add(a, b) { return a + b; }")
{:ok, 42} = QuickBEAM.VM.call(program, "add", [20, 22], max_steps: 10_000)
```

`compile/2` returns an immutable verified program; `decode/2` accepts bytecode from the exact same vendored QuickJS build. `eval/2` evaluates a program, while `call/4` initializes it and invokes a named global. The `measure/2` and `measure_call/4` variants also return deterministic execution measurements.

Pass `:handlers` for asynchronous `Beam.call` operations, `:vars` for initial globals and `:profile` (`:core` or `:ssr`) for the builtin surface. The options `:max_steps`, `:max_stack_depth`, `:memory_limit` and `:timeout` bound each evaluation. The memory limit counts logical VM allocation; measurement APIs report BEAM process memory separately. Browser, Node.js, DOM, WASM and native-addon APIs remain part of the native runtime.

Pin programs that a supervised application shares across requests, and unpin them when that lifecycle owner replaces or retires the program:

```elixir
{:ok, pinned} = QuickBEAM.VM.pin(program)

try do
  QuickBEAM.VM.call(pinned, "add", [20, 22], timeout: 1_000)
after
  QuickBEAM.VM.unpin(pinned)
end
```

Pinned storage is bounded and has no implicit eviction. Recompile programs after an incompatible QuickJS bytecode or ABI upgrade. See `QuickBEAM.VM` for supported semantics, limits and error tuples.

## Native runtime additions

`Intl.Segmenter` provides grapheme segmentation through the vendored `unicode-segmenter` implementation and is included in browser APIs or the `:intl` group. Native `WebAssembly.instantiate` calls use configurable `:wasm_stack_size` and `:wasm_heap_size` options on runtimes and context pools.

`QuickBEAM.load_addon/3` caches exports for repeated loads in one runtime. Loading the same canonical addon path in another runtime, or after reset, returns `{:error, {:addon_already_initialized, path}}` unless the caller explicitly selects `allow_reinitialization: true` for an addon that supports multiple environments.
