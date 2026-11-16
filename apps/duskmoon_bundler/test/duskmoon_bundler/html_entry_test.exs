defmodule DuskmoonBundler.HTMLEntryTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("fixtures/html_entry", __DIR__)

  setup do
    File.mkdir_p!(@fixture_dir)
    on_exit(fn -> File.rm_rf!(@fixture_dir) end)
    :ok
  end

  describe "extract/1" do
    test "extracts script src" do
      File.write!(Path.join(@fixture_dir, "index.html"), """
      <html>
        <body>
          <script type="module" src="js/app.ts"></script>
        </body>
      </html>
      """)

      {:ok, entries} = DuskmoonBundler.HTMLEntry.extract(Path.join(@fixture_dir, "index.html"))
      assert length(entries.scripts) == 1
      assert hd(entries.scripts) =~ "js/app.ts"
    end

    test "extracts stylesheet href" do
      File.write!(Path.join(@fixture_dir, "index.html"), """
      <html>
        <head>
          <link rel="stylesheet" href="css/app.css">
        </head>
      </html>
      """)

      {:ok, entries} = DuskmoonBundler.HTMLEntry.extract(Path.join(@fixture_dir, "index.html"))
      assert length(entries.styles) == 1
      assert hd(entries.styles) =~ "css/app.css"
    end

    test "extracts multiple entries" do
      File.write!(Path.join(@fixture_dir, "index.html"), """
      <html>
        <head>
          <link rel="stylesheet" href="css/app.css">
          <link rel="stylesheet" href="css/vendor.css">
        </head>
        <body>
          <script type="module" src="js/app.ts"></script>
          <script type="module" src="js/admin.ts"></script>
        </body>
      </html>
      """)

      {:ok, entries} = DuskmoonBundler.HTMLEntry.extract(Path.join(@fixture_dir, "index.html"))
      assert length(entries.scripts) == 2
      assert length(entries.styles) == 2
    end
  end

  describe "extract/1 path handling" do
    test "resolves root-absolute paths against the HTML directory" do
      File.write!(Path.join(@fixture_dir, "index.html"), """
      <link rel="stylesheet" href="/src/app.css">
      <script type="module" src="/src/main.ts"></script>
      """)

      {:ok, entries} = DuskmoonBundler.HTMLEntry.extract(Path.join(@fixture_dir, "index.html"))
      assert entries.scripts == [Path.join(@fixture_dir, "src/main.ts")]
      assert entries.styles == [Path.join(@fixture_dir, "src/app.css")]
    end

    test "ignores remote, protocol-relative and data URLs" do
      File.write!(Path.join(@fixture_dir, "index.html"), """
      <link rel="stylesheet" href="https://cdn.example.com/app.css">
      <link rel="stylesheet" href="//cdn.example.com/other.css">
      <script src="https://cdn.example.com/lib.js"></script>
      <script src="//cdn.example.com/lib2.js"></script>
      <script src="data:text/javascript,console.log(1)"></script>
      <script type="module" src="js/app.ts"></script>
      """)

      {:ok, entries} = DuskmoonBundler.HTMLEntry.extract(Path.join(@fixture_dir, "index.html"))
      assert entries.scripts == [Path.join(@fixture_dir, "js/app.ts")]
      assert entries.styles == []
    end

    test "returns an error for a missing HTML file" do
      path = Path.join(@fixture_dir, "missing.html")

      assert {:error, {:file_read_error, ^path, :enoent}} =
               DuskmoonBundler.HTMLEntry.extract(path)
    end
  end

  describe "html?/1" do
    test "recognizes HTML files" do
      assert DuskmoonBundler.HTMLEntry.html?("index.html")
      assert DuskmoonBundler.HTMLEntry.html?("page.htm")
    end

    test "rejects non-HTML" do
      refute DuskmoonBundler.HTMLEntry.html?("app.ts")
      refute DuskmoonBundler.HTMLEntry.html?("style.css")
    end
  end
end
