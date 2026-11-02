defmodule Player.RaceTest do
  # Not async: the Kiwix tests register the global harness name.
  use ExUnit.Case, async: false

  alias Player.URL
  alias WikiRace.Status

  # A TCP server that accepts connections and never answers, so fetches stay
  # in flight for as long as we want.
  defp black_hole do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    pid =
      spawn_link(fn ->
        send(test, :listening)
        accept_loop(listen, [])
      end)

    assert_receive :listening
    {port, pid}
  end

  defp accept_loop(listen, socks) do
    case :gen_tcp.accept(listen) do
      {:ok, s} -> accept_loop(listen, [s | socks])
      _ -> :ok
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "killing the race pid kills its task supervisor, its tasks and its ETS tables" do
    {port, _} = black_hole()
    base = "http://127.0.0.1:#{port}/content/book/"

    {:ok, pid} = Player.Crawler.start(base <> "A", base <> "B", receive_timeout: 60_000)
    %{tasks: sup, ctx: %{visited: visited}} = :sys.get_state(pid)
    wait_until(fn -> Task.Supervisor.children(sup) != [] end)

    procs = [sup | Task.Supervisor.children(sup)]
    refs = Enum.map(procs, &Process.monitor/1)

    assert %Status{state: :running, current_url: current} = Player.Crawler.status(pid)
    assert current == base <> "A"

    Process.exit(pid, :kill)

    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)
    refute Enum.any?(procs, &Process.alive?/1)
    assert :ets.info(visited) == :undefined
    wait_until(fn -> Player.Registry.lookup(pid) == nil end)
    assert %Status{} = Player.Crawler.status(pid)
  end

  test "an unreachable start ends as :exhausted" do
    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    base = "http://127.0.0.1:#{port}/content/book/"

    {:ok, pid} = Player.Crawler.start(base <> "A", base <> "B")
    wait_until(fn -> Player.Crawler.status(pid).state == :exhausted end)
    assert Process.alive?(pid)
  end

  ## Against a real Kiwix (mix test --include kiwix). KIWIX_URL defaults to the
  ## local instance on :8081. Never point this at the course server.

  defp kiwix,
    do: System.get_env("KIWIX_URL", "http://localhost:8081/content/wikipedia_en_all_nopic/")

  # The platform verifier, hop by hop.
  defp verify!([_, _ | _] = path) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [from, to] ->
      {:ok, %{status: 200, body: body}} = Req.get(from, retry: false)
      {:ok, doc} = Floki.parse_document(body)

      links =
        doc
        |> Floki.attribute("a", "href")
        |> Enum.reject(&String.starts_with?(&1, ["#", "javascript:", "mailto:"]))
        |> Enum.map(&(from |> URI.merge(&1) |> URI.to_string() |> URL.canonical()))
        |> MapSet.new()

      assert MapSet.member?(links, URL.canonical(to)), "#{from} does not link to #{to}"
    end)
  end

  @tag :kiwix
  @tag timeout: 180_000
  test "finds a valid path on easy cases and status/1 stays fast" do
    :global.re_register_name(WikiRace.Harness.registered_name(), self())

    for {s, t} <- [{"Beer", "Sun"}, {"Cat", "Computer"}, {"Jesus", "God"}] do
      start = kiwix() <> s
      target = kiwix() <> t
      {:ok, pid} = Player.Crawler.start(start, target)

      assert_receive {:path_found, _, path}, 60_000
      assert List.first(path) == start
      assert List.last(path) == target
      assert Player.Path.valid_shape?(path, start, target)
      verify!(path)

      {us, %Status{}} = :timer.tc(fn -> Player.Crawler.status(pid) end)
      assert us < 5_000, "status/1 took #{us} µs"

      Process.exit(pid, :kill)
    end
  after
    :global.unregister_name(WikiRace.Harness.registered_name())
  end
end
