defmodule Player.LinksTest do
  use ExUnit.Case, async: true

  alias Player.{Links, URL}

  @base "http://localhost:8080/content/wikipedia_en_all_nopic/"

  defp fixture(name) do
    Path.join([__DIR__, "..", "fixtures", name <> ".html.gz"]) |> File.read!() |> :zlib.gunzip()
  end

  # The exact link set the platform verifier builds for a page (copied logic).
  defp verifier_links(body, base) do
    {:ok, doc} = Floki.parse_document(body)

    doc
    |> Floki.attribute("a", "href")
    |> Enum.reject(&String.starts_with?(&1, ["#", "javascript:", "mailto:"]))
    |> Enum.flat_map(fn href ->
      try do
        [base |> URI.merge(href) |> URI.to_string() |> URL.canonical()]
      rescue
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  for page <- ["Tiger", "United_States"] do
    test "every link we extract from #{page} is accepted by the verifier" do
      page = unquote(page)
      body = fixture(page)
      base = @base <> page
      links = Links.extract(body, base)
      verifier = verifier_links(body, base)

      assert length(links) > 500

      for {url, canon} <- links do
        assert canon == URL.canonical(url)
        assert MapSet.member?(verifier, canon), "verifier would reject #{url}"
        assert String.starts_with?(url, @base)
        refute String.contains?(url, ["#", "?", "/_mw_/", "/_res_/"])
      end

      # Unique by canonical form, and the page itself is not a link.
      canons = Enum.map(links, &elem(&1, 1))
      assert length(Enum.uniq(canons)) == length(canons)
      refute URL.canonical(base) in canons
    end
  end

  test "Tiger: known links, fragments stripped, percent-encoding kept" do
    links = Links.extract(fixture("Tiger"), @base <> "Tiger") |> Map.new()

    assert Map.has_key?(links, @base <> "Bengal_tiger")
    assert Map.has_key?(links, @base <> "Human%E2%80%93wildlife_conflict")
    assert Map.has_key?(links, @base <> "Trapping")
    refute Enum.any?(Map.keys(links), &String.contains?(&1, "#"))
  end

  test "small hand-written page" do
    html = """
    <html><head><link href="./_mw_/site.css"></head><body>
    <a href="#cite">c</a> <a class="x" href="Bee">Bee</a> <a href='Wasp#Life'>w</a>
    <a href="https://example.org/">ext</a> <a href="./_res_/x.png">i</a>
    <a href="Alien%3A_Resurrection">a</a> <a href="Bee#again">dup</a>
    <a href="Tom_%26_Jerry">t</a> <a href="Q&amp;A">q</a> <a href="/abs">abs</a>
    </body></html>
    """

    assert Links.extract(html, @base <> "Page") |> Enum.map(&elem(&1, 0)) == [
             @base <> "Bee",
             @base <> "Wasp",
             @base <> "Alien%3A_Resurrection",
             @base <> "Tom_%26_Jerry",
             @base <> "Q&A"
           ]
  end
end
