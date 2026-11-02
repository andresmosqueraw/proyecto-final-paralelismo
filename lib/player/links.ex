defmodule Player.Links do
  @moduledoc """
  Extracts article links from a Kiwix page.

  Uses a regex over `<a … href="…">` instead of `Floki.parse_document/1`: on a
  1.3 MB page (United_States) Floki takes ~460 ms and the regex ~15 ms, and both
  return the same 5,499 hrefs. The only difference is HTML entities in the
  attribute, which `decode_entities/1` undoes the way Floki does.
  """

  alias Player.URL

  @href ~r/<a\s[^>]*?href=(?:"([^"]*)"|'([^']*)')/is

  @doc """
  Returns the unique article links of `body`, resolved against `base`, as
  `[{url, canonical}]` in page order. The page itself is excluded.
  """
  @spec extract(binary(), String.t()) :: [{String.t(), String.t()}]
  def extract(body, base) do
    self_canon = URL.canonical(base)
    resolve = URL.resolver(base)

    @href
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.reduce({[], MapSet.new([self_canon])}, fn groups, {acc, seen} ->
      href = groups |> Enum.find("", &(&1 != "")) |> decode_entities()

      case resolve.(href) do
        {_url, canon} = link ->
          if MapSet.member?(seen, canon),
            do: {acc, seen},
            else: {[link | acc], MapSet.put(seen, canon)}

        nil ->
          {acc, seen}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "Decodes the HTML entities that can appear in an attribute value."
  @spec decode_entities(String.t()) :: String.t()
  def decode_entities(s) do
    if String.contains?(s, "&") do
      Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt);/, s, fn
        _, "amp" -> "&"
        _, "quot" -> "\""
        _, "apos" -> "'"
        _, "lt" -> "<"
        _, "gt" -> ">"
        _, "#x" <> hex -> <<String.to_integer(hex, 16)::utf8>>
        _, "#" <> dec -> <<String.to_integer(dec)::utf8>>
      end)
    else
      s
    end
  end
end
