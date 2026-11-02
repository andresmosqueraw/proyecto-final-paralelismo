defmodule Player.Race do
  @moduledoc """
  One race: the coordinator whose pid `Player.Crawler.start/2` returns.

  ## Processes

  The race links a `Task.Supervisor`. Each fetch runs in its own task under it,
  so when the harness kills the race pid the supervisor and every task die with
  it. ETS tables are owned by the race and disappear with it too.

  ## Shared state (ETS)

    * `visited` (`set`): `{canonical, parent_canonical, url, depth, key, :queued | :taken}`.
      A URL is inserted with `:ets.insert_new/2` the first time a page links to
      it. `url` is the href as written in the parent page (what we report).
    * `frontier` (`ordered_set`): `{{-score, seq}, url, canonical, depth}`. The
      best score comes first (`Player.Heuristic`). Tasks insert; only the race takes.
    * `target_out` (`set`): canonical URLs linked from the target page.
    * `status` (`set`): `{:status, current_url, best_path, state}` for `status/1`.
    * `measure` (`duplicate_bag`, only with `measure: true`): `{fetch_ms, process_ms, bytes}`
      per fetched page, for the benchmark.
    * `trace` (`bag`, only with `trace: true`): `{canonical, score, depth, links_target?}`
      per fetched page, to validate the heuristic offline.

  ## Search

  At start the race fetches the start page and, in parallel, the target page
  (its links feed the heuristic; the start page waits for them, at most 3 s).

  A task downloads a page, extracts its article links and **checks for the
  target before anything else**, so a path is reported as soon as a page that
  links to the target is read. Then it scores the links and inserts the new
  ones. A link already queued from another page is moved up if it now scores
  higher (with a compare-and-swap on its `visited` row), and its parent becomes
  the new page. Every parent in `visited` is a page whose links contained the
  child, so any reconstructed path is a real chain of links.

  After a path of `L` URLs is found, pages at depth `d` are only useful if
  `d + 2 < L`: deeper frontier entries are deleted and no deeper links are
  queued, and the search keeps looking for a shorter path until the frontier
  empties. When it empties, the best path is the shortest one (bar depth
  overestimates) and the race stops fetching. It does not call
  `report_exhausted/0` then: the platform ignores it once a path is in.

  A shorter path is only reported if it is worth it (`worth_reporting?/4`,
  option `report_policy: :score`, the default; `:always` reports every one).
  """

  use GenServer, restart: :temporary

  require Logger

  alias Player.{Fetcher, Heuristic, Links, Path, URL}

  @no_path 1_000_000
  @max_attempts 2
  @target_wait_ms 3_000
  # Fetches in flight. Kiwix, not our CPU, is the limit: on the local Kiwix
  # throughput stays at ~350 pages/s from 16 to 128 in flight and only the
  # latency per fetch grows, and the first path is a chain of ~3 sequential
  # fetches. 16 had the best or near-best median alone and against a rival
  # sharing Kiwix (fase5_hallazgos.md).
  @concurrency 16
  # ~6x the p99 fetch latency measured under contention (~350 ms), leaving room
  # for a remote Kiwix. A timed-out fetch is retried once.
  @receive_timeout 2_000
  # Safety net in case nobody kills us (benchmarks, tests). Races last 120 s.
  @lifetime_ms 150_000

  # :atomics slots
  @a_best 1
  @a_target_ready 2
  @a_target_n 3

  def start_link({start_url, target_url, opts}) do
    GenServer.start_link(__MODULE__, {start_url, target_url, opts})
  end

  @impl true
  def init({start_url, target_url, opts}) do
    visited =
      :ets.new(:visited, [:set, :public, read_concurrency: true, write_concurrency: true])

    # decentralized_counters (the default with write_concurrency on an
    # ordered_set) makes :ets.info(t, :size) slow under load, and status/1
    # reads that size every 250 ms.
    frontier =
      :ets.new(:frontier, [
        :ordered_set,
        :public,
        write_concurrency: true,
        decentralized_counters: false
      ])

    bfs_share = Keyword.get(opts, :bfs_share, 0.0)

    bfs_frontier =
      if bfs_share > 0,
        do: :ets.new(:bfs_frontier, [:ordered_set, :public, write_concurrency: true])

    target_out = :ets.new(:target_out, [:set, :public, read_concurrency: true])
    status = :ets.new(:status, [:set, :public, read_concurrency: true])
    trace = if opts[:trace], do: :ets.new(:trace, [:bag, :public, write_concurrency: true])

    measure =
      if opts[:measure],
        do: :ets.new(:measure, [:duplicate_bag, :public, write_concurrency: true])

    # 1: pages fetched, 2: failed fetches
    counters = :counters.new(2, [:write_concurrency])
    atomics = :atomics.new(3, [])
    :atomics.put(atomics, @a_best, @no_path)

    {:ok, tasks} = Task.Supervisor.start_link()

    start_canon = URL.canonical(start_url)
    target_canon = URL.canonical(target_url)
    start_key = {0.0, 0}

    :ets.insert(visited, {start_canon, nil, start_url, 0, start_key, :queued})
    :ets.insert(frontier, {start_key, start_url, start_canon, 0})
    if bfs_frontier, do: :ets.insert(bfs_frontier, {{0, 0.0, 0}, start_url, start_canon, 0})
    :ets.insert(status, {:status, start_url, [], :running})

    :ok =
      Player.Registry.register(%{
        status: status,
        counters: counters,
        frontier: frontier,
        trace: trace,
        measure: measure
      })

    Process.send_after(self(), :lifetime_over, Keyword.get(opts, :lifetime_ms, @lifetime_ms))

    weights = Heuristic.weights(Keyword.get(opts, :weights, :default))

    ctx = %{
      race: self(),
      visited: visited,
      frontier: frontier,
      target_out: target_out,
      trace: trace,
      measure: measure,
      bfs_frontier: bfs_frontier,
      bfs_share: bfs_share,
      counters: counters,
      atomics: atomics,
      target_canon: target_canon,
      target_tokens: MapSet.new(Heuristic.tokens(target_canon)),
      weights: weights,
      # BFS (depth-only) needs neither the target's links nor the wait.
      needs_target?: weights.out != 0.0 or weights.rel != 0.0,
      receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout)
    }

    state = %{
      ctx: ctx,
      tasks: tasks,
      status: status,
      start_url: start_url,
      target_url: target_url,
      concurrency: Keyword.get(opts, :concurrency, @concurrency),
      inflight: %{},
      # The path we reported last and when (ms since start); the harness keeps
      # it with that arrival time.
      best_path: nil,
      reported_at: nil,
      report_policy: Keyword.get(opts, :report_policy, :score),
      finished: false,
      started_at: System.monotonic_time(:millisecond)
    }

    cond do
      start_canon == target_canon ->
        # No valid path exists (it would repeat the same article).
        {:ok, finish(state)}

      ctx.needs_target? ->
        {:ok, spawn_target_fetch(state, 1), {:continue, :dispatch}}

      true ->
        :atomics.put(atomics, @a_target_ready, 1)
        {:ok, state, {:continue, :dispatch}}
    end
  end

  @impl true
  def handle_continue(:dispatch, state), do: {:noreply, dispatch(state)}

  @impl true
  def handle_info({:found, parent_canon}, state), do: {:noreply, found(state, parent_canon)}

  def handle_info({ref, result}, %{inflight: inflight} = state)
      when is_map_key(inflight, ref) do
    Process.demonitor(ref, [:flush])
    {job, inflight} = Map.pop(inflight, ref)
    state = %{state | inflight: inflight}

    state =
      case result do
        :ok -> state
        # The page answered (404, 500...): asking again will not help.
        {:error, {:http, _status}} -> state
        # Transport errors and timeouts: one retry.
        _error -> retry(state, job)
      end

    {:noreply, dispatch(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inflight: inflight} = state)
      when is_map_key(inflight, ref) do
    {job, inflight} = Map.pop(inflight, ref)
    {:noreply, dispatch(retry(%{state | inflight: inflight}, job))}
  end

  def handle_info(:lifetime_over, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  ## Dispatch

  defp dispatch(%{finished: true} = state), do: state

  defp dispatch(state) do
    if map_size(state.inflight) >= state.concurrency do
      state
    else
      %{visited: visited, atomics: atomics} = state.ctx

      case take_next(state.ctx) do
        :empty ->
          maybe_finish(state)

        {url, canon, depth, score} ->
          cond do
            depth + 2 >= :atomics.get(atomics, @a_best) ->
              dispatch(state)

            # Already fetched (a stale duplicate left by a priority update or
            # by the other frontier of the portfolio).
            :ets.lookup_element(visited, canon, 6, :taken) == :taken ->
              dispatch(state)

            true ->
              :ets.update_element(visited, canon, {6, :taken})
              state |> spawn_fetch({:page, url, canon, depth, score, 1}) |> dispatch()
          end

        :retry ->
          dispatch(state)
      end
    end
  end

  # Portfolio (Gomes & Selman 01): with probability `bfs_share` take the
  # shallowest entry (ties by score) instead of the best-scored one. Every
  # queued node is in the main frontier, so it alone decides emptiness.
  defp take_next(%{bfs_frontier: bfs} = ctx) when bfs != nil do
    if :rand.uniform() < ctx.bfs_share do
      case take_first(bfs) do
        {:ok, {_d, neg, _seq}, url, canon, depth} -> {url, canon, depth, -neg}
        :empty -> take_main(ctx)
        :retry -> :retry
      end
    else
      take_main(ctx)
    end
  end

  defp take_next(ctx), do: take_main(ctx)

  defp take_main(ctx) do
    case take_first(ctx.frontier) do
      {:ok, {neg, _seq}, url, canon, depth} -> {url, canon, depth, -neg}
      other -> other
    end
  end

  defp take_first(table) do
    case :ets.first(table) do
      :"$end_of_table" ->
        :empty

      key ->
        case :ets.take(table, key) do
          [{^key, url, canon, depth}] -> {:ok, key, url, canon, depth}
          [] -> :retry
        end
    end
  end

  defp spawn_fetch(state, {:page, url, canon, depth, score, _attempt} = job) do
    ctx = state.ctx

    task =
      Task.Supervisor.async_nolink(state.tasks, fn -> crawl(ctx, url, canon, depth, score) end)

    :ets.update_element(state.status, :status, {2, url})
    %{state | inflight: Map.put(state.inflight, task.ref, job)}
  end

  defp spawn_target_fetch(state, attempt) do
    ctx = state.ctx
    url = state.target_url
    task = Task.Supervisor.async_nolink(state.tasks, fn -> load_target(ctx, url) end)
    %{state | inflight: Map.put(state.inflight, task.ref, {:target, attempt})}
  end

  defp retry(state, {:page, url, canon, depth, score, attempt}) when attempt < @max_attempts do
    spawn_fetch(state, {:page, url, canon, depth, score, attempt + 1})
  end

  defp retry(state, {:target, attempt}) when attempt < @max_attempts do
    spawn_target_fetch(state, attempt + 1)
  end

  defp retry(state, {:target, _attempt}) do
    # Go on without the target's links rather than wait forever.
    :atomics.put(state.ctx.atomics, @a_target_ready, 1)
    state
  end

  defp retry(state, _job), do: state

  ## Work done inside tasks

  @doc false
  def load_target(ctx, url) do
    case Fetcher.get(url, receive_timeout: ctx.receive_timeout) do
      {:ok, body} ->
        :counters.add(ctx.counters, 1, 1)
        links = Links.extract(body, url)
        :ets.insert(ctx.target_out, Enum.map(links, fn {_u, c} -> {c} end))
        :atomics.put(ctx.atomics, @a_target_n, length(links))
        :atomics.put(ctx.atomics, @a_target_ready, 1)
        :ok

      {:error, reason} ->
        :counters.add(ctx.counters, 2, 1)
        {:error, reason}
    end
  rescue
    ArgumentError -> :race_gone
  end

  @doc false
  def crawl(ctx, url, canon, depth, score) do
    t0 = System.monotonic_time(:microsecond)

    case Fetcher.get(url, receive_timeout: ctx.receive_timeout) do
      {:ok, body} ->
        t1 = System.monotonic_time(:microsecond)
        :counters.add(ctx.counters, 1, 1)
        links = Links.extract(body, url)
        target = ctx.target_canon
        links_target? = Enum.any?(links, fn {_u, c} -> c == target end)

        if links_target?, do: send(ctx.race, {:found, canon})
        if ctx.trace, do: :ets.insert(ctx.trace, {canon, score, depth, links_target?})

        child_depth = depth + 1

        if child_depth + 2 < :atomics.get(ctx.atomics, @a_best) do
          expand(ctx, canon, child_depth, links)
        end

        if ctx.measure do
          t2 = System.monotonic_time(:microsecond)
          :ets.insert(ctx.measure, {(t1 - t0) / 1000, (t2 - t1) / 1000, byte_size(body)})
        end

        :ok

      {:error, reason} ->
        :counters.add(ctx.counters, 2, 1)
        {:error, reason}
    end
  rescue
    # The race was killed: its ETS tables are gone and this task is about to
    # be shut down by the supervisor. Exit quietly instead of logging a crash.
    ArgumentError -> :race_gone
  end

  defp expand(ctx, parent, child_depth, links) do
    %{visited: visited, frontier: frontier, target_out: target_out} = ctx
    if ctx.needs_target?, do: wait_for_target(ctx.atomics, @target_wait_ms)

    target_n = :atomics.get(ctx.atomics, @a_target_n)
    in_target_out? = fn c -> target_n > 0 and :ets.member(target_out, c) end

    rel_p =
      if ctx.weights.rel != 0.0 and target_n > 0 do
        shared = Enum.count(links, fn {_u, c} -> :ets.member(target_out, c) end)
        Heuristic.rel(shared, length(links), target_n)
      else
        0.0
      end

    target = ctx.target_canon

    entries =
      links
      |> Heuristic.score_links(child_depth, rel_p, in_target_out?, ctx.target_tokens, ctx.weights)
      |> Enum.reduce([], fn
        {_u, ^target, _s}, acc ->
          acc

        {u, c, s}, acc ->
          key = {-s, :erlang.unique_integer([:monotonic, :positive])}

          if :ets.insert_new(visited, {c, parent, u, child_depth, key, :queued}) do
            [{key, u, c, child_depth} | acc]
          else
            maybe_promote(
              visited,
              frontier,
              {c, parent, u, child_depth, s},
              ctx.weights.depth,
              acc
            )
          end
      end)

    :ets.insert(frontier, entries)
    if ctx.bfs_frontier, do: :ets.insert(ctx.bfs_frontier, Enum.map(entries, &by_depth/1))
  end

  # Main-frontier entry -> BFS-frontier entry ({depth, -score, seq} key).
  defp by_depth({{neg, seq}, u, c, d}), do: {{d, neg, seq}, u, c, d}

  # A link already queued from another page: move it up if it now scores
  # higher. If the new page is at least as shallow as the old parent, it
  # becomes the parent. If it is deeper, the parent is kept (re-parenting would
  # make the path longer) and only the priority goes up, scored at the old
  # depth. The compare-and-swap fails if the row changed in the meantime (taken
  # by the race, or promoted by another task), and then we do nothing.
  defp maybe_promote(visited, frontier, {c, parent, u, child_depth, s}, w_depth, acc) do
    case :ets.lookup(visited, c) do
      [{^c, old_p, old_u, old_d, {old_neg, _} = old_key, :queued} = old] ->
        {p2, u2, d2, s2} =
          if child_depth <= old_d,
            do: {parent, u, child_depth, s},
            else: {old_p, old_u, old_d, s + w_depth * (child_depth - old_d)}

        key = {-s2, :erlang.unique_integer([:monotonic, :positive])}

        if s2 > -old_neg and
             :ets.select_replace(visited, [{old, [], [{:const, {c, p2, u2, d2, key, :queued}}]}]) ==
               1 do
          :ets.delete(frontier, old_key)
          [{key, u2, c, d2} | acc]
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp wait_for_target(atomics, left) do
    if :atomics.get(atomics, @a_target_ready) == 0 and left > 0 do
      Process.sleep(5)
      wait_for_target(atomics, left - 5)
    end
  end

  ## Results

  defp found(state, parent_canon) do
    path = Path.to_target(state.ctx.visited, parent_canon, state.start_url, state.target_url)
    best = :atomics.get(state.ctx.atomics, @a_best)

    if path != [] and length(path) < best and
         Path.valid_shape?(path, state.start_url, state.target_url) do
      len = length(path)
      now = System.monotonic_time(:millisecond) - state.started_at
      # Search only for paths shorter than the best one known, reported or not.
      :atomics.put(state.ctx.atomics, @a_best, len)
      # Entries at depth >= len - 2 cannot lead to a shorter path.
      for t <- [state.ctx.frontier, state.ctx.bfs_frontier], t != nil do
        :ets.select_delete(t, [{{:_, :_, :_, :"$1"}, [{:>=, :"$1", len - 2}], [true]}])
      end

      if report?(state, len, now) do
        WikiRace.Harness.report(path)
        # status/1 counts as a report too, so it only ever shows reported paths.
        :ets.update_element(state.status, :status, [{3, path}, {4, :found}])

        Logger.info(
          "[race] path of #{len} articles after #{now} ms: " <>
            Enum.map_join(path, " -> ", &URL.title/1)
        )

        %{state | best_path: path, reported_at: now}
      else
        Logger.info(
          "[race] not reporting a path of #{len} articles at #{now} ms " <>
            "(reported #{length(state.best_path)} at #{state.reported_at} ms)"
        )

        state
      end
    else
      state
    end
  end

  @doc """
  Whether reporting a shorter path is worth it (the harness keeps the shortest
  path *with its arrival time*, and the race ends as soon as both crawlers
  have a verified path, so improvements only count if they come early).

  Going from `l` to `l2` articles, reported at `t1` and now `t2` ms, assuming
  we are the fastest crawler and the new path is the shortest in the race:

      gain (Hops) = 0.20 * (1 - l2 / l)
      loss (Time) = 0.15 * (1 - t1 / t2)

  Report only if the gain is larger.
  """
  def worth_reporting?(l, t1, l2, t2) do
    0.20 * (1 - l2 / l) > 0.15 * (1 - max(t1, 1) / max(t2, 1))
  end

  defp report?(%{best_path: nil}, _len, _now), do: true
  defp report?(%{report_policy: :always}, _len, _now), do: true

  defp report?(state, len, now),
    do: worth_reporting?(length(state.best_path), state.reported_at, len, now)

  defp maybe_finish(%{inflight: inflight} = state) when map_size(inflight) > 0, do: state
  defp maybe_finish(state), do: finish(state)

  defp finish(%{finished: true} = state), do: state

  defp finish(state) do
    if state.best_path == nil do
      WikiRace.Harness.report_exhausted()
      :ets.update_element(state.status, :status, {4, :exhausted})
    end

    Logger.info(
      "[race] finished after #{System.monotonic_time(:millisecond) - state.started_at} ms, " <>
        "#{:counters.get(state.ctx.counters, 1)} pages fetched"
    )

    %{state | finished: true}
  end
end
