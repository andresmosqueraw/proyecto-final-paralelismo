defmodule FakeKiwix do
  @moduledoc """
  A tiny HTTP/1.1 server for tests: serves a fixed set of pages under
  `/content/book/` with keep-alive, so races run on a known graph.

      base = FakeKiwix.start(%{
        "A" => {:page, ["B", "C"]},          # links, as hrefs
        "Alias" => {:redirect, "A"},         # 302 to /content/book/A
        "Raw" => {:html, "<html>...</html>"}
      })

  Unknown paths answer 404.
  """

  def start(pages) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    owner = self()

    pid =
      spawn(fn ->
        send(owner, :ready)
        accept(listen, pages)
      end)

    receive do
      :ready -> :ok
    end

    # Keep the listener alive for the test, close it afterwards.
    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    "http://127.0.0.1:#{port}/content/book/"
  end

  defp accept(listen, pages) do
    {:ok, sock} = :gen_tcp.accept(listen)
    handler = spawn(fn -> serve(sock, pages, "") end)
    :gen_tcp.controlling_process(sock, handler)
    accept(listen, pages)
  end

  defp serve(sock, pages, buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        [request_line | _] = String.split(head, "\r\n")
        [_method, path | _] = String.split(request_line, " ")
        :gen_tcp.send(sock, respond(path, pages))
        serve(sock, pages, rest)

      [_incomplete] ->
        case :gen_tcp.recv(sock, 0, 30_000) do
          {:ok, data} -> serve(sock, pages, buf <> data)
          {:error, _} -> :gen_tcp.close(sock)
        end
    end
  end

  defp respond("/content/book/" <> name, pages) do
    case Map.get(pages, name) do
      {:page, hrefs} -> ok(html(name, hrefs))
      {:html, body} -> ok(body)
      {:redirect, to} -> reply("302 Found", "", [{"location", "/content/book/" <> to}])
      nil -> reply("404 Not Found", "not found", [])
    end
  end

  defp respond(_path, _pages), do: reply("404 Not Found", "not found", [])

  # Looks like a Kiwix page: a stylesheet, a fragment link, an external link,
  # then the article links.
  def html(name, hrefs) do
    links = Enum.map_join(hrefs, "\n", &~s(<p><a href="#{&1}" title="t">#{&1}</a></p>))

    """
    <!DOCTYPE html><html><head><title>#{name}</title>
    <link rel="stylesheet" href="./_mw_/site.css"></head><body>
    <a href="#top">top</a> <a href="https://example.org/">ext</a>
    #{links}
    </body></html>
    """
  end

  defp ok(body), do: reply("200 OK", body, [{"content-type", "text/html; charset=utf-8"}])

  defp reply(status, body, headers) do
    hs = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)
    "HTTP/1.1 #{status}\r\n#{hs}content-length: #{byte_size(body)}\r\n\r\n#{body}"
  end
end

defmodule VerifierCopy do
  @moduledoc "The platform verifier's checks (shape + one fetch per hop), for tests."

  alias Player.URL

  def verify(path, start, target) do
    if Player.Path.valid_shape?(path, start, target) do
      path
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(:ok, fn [from, to] ->
        {:ok, %{status: 200, body: body}} = Req.get(from, retry: false)
        {:ok, doc} = Floki.parse_document(body)

        links =
          doc
          |> Floki.attribute("a", "href")
          |> Enum.reject(&String.starts_with?(&1, ["#", "javascript:", "mailto:"]))
          |> Enum.flat_map(fn href ->
            try do
              [from |> URI.merge(href) |> URI.to_string() |> URL.canonical()]
            rescue
              _ -> []
            end
          end)
          |> MapSet.new()

        if MapSet.member?(links, URL.canonical(to)), do: nil, else: {:error, {from, to}}
      end)
    else
      {:error, :shape}
    end
  end
end
