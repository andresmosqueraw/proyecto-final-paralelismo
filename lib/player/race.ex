defmodule Player.Race do
  @moduledoc """
  One race: the coordinator whose pid `Player.Crawler.start/2` returns.

  ## Processes

  The race links a `Task.Supervisor`. Each fetch runs in its own task under it,
  so when the harness kills the race pid the supervisor and every task die with
  it. ETS tables are owned by the race and disappear with it too.

  ## Shared state (ETS)

    * `visited` (`set`): `{canonical, parent_canonical, url, depth}`. A URL is
      inserted with `:ets.insert_new/2` the first time any page links to it, so
      each article enters the frontier once, with the page that linked to it.
    * `frontier` (`ordered_set`): `{{depth, seq}, url, canonical}`. Ordering by
      depth gives BFS. Tasks insert children directly; only the race takes.
    * `status` (`set`): `{:status, current_url, best_path, state}` for `status/1`.

  ## Search

  The race keeps up to `concurrency` fetches in flight. A task downloads a page,
  extracts its article links and **checks for the target before inserting
  anything**, so a path is found as soon as a page that links to the target is
  read, without downloading the target itself.

  After a path of `L` URLs is found, pages at depth `d` are only useful if
  `d + 2 < L`, so deeper work is pruned and the search keeps looking for a
  shorter path until the frontier empties.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Player.{Fetcher, Links, Path, URL}

  @no_path 1_000_000
  @max_attempts 2
  # Safety net in case nobody kills us (benchmarks, tests). Races last 120 s.
  @lifetime_ms 150_000

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

    status = :ets.new(:status, [:set, :public, read_concurrency: true])
    # 1: pages fetched
    counters = :counters.new(1, [:write_concurrency])
    # 1: length (in URLs) of the best path reported so far
    best = :atomics.new(1, [])
    :atomics.put(best, 1, @no_path)

    {:ok, tasks} = Task.Supervisor.start_link()

    start_canon = URL.canonical(start_url)
    target_canon = URL.canonical(target_url)

    :ets.insert(visited, {start_canon, nil, start_url, 0})
    :ets.insert(frontier, {{0, 0}, start_url, start_canon})
    :ets.insert(status, {:status, start_url, [], :running})

    :ok = Player.Registry.register(%{status: status, counters: counters, frontier: frontier})
    Process.send_after(self(), :lifetime_over, Keyword.get(opts, :lifetime_ms, @lifetime_ms))

    ctx = %{
      race: self(),
      visited: visited,
      frontier: frontier,
      counters: counters,
      best: best,
      target_canon: target_canon,
      receive_timeout: Keyword.get(opts, :receive_timeout, 5_000)
    }

    state = %{
      ctx: ctx,
      tasks: tasks,
      status: status,
      start_url: start_url,
      target_url: target_url,
      concurrency: Keyword.get(opts, :concurrency, 4 * System.schedulers_online()),
      inflight: %{},
      best_path: nil,
      finished: false,
      started_at: System.monotonic_time(:millisecond)
    }

    if start_canon == target_canon do
      # No valid path exists (it would repeat the same article).
      {:ok, finish(state)}
    else
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
        {:error, _reason} -> retry(state, job)
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
      case :ets.first(state.ctx.frontier) do
        :"$end_of_table" ->
          maybe_finish(state)

        {depth, _seq} = key ->
          if depth + 2 >= :atomics.get(state.ctx.best, 1) do
            # Ordered by depth: everything left is at least as deep.
            :ets.delete_all_objects(state.ctx.frontier)
            maybe_finish(state)
          else
            case :ets.take(state.ctx.frontier, key) do
              [{^key, url, canon}] -> state |> spawn_fetch({url, canon, depth, 1}) |> dispatch()
              [] -> dispatch(state)
            end
          end
      end
    end
  end

  defp spawn_fetch(state, {url, canon, depth, _attempt} = job) do
    ctx = state.ctx
    task = Task.Supervisor.async_nolink(state.tasks, fn -> crawl(ctx, url, canon, depth) end)
    :ets.update_element(state.status, :status, {2, url})
    %{state | inflight: Map.put(state.inflight, task.ref, job)}
  end

  defp retry(state, {url, canon, depth, attempt}) when attempt < @max_attempts do
    spawn_fetch(state, {url, canon, depth, attempt + 1})
  end

  defp retry(state, _job), do: state

  ## Work done inside each task

  @doc false
  def crawl(ctx, url, canon, depth) do
    case Fetcher.get(url, receive_timeout: ctx.receive_timeout) do
      {:ok, body} ->
        :counters.add(ctx.counters, 1, 1)
        links = Links.extract(body, url)
        target = ctx.target_canon

        if Enum.any?(links, fn {_u, c} -> c == target end) do
          send(ctx.race, {:found, canon})
        end

        child_depth = depth + 1

        if child_depth + 2 < :atomics.get(ctx.best, 1) do
          new =
            for {u, c} <- links,
                c != target,
                :ets.insert_new(ctx.visited, {c, canon, u, child_depth}),
                do: {{child_depth, :erlang.unique_integer([:monotonic, :positive])}, u, c}

          :ets.insert(ctx.frontier, new)
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Results

  defp found(state, parent_canon) do
    path = Path.to_target(state.ctx.visited, parent_canon, state.start_url, state.target_url)
    best = :atomics.get(state.ctx.best, 1)

    if path != [] and length(path) < best and
         Path.valid_shape?(path, state.start_url, state.target_url) do
      WikiRace.Harness.report(path)
      :atomics.put(state.ctx.best, 1, length(path))
      :ets.update_element(state.status, :status, [{3, path}, {4, :found}])

      Logger.info(
        "[race] path of #{length(path)} articles after " <>
          "#{System.monotonic_time(:millisecond) - state.started_at} ms: " <>
          Enum.map_join(path, " -> ", &URL.title/1)
      )

      %{state | best_path: path}
    else
      state
    end
  end

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
