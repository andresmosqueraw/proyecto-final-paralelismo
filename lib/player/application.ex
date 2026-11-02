defmodule Player.Application do
  @moduledoc """
  Starts the application.

      Player.Supervisor (one_for_one)
      ├── Player.Registry        race pid -> ETS tables, read by status/1
      ├── Player.Finch           HTTP connection pool used by Player.Fetcher
      └── Player.RaceSupervisor  DynamicSupervisor, one Player.Race per start/2
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Player.Registry,
      Player.Fetcher,
      {DynamicSupervisor, name: Player.RaceSupervisor, strategy: :one_for_one}
    ]

    with {:ok, sup} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Player.Supervisor) do
      warm_up()
      {:ok, sup}
    end
  end

  # Load the modules used during a race now, so the first start/2 and status/1
  # calls of a race do not pay for code loading.
  defp warm_up do
    for mod <- [
          Player.Crawler,
          Player.Race,
          Player.Links,
          Player.URL,
          Player.Path,
          Player.Fetcher,
          WikiRace.Status,
          WikiRace.Harness,
          Req,
          Req.Request,
          Req.Response,
          Req.Steps,
          Req.Finch,
          Finch,
          Mint.HTTP1,
          Regex,
          URI
        ],
        do: Code.ensure_loaded(mod)

    Player.Crawler.status(self())
    Player.Links.extract(~s(<a href="A">a</a>), "http://localhost/content/b/X")
    :ok
  end
end
