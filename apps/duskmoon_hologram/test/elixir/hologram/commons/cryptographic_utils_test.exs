defmodule Hologram.Commons.CryptographicUtilsTest do
  use Hologram.Test.BasicCase, async: true
  import Hologram.Commons.CryptographicUtils

  describe "digest/3" do
    test "SHA256 algorithm with hex output format" do
      assert digest("Hologram", :sha256, :hex) ==
               "ddff15a2da596882cfd545132004c8e7355e457517a3874f4853cc6ff1110c2e"
    end

    test "MD5 algorithm with binary output format" do
      assert digest("Hologram", :md5, :binary) ==
               <<8, 132, 19, 120, 33, 216, 230, 154, 210, 235, 180, 219, 210, 116, 125, 36>>
    end
  end

  describe "uuid4/0" do
    test "returns a lowercase UUID with version 4 and RFC variant bits" do
      for _ <- 1..100 do
        assert uuid4() =~
                 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      end
    end

    test "generates independent UUIDs" do
      refute uuid4() == uuid4()
    end
  end
end
