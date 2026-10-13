# JavaScript runtime API

Create an isolated runtime with `QuickBEAM.start/1`, evaluate JavaScript with `QuickBEAM.eval/3`, and stop it with `QuickBEAM.stop/1`.

```elixir
{:ok, runtime} = QuickBEAM.start()
{:ok, 42} = QuickBEAM.eval(runtime, "21 * 2")
QuickBEAM.stop(runtime)
```

The public runtime supports module loading, compiled bytecode, function calls, globals, DOM operations and Web APIs backed by OTP. See the module documentation for options and return values. Source development must compile the same vendored QuickJS/native sources as the Elixir wrappers; released consumers load the versioned precompiled NIF and verify its checksum.
