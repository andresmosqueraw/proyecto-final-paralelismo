defmodule Player.URL do
  @moduledoc """
  URL helpers that mirror the platform verifier exactly.

  `canonical/1` is a copy of `WikiRacePlatform.Race.Verifier.canonical/1`: two
  URLs are "the same article" for the verifier if and only if their canonical
  forms are equal, so every dedupe and target check uses it.
  """

  @doc "Canonical form used by the verifier (scheme, host, port, decoded path; no query, no fragment, no trailing slash)."
  @spec canonical(String.t()) :: String.t()
  def canonical(url) do
    uri = URI.parse(url)
    path = uri.path |> to_string() |> URI.decode() |> String.trim_trailing("/")
    "#{uri.scheme}://#{uri.host}#{port(uri)}#{path}"
  end

  defp port(%URI{scheme: "http", port: 80}), do: ""
  defp port(%URI{scheme: "https", port: 443}), do: ""
  defp port(%URI{port: nil}), do: ""
  defp port(%URI{port: port}), do: ":#{port}"

  @doc """
  Resolves an article `href` found in the page at `base`.

  Returns `{url, canonical}` where `url` is `URI.merge(base, href)` without the
  fragment (the exact string we put in a reported path and fetch), or `nil` if
  the href is not a link to another article.
  """
  @spec resolve(String.t(), String.t()) :: {String.t(), String.t()} | nil
  def resolve(base, href) do
    if article_href?(href) do
      href = strip_fragment(href)

      url = base |> URI.merge(href) |> URI.to_string()
      {url, canonical(url)}
    end
  rescue
    _ -> nil
  end

  @doc """
  True for hrefs that point to another article in the same Kiwix book.

  Kiwix writes article links as bare relative names (`Bengal_tiger`,
  `Alien%3A_Resurrection`). Everything else is a fragment, a static resource
  (`./_mw_/…`, `../-/…`), an absolute path or an external URL.
  """
  @spec article_href?(String.t()) :: boolean()
  def article_href?(""), do: false
  def article_href?("#" <> _), do: false
  def article_href?("." <> _), do: false
  def article_href?("/" <> _), do: false

  def article_href?(href) do
    not String.contains?(href, [":", "?", "\\"]) and not String.starts_with?(href, "#")
  end

  defp strip_fragment(href) do
    case :binary.split(href, "#") do
      [h, _] -> h
      [h] -> h
    end
  end

  @doc "Short, human readable title of an article URL (for logs and the dashboard)."
  @spec title(String.t()) :: String.t()
  def title(url) do
    url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename() |> URI.decode()
  end
end
