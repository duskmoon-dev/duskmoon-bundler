defmodule OxideTest do
  use ExUnit.Case, async: true

  test "extracts candidates with their source byte positions" do
    assert [
             %Oxide.Candidate{value: "class", position: 0},
             %Oxide.Candidate{value: "flex", position: 7},
             %Oxide.Candidate{value: "text-red-500", position: 12}
           ] = Oxide.extract(~s(class="flex text-red-500"), "html")
  end

  test "scans Ruby word arrays with angle brackets and custom delimiters incrementally" do
    scanner = Oxide.new()
    content = ~s(%w<flex gap-4>\n%w|block px-2|)
    changed = [%{content: content, extension: "rb"}]

    candidates = Oxide.scan_files(scanner, changed)

    for candidate <- ["flex", "gap-4", "block", "px-2"] do
      assert candidate in candidates
    end

    assert [] = Oxide.scan_files(scanner, changed)
    assert ["grid"] = Oxide.scan_files(scanner, [%{content: "grid flex", extension: "html"}])
  end

  test "rejects changed entries without file or content and keeps the scanner usable" do
    scanner = Oxide.new()

    assert_raise ArgumentError, ~r/either :file or :content/, fn ->
      Oxide.scan_files(scanner, [%{extension: "html"}])
    end

    # Bypass Elixir validation: the NIF must raise instead of panicking while
    # holding (and poisoning) the scanner lock.
    assert_raise ArgumentError, fn ->
      Oxide.Native.scan_files(scanner, [
        %Oxide.Changed{content: "flex", extension: "html"},
        %Oxide.Changed{extension: "html"}
      ])
    end

    assert ["flex"] = Oxide.scan_files(scanner, [%{content: "flex", extension: "html"}])
    assert is_list(Oxide.files(scanner))
  end

  describe "filesystem scanning" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib/skip"))
      File.write!(Path.join(tmp_dir, "lib/page.html"), ~s(<div class="flex mt-4"></div>))
      File.write!(Path.join(tmp_dir, "lib/skip/hidden.html"), ~s(<div class="grid px-2"></div>))
      File.write!(Path.join(tmp_dir, "lib/notes.txt"), "underline")
      :ok
    end

    test "scan/1 extracts sorted candidates from files matching the sources", %{tmp_dir: tmp_dir} do
      scanner = Oxide.new(sources: [%{base: tmp_dir, pattern: "**/*.html"}])

      candidates = Oxide.scan(scanner)

      assert candidates == Enum.sort(candidates)
      for candidate <- ["flex", "mt-4", "grid", "px-2"], do: assert(candidate in candidates)
      refute "underline" in candidates
    end

    test "scan/1 honours negated sources", %{tmp_dir: tmp_dir} do
      scanner =
        Oxide.new(
          sources: [
            %Oxide.Source{base: tmp_dir, pattern: "**/*.html"},
            %{base: tmp_dir, pattern: "lib/skip/**", negated: true}
          ]
        )

      candidates = Oxide.scan(scanner)

      assert "flex" in candidates
      refute "grid" in candidates
      refute "px-2" in candidates
      assert Oxide.files(scanner) == [Path.join(tmp_dir, "lib/page.html")]
    end

    test "scan/1 returns every known candidate on each call, including new files", %{
      tmp_dir: tmp_dir
    } do
      scanner = Oxide.new(sources: [%{base: tmp_dir, pattern: "**/*.html"}])

      first = Oxide.scan(scanner)
      assert Oxide.scan(scanner) == first

      File.write!(Path.join(tmp_dir, "lib/added.html"), ~s(<p class="italic"></p>))

      second = Oxide.scan(scanner)
      assert "italic" in second
      assert first -- second == []
    end

    test "files/1 lists the scanned files", %{tmp_dir: tmp_dir} do
      scanner = Oxide.new(sources: [%{base: tmp_dir, pattern: "**/*.html"}])
      assert Oxide.files(Oxide.new()) == []

      Oxide.scan(scanner)

      assert Enum.sort(Oxide.files(scanner)) == [
               Path.join(tmp_dir, "lib/page.html"),
               Path.join(tmp_dir, "lib/skip/hidden.html")
             ]
    end

    test "globs/1 returns the watch patterns for the sources", %{tmp_dir: tmp_dir} do
      scanner = Oxide.new(sources: [%{base: tmp_dir, pattern: "**/*.html"}])
      assert Oxide.globs(Oxide.new()) == []

      Oxide.scan(scanner)

      assert [%Oxide.Glob{base: ^tmp_dir, pattern: "**/*.html"}] = Oxide.globs(scanner)
    end
  end
end
