defmodule QuickBEAM.SandboxTest do
  use ExUnit.Case, async: true

  for kind <- [:runtime, :context] do
    describe "#{kind} strict sandbox" do
      setup do
        owner = self()

        handlers = %{
          "echo" => fn [value] -> value end,
          "is_map" => fn [value] -> is_map(value) end,
          "delayed" => fn [value] ->
            send(owner, {:handler_started, self()})
            receive do: (:complete -> value)
          end
        }

        case unquote(kind) do
          :runtime ->
            runtime = start_supervised!({QuickBEAM, sandbox: :strict, handlers: handlers})
            %{runtime: runtime, api: QuickBEAM}

          :context ->
            pool = start_supervised!({QuickBEAM.ContextPool, size: 1})

            runtime =
              start_supervised!(
                {QuickBEAM.Context, pool: pool, sandbox: :strict, handlers: handlers}
              )

            %{runtime: runtime, api: QuickBEAM.Context}
        end
      end

      test "only explicit handlers are available, including async callbacks and retained generators",
           %{
             runtime: runtime,
             api: api
           } do
        assert {:ok, 42} = api.eval(runtime, ~s|Beam.callSync("echo", 42)|)
        task = Task.async(fn -> api.eval(runtime, ~s|await Beam.call("delayed", 43)|) end)
        assert_receive {:handler_started, handler}
        send(handler, :complete)
        assert {:ok, 43} = Task.await(task)

        assert {:ok, 1} =
                 api.eval(runtime, """
                 globalThis.sequence = (function* () { yield 1; yield 2; })();
                 sequence.next().value
                 """)

        assert {:ok, 2} = api.eval(runtime, "sequence.next().value")
      end

      test "privileged private handlers are denied through both native call paths", %{
        runtime: runtime,
        api: api
      } do
        for name <- [
              "__beam_whereis",
              "__beam_spawn",
              "__beam_rpc",
              "__beam_register",
              "__beam_link",
              "__process_monitor",
              "__process_demonitor",
              "__process_env_get",
              "__fs_read_file",
              "__child_process_exec_sync",
              "__fetch",
              "__ws_connect",
              "__eventsource_open",
              "__worker_spawn"
            ],
            call <- ["await Beam.call", "Beam.callSync"] do
          assert {:error, %QuickBEAM.JSError{message: message}} =
                   api.eval(runtime, ~s|#{call}(#{inspect(name)}, "init")|)

          assert message =~ "Unknown handler: #{name}"
        end
      end

      test "native process messaging is denied even when a host passes a valid PID", %{
        runtime: runtime,
        api: api
      } do
        :ok = api.set_global(runtime, "target", self())

        for code <- [
              "Beam.self()",
              "Beam.send(target, 'escaped')",
              "Reflect.apply(Beam.send, null, [target, 'escaped'])",
              "Beam.onMessage(() => {})"
            ] do
          assert {:error, %QuickBEAM.JSError{message: message}} = api.eval(runtime, code)
          assert message =~ "denied in strict sandbox mode"
        end

        refute_receive "escaped"
      end

      test "ambient APIs and module imports stay unavailable across reset", %{
        runtime: runtime,
        api: api
      } do
        for _ <- 1..2 do
          assert {:ok, 42} = api.eval(runtime, ~s|await Beam.call("echo", 42)|)
          assert {:ok, 43} = api.eval(runtime, ~s|Beam.callSync("echo", 43)|)

          assert {:ok, true} =
                   api.eval(runtime, """
                   ['fetch', 'WebSocket', 'EventSource', 'Worker', 'process', 'fs',
                    'require', 'console', 'WebAssembly'].every(name => !(name in globalThis))
                   """)

          for module <- [
                "node:fs",
                "node:child_process",
                "file:///etc/passwd",
                "https://example.invalid/a.js",
                "data:text/javascript,export default 1"
              ] do
            assert {:error, %QuickBEAM.JSError{}} =
                     api.eval(runtime, "await import(#{inspect(module)})")
          end

          assert :ok = api.reset(runtime)
        end
      end

      test "symbols and forged external terms cannot allocate VM atoms", %{
        runtime: runtime,
        api: api
      } do
        name = "sandbox_atom_" <> Base.encode16(:crypto.strong_rand_bytes(16))
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
        assert {:ok, ^name} = api.eval(runtime, "Symbol(#{inspect(name)})")

        assert {:ok, ^name} =
                 api.eval(runtime, ~s|await Beam.call("echo", Symbol(#{inspect(name)}))|)

        # ETF SMALL_ATOM_UTF8_EXT, assembled without interning the name in Elixir.
        encoded = <<131, 119, byte_size(name)>> <> name
        bytes = encoded |> :binary.bin_to_list() |> JSON.encode!()
        object = "({__beam_type__: 'atom', __beam_data__: new Uint8Array(#{bytes})})"

        assert {:ok, %{"__beam_type__" => "atom", "__beam_data__" => ^encoded}} =
                 api.eval(runtime, object)

        for call <- ["await Beam.call", "Beam.callSync"] do
          assert {:ok, true} = api.eval(runtime, "#{call}('is_map', #{object})")
        end

        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end
  end

  test "strict runtime denies host addon loading before accessing a path" do
    runtime = start_supervised!({QuickBEAM, sandbox: :strict})
    assert {:error, reason} = QuickBEAM.load_addon(runtime, "/missing/addon.node")
    assert inspect(reason) =~ "denied in strict sandbox mode"
  end

  test "strict contexts do not restrict a trusted neighbour on the same pool" do
    pool = start_supervised!({QuickBEAM.ContextPool, size: 1})
    strict = start_supervised!({QuickBEAM.Context, id: :strict, pool: pool, sandbox: :strict})
    trusted = start_supervised!({QuickBEAM.Context, id: :trusted, pool: pool})
    assert {:ok, "function"} = QuickBEAM.Context.eval(trusted, "typeof fetch")
    assert {:ok, ^trusted} = QuickBEAM.Context.eval(trusted, "Beam.self()")
    assert {:error, %QuickBEAM.JSError{}} = QuickBEAM.Context.eval(strict, "Beam.self()")
  end

  test "strict options reject conflicting APIs and reserved handler names before starting" do
    assert {:error, {:sandbox_conflict, :apis}} =
             QuickBEAM.start(sandbox: :strict, apis: [:browser])

    assert {:error, {:sandbox_conflict, :handlers}} =
             QuickBEAM.start(sandbox: :strict, handlers: %{"__beam_spawn" => fn _ -> :ok end})

    assert {:error, {:invalid_option, :sandbox, true}} = QuickBEAM.start(sandbox: true)
  end
end
