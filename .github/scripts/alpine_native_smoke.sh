#!/bin/sh
set -eu

version=${1:?usage: alpine_native_smoke.sh B}
case "$version" in
  *[!0-9.]*|'') echo "Expected a stable numeric release version" >&2; exit 2 ;;
esac

# A fresh consumer must use published precompiled NIFs, without build tools or
# source-build/target overrides. Run inside the official Alpine Elixir image.
for tool in cargo rustc zig; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "Unexpected source-build tool: $tool" >&2
    exit 1
  fi
done
for variable in DUSKMOON_BUILD_NATIVE_FROM_SOURCE OXC_EX_BUILD OXC_FMT_BUILD OXC_LINT_BUILD OXIDE_EX_BUILD VIZE_EX_BUILD QUICKBEAM_BUILD TARGET_ARCH TARGET_OS TARGET_ABI; do
  if printenv "$variable" >/dev/null 2>&1; then
    echo "Unexpected native override: $variable" >&2
    exit 1
  fi
done

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates
fi

consumer_dir=$(mktemp -d)
trap 'rm -rf "$consumer_dir"' EXIT
cd "$consumer_dir"
export MIX_ENV=prod
export DUSKMOON_NATIVE_MODE=precompiled
mix local.hex --force
mix local.rebar --force
cat > mix.exs <<EOF
defmodule AlpineNativeSmoke.MixProject do
  use Mix.Project
  def project do
    [app: :alpine_native_smoke, version: "0.1.0", elixir: ">= 1.18.0",
     deps: [
       {:duskmoon_bundler, "== $version"},
       {:duskmoon_bundler_runtime, "== $version"},
       {:duskmoon_oxc, "== $version"}, {:duskmoon_oxide, "== $version"},
       {:duskmoon_vize, "== $version"}, {:duskmoon_quickbeam, "== $version"},
       {:duskmoon_npm, "== $version"}, {:duskmoon_hex_solver, "== $version"}]]
  end
  def application, do: [extra_applications: [:logger]]
end
EOF
mix deps.get
mix deps.compile
mix run /validation/alpine_native_smoke.exs
