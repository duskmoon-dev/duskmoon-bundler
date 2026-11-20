defmodule DuskmoonBundler.HMR.SocketTest do
  use ExUnit.Case, async: false

  alias DuskmoonBundler.HMR.{CompileErrors, Socket}

  describe "compile errors" do
    setup do
      root = Path.join(System.tmp_dir!(), "duskmoon-errors-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      path = Path.join(root, "app.ts")
      source = "const = ;"
      File.write!(path, source)
      on_exit(fn -> File.rm_rf!(root) end)
      config = %DuskmoonBundler.DevServer.Config{root: root}

      %{
        scope: CompileErrors.scope(config),
        config: config,
        path: path,
        version: :crypto.hash(:sha256, source)
      }
    end

    test "replays pending errors and ignores saves and deletions", ctx do
      CompileErrors.put(ctx.scope, :app, ctx.path, ctx.version, "invalid source")
      {:ok, state} = Socket.init(%{error_scope: ctx.scope})
      assert_receive {:duskmoon_bundler_compile_error, :app, version} = message
      assert version == ctx.version
      assert {:push, {:text, json}, ^state} = Socket.handle_info(message, state)

      assert Jason.decode!(json) == %{
               "type" => "error",
               "payload" => %{"reason" => "invalid source"}
             }

      File.write!(ctx.path, "const value = 42")
      assert {:ok, ^state} = Socket.handle_info(message, state)

      File.write!(ctx.path, "const = ;")
      CompileErrors.put(ctx.scope, :app, ctx.path, ctx.version, "invalid again")
      File.rm!(ctx.path)
      assert {:ok, ^state} = Socket.handle_info(message, state)
    end

    test "isolates endpoints and compile variants and drops successfully compiled errors", ctx do
      {:ok, state} = Socket.init(%{error_scope: ctx.scope})
      other_scope = CompileErrors.scope(%{ctx.config | target: "es2020"})
      CompileErrors.put(other_scope, :app, ctx.path, ctx.version, "different endpoint")
      refute_receive {:duskmoon_bundler_compile_error, _, _}

      CompileErrors.put(ctx.scope, :app, ctx.path, ctx.version, "failed")
      assert_receive {:duskmoon_bundler_compile_error, :app, _} = message
      CompileErrors.clear(ctx.scope, :other_variant, ctx.version)
      assert {:push, _, ^state} = Socket.handle_info(message, state)
      CompileErrors.clear(ctx.scope, :app, ctx.version)
      assert {:ok, ^state} = Socket.handle_info(message, state)
    end

    test "a queued old error cannot erase a newer source error", ctx do
      {:ok, state} = Socket.init(%{error_scope: ctx.scope})
      CompileErrors.put(ctx.scope, :app, ctx.path, ctx.version, "old")
      assert_receive {:duskmoon_bundler_compile_error, :app, _} = old_message

      File.write!(ctx.path, "export const = ;")
      version = :crypto.hash(:sha256, "export const = ;")
      CompileErrors.put(ctx.scope, :app, ctx.path, version, "new")
      assert_receive {:duskmoon_bundler_compile_error, :app, ^version} = new_message
      CompileErrors.clear(ctx.scope, :app, ctx.version)
      assert {:ok, ^state} = Socket.handle_info(old_message, state)
      assert {:push, {:text, json}, ^state} = Socket.handle_info(new_message, state)
      assert Jason.decode!(json)["payload"]["reason"] == "new"
    end

    test "late completion of an old compilation cannot overwrite the current error", ctx do
      {:ok, state} = Socket.init(%{error_scope: ctx.scope})
      File.write!(ctx.path, "export const = ;")
      version = :crypto.hash(:sha256, "export const = ;")
      CompileErrors.put(ctx.scope, :app, ctx.path, version, "current error")
      assert_receive {:duskmoon_bundler_compile_error, :app, ^version} = current_message

      CompileErrors.put(ctx.scope, :app, ctx.path, ctx.version, "old error")
      assert_receive {:duskmoon_bundler_compile_error, :app, _} = old_message
      assert {:ok, ^state} = Socket.handle_info(old_message, state)
      assert {:push, {:text, json}, ^state} = Socket.handle_info(current_message, state)
      assert Jason.decode!(json)["payload"]["reason"] == "current error"
    end
  end

  describe "init/1" do
    test "registers with registry" do
      {:ok, _state} = Socket.init(nil)
      me = self()
      assert {me, nil} in Registry.lookup(DuskmoonBundler.HMR.Registry, :clients)
    end
  end

  describe "handle_info/2" do
    test "broadcasts HMR messages as JSON" do
      {:ok, state} = Socket.init(nil)

      {:push, {:text, json}, _state} =
        Socket.handle_info(
          {:duskmoon_bundler_hmr, :update, %{path: "App.vue", changes: [:template]}},
          state
        )

      decoded = Jason.decode!(json)
      assert decoded["type"] == "update"
      assert decoded["payload"]["path"] == "App.vue"
      assert decoded["payload"]["changes"] == ["template"]
    end

    test "ignores unknown messages" do
      {:ok, state} = Socket.init(nil)
      assert {:ok, ^state} = Socket.handle_info(:unknown, state)
    end
  end

  describe "handle_in/2" do
    test "replies to heartbeat pings with a JSON pong" do
      {:ok, state} = Socket.init(nil)

      {:push, {:text, json}, _state} =
        Socket.handle_in({~s({"type":"ping"}), opcode: :text}, state)

      decoded = Jason.decode!(json)
      assert decoded["type"] == "pong"
    end

    test "ignores unknown incoming message types" do
      {:ok, state} = Socket.init(nil)

      assert {:ok, ^state} =
               Socket.handle_in(
                 {~s({"type":"something-else"}), opcode: :text},
                 state
               )
    end

    test "ignores malformed JSON frames" do
      {:ok, state} = Socket.init(nil)

      assert {:ok, ^state} =
               Socket.handle_in({"not-json", opcode: :text}, state)
    end
  end
end
