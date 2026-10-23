# Duskmoon Bundler contributor instructions

Work in the current checkout unless a branch/worktree is explicitly requested. Preserve unrelated concurrent changes and stage only reviewed scope. Use Bun for JavaScript dependencies and standard Mix/ExUnit conventions. Run `mix format`, `mix compile --warnings-as-errors` and relevant tests before commits. Native development/CI sets `DUSKMOON_NATIVE_MODE=source`; strict consumers set `precompiled`. Never use UI repository paths, caches or root node_modules implicitly.

Maintain all nine toolchain package versions as one B cohort. UI version U belongs to the separate `phoenix-duskmoon-ui` repository. Stage packages outside the checkout; never mutate source Mix manifests to publish. Preserve native target/NIF ABI sets, portable CPU flags, vendored licenses and historical native artifacts.
