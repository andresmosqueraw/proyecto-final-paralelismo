defmodule Player.Crawler do
  @moduledoc """
  Our `WikiRace.Crawler`.

  `start/2` only starts a `Player.Race` under `Player.RaceSupervisor` and
  returns its pid; the crawl runs in that process tree. `status/1` reads the
  race's ETS tables and never messages the race, so it answers in microseconds
  even under full load.
  """

  @behaviour WikiRace.Crawler

  alias WikiRace.Status

  @impl WikiRace.Crawler
  def start(start_url, target_url), do: start(start_url, target_url, [])

  @doc """
  Same as `start/2` with options, for tests and benchmarks:
  `:concurrency`, `:receive_timeout`, `:lifetime_ms`.
  """
  def start(start_url, target_url, opts) do
    case DynamicSupervisor.start_child(
           Player.RaceSupervisor,
           {Player.Race, {start_url, target_url, opts}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @impl WikiRace.Crawler
  def status(pid) do
    with %{status: status, counters: counters, frontier: frontier} <- Player.Registry.lookup(pid),
         [{:status, current_url, path, state}] <- :ets.lookup(status, :status),
         size when is_integer(size) <- :ets.info(frontier, :size) do
      Status.new(
        current_url: current_url,
        frontier_size: size,
        visited_count: :counters.get(counters, 1),
        path: path,
        state: state
      )
    else
      _ -> Status.new()
    end
  rescue
    ArgumentError -> Status.new()
  end
end
