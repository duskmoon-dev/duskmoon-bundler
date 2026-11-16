defmodule OXC.Lint.TypeAwareTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    for app <- [:duskmoon_oxc, :oxc] do
      previous = Application.get_env(app, :tsgolint)

      on_exit(fn ->
        if previous,
          do: Application.put_env(app, :tsgolint, previous),
          else: Application.delete_env(app, :tsgolint)
      end)

      Application.delete_env(app, :tsgolint)
    end

    {:ok, fake: fake_tsgolint(tmp_dir, "exit 0")}
  end

  test "reads the tsgolint executable from the :duskmoon_oxc application environment", %{
    fake: fake
  } do
    Application.put_env(:duskmoon_oxc, :tsgolint, executable: fake)

    assert {:ok, []} = OXC.Lint.run(["entry.ts"], type_aware: true)
  end

  test "falls back to the legacy :oxc application environment", %{fake: fake} do
    Application.put_env(:oxc, :tsgolint, executable: fake)

    assert {:ok, []} = OXC.Lint.run(["entry.ts"], type_aware: true)
  end

  test "prefers :duskmoon_oxc over the legacy :oxc application environment", %{
    fake: fake,
    tmp_dir: tmp_dir
  } do
    Application.put_env(:duskmoon_oxc, :tsgolint, executable: fake)
    Application.put_env(:oxc, :tsgolint, executable: Path.join(tmp_dir, "missing-tsgolint"))

    assert {:ok, []} = OXC.Lint.run(["entry.ts"], type_aware: true)
  end

  test "keeps the payload in a private per-run directory and removes it", %{tmp_dir: tmp_dir} do
    scratch = Path.join(tmp_dir, "scratch")
    listing = Path.join(tmp_dir, "listing")
    File.mkdir_p!(scratch)

    fake =
      fake_tsgolint(tmp_dir, """
      for entry in "$TMPDIR"/*; do ls -ld "$entry"; done > "$OXC_TEST_LISTING"
      cat > "$OXC_TEST_LISTING.payload"
      """)

    previous_tmpdir = System.get_env("TMPDIR")
    System.put_env("TMPDIR", scratch)
    System.put_env("OXC_TEST_LISTING", listing)

    on_exit(fn ->
      if previous_tmpdir,
        do: System.put_env("TMPDIR", previous_tmpdir),
        else: System.delete_env("TMPDIR")

      System.delete_env("OXC_TEST_LISTING")
    end)

    assert {:ok, []} = OXC.Lint.run(["entry.ts"], type_aware: true, tsgolint: fake)

    assert [entry] = listing |> File.read!() |> String.split("\n", trim: true)
    assert String.starts_with?(entry, "drwx------")
    assert %{"version" => 2} = Jason.decode!(File.read!(listing <> ".payload"))
    assert File.ls!(scratch) == []
  end

  test "returns type-aware diagnostics as structs with the configured severity", %{
    tmp_dir: tmp_dir
  } do
    payload =
      Jason.encode!(%{
        "rule" => "no-floating-promises",
        "file_path" => "/project/entry.ts",
        "range" => %{"pos" => 3, "end" => 9},
        "message" => %{"description" => "Promises must be awaited.", "help" => "Add await."},
        "fixes" => [%{"text" => "await ", "range" => %{"pos" => 3, "end" => 3}}]
      })

    frames = Path.join(tmp_dir, "frames")
    File.write!(frames, <<byte_size(payload)::little-32, 1, payload::binary>>)
    fake = fake_tsgolint(tmp_dir, ~s(cat "#{frames}"))

    assert {:ok, [diagnostic]} =
             OXC.Lint.run(["entry.ts"],
               type_aware: true,
               tsgolint: fake,
               rules: %{"typescript/no-floating-promises" => :deny}
             )

    assert %OXC.Lint.TypeAware.Diagnostic{
             rule: "typescript/no-floating-promises",
             severity: :deny,
             file: "/project/entry.ts",
             span: {3, 9},
             message: "Promises must be awaited.",
             help: "Add await.",
             fixes: [%{"text" => "await "}]
           } = diagnostic
  end

  defp fake_tsgolint(tmp_dir, body) do
    path = Path.join(tmp_dir, "fake-tsgolint-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end
end
