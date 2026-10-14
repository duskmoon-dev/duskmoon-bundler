# Run by npm_bootstrap_test.exs in a fresh VM. Bound failures before HTTP retries.
spawn(fn ->
  Process.sleep(20_000)
  System.halt(99)
end)

Mix.start()

case System.argv() do
  ["https", dir, cert, registry, integrity] ->
    {:ok, _} = Application.ensure_all_started(:http_fetch)
    false = :code.is_loaded(:public_key)
    paths = :code.get_path()

    Mix.Project.in_project(:bootstrap_proof, dir, fn _ ->
      Mix.Task.run("deps.compile", ["bootstrap_dep"])
      false = :code.is_loaded(:public_key)

      # Older Mix versions prune OTP paths here; newer versions may preserve them.
      # Keep only restored project/dependency paths, leaving OTP paths as compiled.
      library_paths = Enum.reject(paths, &List.starts_with?(&1, :code.lib_dir()))
      Code.prepend_paths(library_paths)
      {:ok, []} = Application.ensure_all_started(:ssl)

      if Version.match?(System.version(), "~> 1.18.0") do
        :non_existing = :code.where_is_file(~c"public_key.beam")
      end

      Application.put_env(:public_key, :cacerts_path, cert)
      System.put_env("NPM_REGISTRY", registry)
      System.put_env("NPM_EX_CACHE_DIR", Path.join(dir, "cold-cache"))
      false = File.exists?(NPM.Config.cache_dir())

      # Exercise a metadata task and strict installation, both through HTTPS.
      Mix.Tasks.Npm.View.run(["bootstrap-package", "versions"])

      {:ok, %{name: "bootstrap-package", versions: %{"1.0.0" => _}}} =
        NPM.PackumentCache.get("bootstrap-package")

      File.write!(
        "package.json",
        ~s({"name":"bootstrap-proof","dependencies":{"bootstrap-package":"1.0.0"}})
      )

      :ok =
        NPM.Lockfile.write(%{
          "bootstrap-package" => %{
            version: "1.0.0",
            integrity: integrity,
            tarball: registry <> "/bootstrap-package.tgz",
            dependencies: %{},
            optional_dependencies: %{},
            has_install_script: false
          }
        })

      :ok = Mix.Tasks.Npm.Ci.run([])
      IO.puts("bootstrap regression passed")
    end)

  ["startup_failure", dir] ->
    defmodule BootstrapFailure do
      def start(_type, _args), do: {:error, :bootstrap_test_failure}
    end

    :ok =
      :application.load(
        {:application, :http_fetch,
         [
           vsn: ~c"0",
           description: ~c"bootstrap failure",
           modules: [BootstrapFailure],
           registered: [],
           applications: [:kernel, :stdlib],
           mod: {BootstrapFailure, []}
         ]}
      )

    File.cd!(dir)

    try do
      Mix.Tasks.Npm.Ci.run([])
      raise "expected immediate bootstrap failure"
    rescue
      error in Mix.Error ->
        true = String.contains?(error.message, "npm bootstrap failed: cannot start http_fetch")
        true = String.contains?(error.message, "bootstrap_test_failure")
        IO.puts("bootstrap startup failure passed")
    end
end
