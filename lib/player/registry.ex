defmodule Player.Registry do
  @moduledoc """
  Maps a race pid to the ETS tables that hold its progress, so `status/1` can
  read them without messaging the race.

  This process only owns the public table `:player_races` and removes a race's
  row when the race process dies.
  """

  use GenServer

  @table :player_races

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Called by a race from its own process during `init/1`."
  @spec register(map()) :: :ok
  def register(info) when is_map(info), do: GenServer.call(__MODULE__, {:register, self(), info})

  @doc "Lock-free lookup. Returns the map given to `register/1` or `nil`."
  @spec lookup(pid()) :: map() | nil
  def lookup(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, info}] -> info
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:register, pid, info}, _from, state) do
    Process.monitor(pid)
    :ets.insert(@table, {pid, info})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.delete(@table, pid)
    {:noreply, state}
  end
end
