# Runtime components

`QuickBEAM.Application` starts the OTP support services. Each runtime owns native QuickJS state through NIF resources; Elixir provides the public runtime API and HTTP/WebSocket/event-source integration. Native sources include Zig NIF glue, QuickJS, the Lexbor DOM bridge, and WAMR WebAssembly support. Original upstream notices remain in the vendored resources.

The package contains its native sources and headers under `lib` and `priv/c_src`, and internal JavaScript/TypeScript modules under `priv/ts`. Released packages download the matching B artifact from the bundler repository. `DUSKMOON_NATIVE_MODE=source` compiles development sources, while `precompiled` rejects force-build conflicts and requires checksum-verified artifacts. Historical released packages keep their original URLs in the UI repository.
