defmodule Player.EdgeCasesTest do
  @moduledoc """
  Races on small known graphs served by `FakeKiwix`. Every reported path is
  checked with the platform verifier's logic (`VerifierCopy`).
  """
  # Not async: the tests register the global harness name.
  use ExUnit.Case, async: false

  alias WikiRace.Status

  setup do
    :yes = :global.re_register_name(WikiRace.Harness.registered_name(), self())
    on_exit(fn -> :global.unregister_name(WikiRace.Harness.registered_name()) end)
    :ok
  end

  @graph %{
    "A" => {:page, ["B", "C", "Caf%C3%A9_(film)", "Mercury_(disambiguation)"]},
    "B" => {:page, ["D", "A"]},
    "C" => {:page, ["A"]},
    "D" => {:page, []},
    "Alias" => {:redirect, "A"},
    "Caf%C3%A9_(film)" => {:page, ["E"]},
    "E" => {:page, []},
    "Mercury_(disambiguation)" => {:page, ["Mercury_(planet)", "Mercury_(element)"]},
    "Mercury_(planet)" => {:page, []},
    "Mercury_(element)" => {:page, []},
    "Island" => {:page, ["Island2"]},
    "Island2" => {:page, ["Island"]},
    # F reaches G through H, and also links an alias of G that redirects to it.
    "F" => {:page, ["GAlias", "H"]},
    "GAlias" => {:redirect, "G"},
    "H" => {:page, ["G"]},
    "G" => {:page, []}
  }

  defp race(base, from, to) do
    start = base <> from
    target = base <> to
    {:ok, pid} = Player.Crawler.start(start, target)
    {pid, start, target}
  end

  defp assert_path(pid, start, target, expected) do
    assert_receive {:path_found, ^pid, path}, 5_000
    assert path == expected
    assert VerifierCopy.verify(path, start, target) == :ok
    # status/1 shows the same path.
    assert %Status{state: :found, path: ^path} = wait_status(pid, :found)
    path
  end

  defp wait_status(pid, state, tries \\ 200) do
    case Player.Crawler.status(pid) do
      %Status{state: ^state} = st ->
        st

      st when tries == 0 ->
        flunk("state never became #{state}: #{inspect(st)}")

      _ ->
        Process.sleep(10)
        wait_status(pid, state, tries - 1)
    end
  end

  test "target linked directly from start: a path of two articles" do
    base = FakeKiwix.start(@graph)
    {pid, s, t} = race(base, "A", "B")
    assert_path(pid, s, t, [s, t])
  end

  test "two hops, never through the target's page" do
    base = FakeKiwix.start(@graph)
    {pid, s, t} = race(base, "A", "D")
    assert_path(pid, s, t, [s, base <> "B", t])
  end

  test "start is a redirect: the path starts with the URL we were given" do
    base = FakeKiwix.start(@graph)
    {pid, s, t} = race(base, "Alias", "D")
    assert_path(pid, s, t, [base <> "Alias", base <> "B", base <> "D"])
  end

  test "a link that only redirects to the target does not count; the path uses real hrefs" do
    base = FakeKiwix.start(@graph)
    {pid, s, t} = race(base, "F", "G")
    assert_path(pid, s, t, [s, base <> "H", t])
  end

  test "Unicode and parentheses in titles; target written with other %-escapes" do
    base = FakeKiwix.start(@graph)
    {pid, s, t} = race(base, "A", "Caf%C3%A9_(film)")
    assert_path(pid, s, t, [s, t])

    # Same article, lowercase hex: canonically equal, and the path must end
    # with the target URL exactly as start/2 received it.
    {pid2, s2, t2} = race(base, "B", "Caf%c3%a9_(film)")
    assert_path(pid2, s2, t2, [s2, base <> "A", t2])
  end

  test "disambiguation page on the way" do
    base = FakeKiwix.start(@graph)
    {pid, s, t} = race(base, "A", "Mercury_(element)")
    assert_path(pid, s, t, [s, base <> "Mercury_(disambiguation)", t])
  end

  test "unreachable target ends as :exhausted and reports nothing" do
    base = FakeKiwix.start(@graph)
    {pid, _s, _t} = race(base, "Island", "A")
    assert_receive {:exhausted, ^pid}, 5_000
    refute_received {:path_found, ^pid, _}
    assert %Status{state: :exhausted, path: []} = wait_status(pid, :exhausted)
  end

  test "start == target: no valid path exists, so nothing is reported" do
    base = FakeKiwix.start(@graph)
    {pid, _s, _t} = race(base, "A", "A")
    assert_receive {:exhausted, ^pid}, 5_000
    refute_received {:path_found, ^pid, _}
  end

  test "missing target page (404) still finds paths that end at its URL" do
    pages = Map.put(@graph, "A", {:page, ["B", "Missing"]})
    base = FakeKiwix.start(pages)
    {pid, s, t} = race(base, "B", "Missing")
    assert_receive {:path_found, ^pid, path}, 5_000
    assert path == [s, base <> "A", t]
  end

  test "no processes leak across many races" do
    base = FakeKiwix.start(@graph)
    # Warm up, then compare.
    {pid, _, _} = race(base, "A", "D")
    assert_receive {:path_found, ^pid, _}, 5_000
    Process.exit(pid, :kill)
    Process.sleep(100)
    before = length(Process.list())

    for _ <- 1..20 do
      {pid, _, _} = race(base, "A", "D")
      assert_receive {:path_found, ^pid, _}, 5_000
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
    end

    Process.sleep(200)
    # Finch may open a few more connections; races themselves leave nothing.
    assert length(Process.list()) <= before + 5
  end
end
