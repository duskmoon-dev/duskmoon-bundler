defmodule Mix.Tasks.Npm.BootstrapTest do
  use ExUnit.Case, async: true

  defmodule Registry do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(conn, {owner, archive}) do
      send(owner, {:https_request, conn.request_path})

      case conn.request_path do
        "/bootstrap-package" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, ~s({"name":"bootstrap-package","versions":{"1.0.0":{}}}))

        "/bootstrap-package.tgz" ->
          send_resp(conn, 200, archive)
      end
    end
  end

  @tag :tmp_dir
  test "compilation followed by npm tasks restores lazy OTP modules for cold-cache HTTPS", %{
    tmp_dir: dir
  } do
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    ca = Path.join(dir, "ca.pem")
    ca_key = Path.join(dir, "ca-key.pem")
    csr = Path.join(dir, "server.csr")
    extensions = Path.join(dir, "server.ext")
    File.write!(extensions, "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\n")

    openssl!([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=Bootstrap Test CA",
      "-keyout",
      ca_key,
      "-out",
      ca
    ])

    openssl!([
      "req",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      "/CN=localhost",
      "-keyout",
      key,
      "-out",
      csr
    ])

    openssl!([
      "x509",
      "-req",
      "-in",
      csr,
      "-CA",
      ca,
      "-CAkey",
      ca_key,
      "-CAcreateserial",
      "-days",
      "1",
      "-extfile",
      extensions,
      "-out",
      cert
    ])

    archive_path = Path.join(dir, "package.tgz")
    manifest = ~s({"name":"bootstrap-package","version":"1.0.0"})

    :ok =
      :erl_tar.create(String.to_charlist(archive_path), [{~c"package/package.json", manifest}], [
        :compressed
      ])

    archive = File.read!(archive_path)

    server =
      start_supervised!(
        {Bandit,
         plug: {Registry, {self(), archive}},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         certfile: cert,
         keyfile: key}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    registry = "https://localhost:#{port}"
    integrity = "sha512-" <> Base.encode64(:crypto.hash(:sha512, archive))
    write_compilation_project!(dir)

    {output, status} = run_proof(["https", dir, ca, registry, integrity])
    assert status == 0, output
    assert output =~ "bootstrap regression passed"
    assert_received {:https_request, "/bootstrap-package"}
    assert_received {:https_request, "/bootstrap-package.tgz"}
    assert File.read!(Path.join(dir, "node_modules/bootstrap-package/package.json")) == manifest
  end

  @tag :tmp_dir
  test "npm.ci fails before installation when the HTTP application cannot start", %{tmp_dir: dir} do
    {output, status} = run_proof(["startup_failure", dir])
    assert status == 0, output
    assert output =~ "bootstrap startup failure passed"
    refute File.exists?(Path.join(dir, "node_modules"))
  end

  defp openssl!(args) do
    {output, status} = System.cmd("openssl", args, stderr_to_stdout: true)
    assert status == 0, output
  end

  defp run_proof(args) do
    script = Path.expand("../../fixtures/npm_bootstrap_proof.exs", __DIR__)
    build_paths = Path.join(Mix.Project.build_path(), "lib/*/ebin")

    System.cmd(
      System.find_executable("elixir"),
      ["--erl", "+S 2:2", "-pa", build_paths, script | args],
      stderr_to_stdout: true,
      env: [
        {"MIX_BUILD_PATH", nil},
        {"MIX_ENV", "test"},
        {"NPM_TOKEN", nil},
        {"NPM_EX_ALLOWED_REGISTRIES", nil},
        {"NPM_EX_LINK_STRATEGY", nil}
      ]
    )
  end

  defp write_compilation_project!(dir) do
    File.mkdir_p!(Path.join(dir, "dep/lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule BootstrapProof.MixProject do
      use Mix.Project
      def project, do: [app: :bootstrap_proof, version: "1.0.0", deps: [{:bootstrap_dep, path: "dep"}]]
    end
    """)

    File.write!(Path.join(dir, "dep/mix.exs"), """
    defmodule BootstrapDep.MixProject do
      use Mix.Project
      def project, do: [app: :bootstrap_dep, version: "1.0.0"]
    end
    """)

    File.write!(Path.join(dir, "dep/lib/bootstrap_dep.ex"), "defmodule BootstrapDep do\nend\n")
  end
end
