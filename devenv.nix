{ pkgs, lib, config, inputs, ... }:
let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
  pkgs-rust = import inputs.nixpkgs-rust { system = pkgs.stdenv.system; };
  zig = pkgs-rust.zig_0_17.override {
    version = "0.17.1";
    hash = "sha256-oC6L2B6kpxqLMZTOA7iScA3UrYF+T7t09ryfPeSwY5M=";
  };
in {
  env.DUSKMOON_NATIVE_MODE = "source";
  # Zigler accepts an explicit patch toolchain through this variable.
  env.ZIG_EXECUTABLE_PATH = "${zig}/bin/zig";
  packages = with pkgs-stable; [ git tailwindcss_4 clang pkg-config ]
    # Vize and QuickBEAM require newer Rust and Zig than the stable baseline.
    ++ [ pkgs-rust.cargo pkgs-rust.rustc zig ]
    ++ lib.optionals stdenv.isLinux [ inotify-tools ];
  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;
  languages.javascript.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;
}
