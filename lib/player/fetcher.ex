defmodule Player.Fetcher do
  @moduledoc """
  Downloads one Kiwix page with `Req`, over the application's own Finch pool
  (`Player.Finch`), so many fetches can be in flight at once.
  """

  @finch Player.Finch

  @doc "Finch child spec used by `Player.Application`."
  def child_spec(_opts) do
    Finch.child_spec(name: @finch, pools: %{default: [size: 256, count: 1]})
  end

  @doc "GETs `url` (following redirects). Returns `{:ok, body}` or `{:error, reason}`."
  @spec get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def get(url, opts \\ []) do
    timeout = Keyword.get(opts, :receive_timeout, 5_000)

    case Req.get(url,
           finch: [name: @finch, pool_timeout: timeout],
           retry: false,
           receive_timeout: timeout,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
