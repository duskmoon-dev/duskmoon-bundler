defmodule Vize.CSSTest do
  use ExUnit.Case, async: true

  describe "collect_urls/2" do
    test "returns byte ranges for unquoted, quoted, and repeated URLs" do
      css = ".é { background: url(a.png), url('b.png') }\n.b { mask: url( \"a.png\" ) }"

      assert {:ok, urls} = Vize.CSS.collect_urls(css, filename: "app.css")
      assert Enum.map(urls, & &1.url) == ["a.png", "b.png", "a.png"]

      for %Vize.CSS.URL{url: url, range: range, location: location} <- urls do
        assert binary_part(css, range.start, range.end - range.start) == url
        assert %Vize.SourceRange{start: %Vize.SourceLocation{line: line}} = location
        assert line in [1, 2]
      end

      assert [%{range: first}, _, %{range: last}] = urls
      assert first != last
    end

    test "ignores URLs in comments and returns no URLs for plain CSS" do
      assert {:ok, [%Vize.CSS.URL{range: %Vize.Range{start: 38, end: 43}}]} =
               Vize.CSS.collect_urls("/* url(a.png) */ .a { background: url(a.png) }")

      assert {:ok, []} = Vize.CSS.collect_urls(".a { color: red }")
      assert [] = Vize.CSS.collect_urls!(".a { color: red }")
    end

    test "skips URLs whose escaped source text cannot be located" do
      css = ".a { background: url(img\\ a.png) } .b { background: url('b.png') }"

      assert {:ok, [%Vize.CSS.URL{url: "b.png", range: range}]} = Vize.CSS.collect_urls(css)
      assert binary_part(css, range.start, range.end - range.start) == "b.png"
    end

    test "returns a Vize.Error for unparsable CSS" do
      assert {:error, %Vize.Error{errors: [message]}} =
               Vize.CSS.collect_urls(".a { background: url(a.png }")

      assert message =~ "CSS parse error"
      assert_raise Vize.Error, fn -> Vize.CSS.collect_urls!(".a { background: url(a.png }") end
    end
  end

  describe "rewrite_urls/3" do
    test "rewrites selected URLs in place and keeps the rest of the source" do
      css =
        "/* keep */\n.a { background: url(a.png) }\n.b { background: url('b.png'), url(a.png) }"

      assert {:ok, rewritten} =
               Vize.CSS.rewrite_urls(css, [filename: "app.css"], fn
                 "a.png" -> {:rewrite, ["/assets/", "a-123.png"]}
                 "b.png" -> :keep
               end)

      assert rewritten ==
               "/* keep */\n.a { background: url(/assets/a-123.png) }\n.b { background: url('b.png'), url(/assets/a-123.png) }"

      assert Vize.CSS.rewrite_urls!(css, fn _ -> :keep end) == css
    end

    test "leaves escaped URLs untouched instead of failing the whole stylesheet" do
      css = ".a { background: url(img\\ a.png) } .b { background: url('b.png') }"

      assert {:ok, rewritten} = Vize.CSS.rewrite_urls(css, fn url -> {:rewrite, "/x/" <> url} end)
      assert rewritten == ".a { background: url(img\\ a.png) } .b { background: url('/x/b.png') }"
    end
  end

  describe "bundle/2" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "nested"))

      File.write!(
        Path.join(tmp_dir, "app.css"),
        "@import './nested/base.css';\n.app { color: red }\n"
      )

      File.write!(
        Path.join(tmp_dir, "nested/base.css"),
        "@import './tokens.css' screen;\n.base { color: blue }\n"
      )

      File.write!(Path.join(tmp_dir, "nested/tokens.css"), ".token { color: green }\n")
      {:ok, entry: Path.join(tmp_dir, "app.css")}
    end

    test "inlines nested imports in dependency order", %{entry: entry} do
      assert {:ok, %{code: code, errors: []}} = Vize.CSS.bundle(entry)

      refute code =~ "@import"
      assert code =~ "@media screen"
      assert [token, base, app] = Enum.map([".token", ".base", ".app"], &offset(code, &1))
      assert token < base and base < app
    end

    test "minifies the bundled stylesheet", %{entry: entry} do
      assert %{code: code} = Vize.CSS.bundle!(entry, minify: true)

      assert code == "@media screen{.token{color:green}}.base{color:#00f}.app{color:red}"
    end

    test "rebases imported image and font URLs before merging rules", %{
      entry: entry,
      tmp_dir: tmp_dir
    } do
      File.write!(entry, "@import './nested/base.css'; .entry { background: url(icon.svg) }")

      File.write!(
        Path.join(tmp_dir, "nested/base.css"),
        """
        @import './deep/tokens.css' screen;
        .base { background: url(icon.svg?theme=dark#symbol) }
        @font-face { font-family: Demo; src: url('../fonts/demo.woff2?v=1#face') }
        .remote { background: url(https://example.com/icon.svg) }
        .data { background: url('data:image/svg+xml;base64,abc') }
        .absolute { background: url(/icons/shared.svg) }
        .fragment { filter: url(#local) }
        """
      )

      File.mkdir_p!(Path.join(tmp_dir, "nested/deep"))

      File.write!(
        Path.join(tmp_dir, "nested/deep/tokens.css"),
        ".deep { background: url('../deep.svg') }"
      )

      for minify <- [false, true] do
        assert {:ok, %{code: code, errors: []}} = Vize.CSS.bundle(entry, minify: minify)
        assert {:ok, urls} = Vize.CSS.collect_urls(code)

        assert Enum.map(urls, & &1.url) == [
                 "nested/deep.svg",
                 "nested/icon.svg?theme=dark#symbol",
                 "fonts/demo.woff2?v=1#face",
                 "https://example.com/icon.svg",
                 "data:image/svg+xml;base64,abc",
                 "/icons/shared.svg",
                 "#local",
                 "icon.svg"
               ]
      end
    end

    test "reports a missing entry in the result errors", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "missing.css")

      assert {:ok, %{code: "", errors: [message]}} = Vize.CSS.bundle(missing)
      assert message =~ "CSS bundle error"
      assert_raise RuntimeError, ~r/CSS bundle error/, fn -> Vize.CSS.bundle!(missing) end
    end

    test "merges shared import media contexts and rebases its asset once", %{
      entry: entry,
      tmp_dir: tmp_dir
    } do
      File.write!(entry, """
      @import './nested/base.css' print;
      @import './nested/base.css' screen;
      .entry { color: red }
      """)

      File.write!(Path.join(tmp_dir, "nested/base.css"), ".base { background: url(icon.svg) }")

      for minify <- [false, true] do
        assert {:ok, %{code: code, errors: []}} = Vize.CSS.bundle(entry, minify: minify)

        assert code =~ ~r/@media print,\s*screen/
        assert length(Regex.scan(~r/\.base\s*\{/, code)) == 1
        assert offset(code, ".base") < offset(code, ".entry")
        assert {:ok, [%Vize.CSS.URL{url: "nested/icon.svg"}]} = Vize.CSS.collect_urls(code)
        refute code =~ "@import"
      end
    end

    test "terminates cyclic imports and preserves each stylesheet's asset path", %{
      entry: entry,
      tmp_dir: tmp_dir
    } do
      File.write!(entry, "@import './nested/base.css'; .entry { background: url(entry.svg) }")

      File.write!(
        Path.join(tmp_dir, "nested/base.css"),
        "@import '../app.css'; .base { background: url(icon.svg) }"
      )

      for minify <- [false, true] do
        assert {:ok, %{code: code, errors: []}} = Vize.CSS.bundle(entry, minify: minify)

        assert length(Regex.scan(~r/\.base\s*\{/, code)) == 1
        assert length(Regex.scan(~r/\.entry\s*\{/, code)) == 1
        assert {:ok, urls} = Vize.CSS.collect_urls(code)
        assert Enum.map(urls, & &1.url) == ["nested/icon.svg", "entry.svg"]
        refute code =~ "@import"
      end
    end

    test "rebases imported assets when the entry uses a relative path", %{
      entry: entry,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "nested/base.css"), ".base { background: url(icon.svg) }")

      assert {:ok, %{code: code, errors: []}} =
               Vize.CSS.bundle(Path.relative_to_cwd(entry), minify: true)

      assert {:ok, [%Vize.CSS.URL{url: "nested/icon.svg"}]} = Vize.CSS.collect_urls(code)
    end

    if match?({:unix, _}, :os.type()) do
      test "preserves symlink asset aliases and filesystem parent traversal", %{
        entry: entry,
        tmp_dir: tmp_dir
      } do
        real_dir = Path.join(tmp_dir, "real/styles")
        File.mkdir_p!(real_dir)
        File.ln_s!(real_dir, Path.join(tmp_dir, "alias"))
        File.write!(entry, "@import './alias/base.css'; .entry { color: red }")

        File.write!(
          Path.join(real_dir, "base.css"),
          "@import '../tokens.css'; .base { background: url(icon.svg) }"
        )

        File.write!(Path.join(tmp_dir, "real/tokens.css"), ".token { color: green }")
        File.write!(Path.join(tmp_dir, "tokens.css"), ".wrong { color: red }")

        for minify <- [false, true] do
          assert {:ok, %{code: code, errors: []}} = Vize.CSS.bundle(entry, minify: minify)

          assert code =~ ".token"
          refute code =~ ".wrong"
          assert {:ok, [%Vize.CSS.URL{url: "alias/icon.svg"}]} = Vize.CSS.collect_urls(code)
        end
      end
    end

    test "retains CSS Modules exports while rebasing imported URLs", %{
      entry: entry,
      tmp_dir: tmp_dir
    } do
      File.write!(entry, "@import './nested/base.css'; .entry { color: red }")
      File.write!(Path.join(tmp_dir, "nested/base.css"), ".base { background: url(icon.svg) }")

      assert {:ok, %{code: code, errors: [], exports: exports}} =
               Vize.CSS.bundle(entry, css_modules: true, minify: true)

      # LightningCSS exports the entry module's classes, while imported classes
      # are scoped within their own modules.
      assert %{"entry" => entry_class} = exports
      assert code =~ ".#{entry_class}"
      refute code =~ ".base{"
      assert {:ok, [%Vize.CSS.URL{url: "nested/icon.svg"}]} = Vize.CSS.collect_urls(code)
    end
  end

  defp offset(code, pattern) do
    {offset, _length} = :binary.match(code, pattern)
    offset
  end
end
