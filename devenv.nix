{ pkgs, lib, config, inputs, ... }:
let pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in {
  env.DUSKMOON_NATIVE_MODE = "source";
  packages = with pkgs-stable; [ git tailwindcss_4 zig_0_15 cargo rustc clang pkg-config ]
    ++ lib.optionals stdenv.isLinux [ inotify-tools ];
  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;
  languages.javascript.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;
}
