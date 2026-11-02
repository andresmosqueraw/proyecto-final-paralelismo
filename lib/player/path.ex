defmodule Player.Path do
  @moduledoc """
  Builds and checks the paths we report.

  A wrong report costs -1.0 for the race, so nothing is reported unless
  `valid_shape?/3` holds. Hops are correct by construction: a node is only
  stored in the visited table with the parent page whose links contained it.
  """

  alias Player.URL

  @doc """
  Walks the visited table back from `canon` to the start and returns the list
  of URLs (start first). Rows are `{canonical, parent_canonical | nil, url, depth}`.
  """
  @spec reconstruct(:ets.tid(), String.t()) :: [String.t()]
  def reconstruct(visited, canon), do: walk(visited, canon, [], 0)

  defp walk(_visited, nil, acc, _n), do: acc
  # A cycle cannot happen (every node is inserted once, after its parent), but
  # never loop forever on a bug.
  defp walk(_visited, _canon, _acc, n) when n > 1_000, do: []

  defp walk(visited, canon, acc, n) do
    case :ets.lookup(visited, canon) do
      [{^canon, parent, url, _depth}] -> walk(visited, parent, [url | acc], n + 1)
      [] -> []
    end
  end

  @doc """
  Full path ending in the target: the start URL and the target URL are the exact
  strings `start/2` received, as the verifier compares against them.
  """
  @spec to_target(:ets.tid(), String.t(), String.t(), String.t()) :: [String.t()]
  def to_target(visited, parent_canon, start_url, target_url) do
    case reconstruct(visited, parent_canon) do
      [] -> []
      [_start | rest] -> [start_url | rest] ++ [target_url]
    end
  end

  @doc "Same structural checks as the platform verifier's `check_shape/3`."
  @spec valid_shape?([String.t()], String.t(), String.t()) :: boolean()
  def valid_shape?(path, start_url, target_url) do
    is_list(path) and path != [] and Enum.all?(path, &is_binary/1) and
      URL.canonical(List.first(path)) == URL.canonical(start_url) and
      URL.canonical(List.last(path)) == URL.canonical(target_url) and
      length(path) >= 2 and
      no_duplicates?(path)
  end

  defp no_duplicates?(path) do
    canon = Enum.map(path, &URL.canonical/1)
    length(Enum.uniq(canon)) == length(canon)
  end
end
