defmodule DuskmoonBundler.PublicDirTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.PublicDir

  @moduletag :tmp_dir

  test "resolves percent-encoded file names", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "my file.txt"), "public")

    assert PublicDir.lookup(dir, "/my%20file.txt") == Path.join(dir, "my file.txt")
  end

  test "returns nil for malformed percent escapes", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "favicon.svg"), "<svg/>")

    assert PublicDir.lookup(dir, "/%zz") == nil
    assert PublicDir.lookup(dir, "/favicon.svg%") == nil
    assert PublicDir.lookup(dir, "/%E4%B8") == nil
  end

  test "does not escape the public directory through encoded traversal", %{tmp_dir: dir} do
    public = Path.join(dir, "public")
    File.mkdir_p!(public)
    File.write!(Path.join(dir, "secret.txt"), "secret")

    assert PublicDir.lookup(public, "/%2e%2e/secret.txt") == nil
  end
end
