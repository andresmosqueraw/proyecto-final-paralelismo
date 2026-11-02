defmodule Player.Heuristic do
  @moduledoc """
  Priority of a link in the frontier (higher is fetched first).

  For a link `c` found on page `p`, about to sit at depth `d`:

      score = w_out   * [c is linked from the target page]          (reciprocity, Zlatić 06)
            + w_title * overlap(tokens(c), tokens(target))          (Ebrahimi 25, Zaheer 22)
            + w_rel   * rel(p)                                       (soft focus, Chakrabarti 99;
                                                                      link overlap, Milne & Witten 08)
            + w_lead  * [c is among the first article links of p]   (Dimitrov 17)
            - w_depth * d                                            (keeps paths short)

  `rel(p)` is the cosine between the article links of `p` and those of the
  target page, scaled to [0, 1]. It is computed once per fetched page and
  shared by all its children, so children of pages "about" the target's topic
  go first. Before any of this, a page that links to the target is reported
  immediately (that check is in `Player.Race`).

  With every weight at 0 except `depth` the frontier is ordered by depth, i.e.
  plain BFS (`weights(:bfs)`), which is what the baseline measured.
  """

  # Chosen on 60 cases: the lead bonus did not help (fase3_hallazgos.md), and
  # depth 1.5 makes the first path optimal more often than 1.0 at the same
  # median time, while 2.0 is slower (fase4_hallazgos.md).
  @default %{out: 2.0, title: 1.5, rel: 2.0, lead: 0.0, depth: 1.5}
  @lead_links 40
  @rel_scale 5.0

  @stopwords ~w(the of and in on at to for a an by with from as is de la le el los las du des
                der die das und list lists)

  @doc "Default weights, or `:bfs` for depth-only ordering."
  def weights(:bfs), do: %{out: 0.0, title: 0.0, rel: 0.0, lead: 0.0, depth: 1.0}
  def weights(:default), do: @default
  def weights(%{} = w), do: Map.merge(@default, w)

  @doc "Lowercase word tokens of an article title (from a URL or canonical URL)."
  @spec tokens(String.t()) :: [String.t()]
  def tokens(url) do
    url
    |> Player.URL.title()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 2))
    |> Enum.uniq()
  end

  @doc "Share of the target's title tokens that also appear in `tokens`."
  @spec title_overlap([String.t()], MapSet.t()) :: float()
  def title_overlap(_tokens, %MapSet{map: m}) when map_size(m) == 0, do: 0.0

  def title_overlap(tokens, target_tokens) do
    hits = Enum.count(tokens, &MapSet.member?(target_tokens, &1))
    min(1.0, hits / MapSet.size(target_tokens))
  end

  @doc """
  Relatedness of a fetched page to the target, in [0, 1]: cosine between the
  page's links and the target's links, times #{@rel_scale}, capped at 1.
  """
  @spec rel(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: float()
  def rel(_shared, 0, _target_n), do: 0.0
  def rel(_shared, _page_n, 0), do: 0.0

  def rel(shared, page_n, target_n) do
    min(1.0, @rel_scale * shared / :math.sqrt(page_n * target_n))
  end

  @doc """
  Scores the links of a fetched page. `in_target_out?` tells whether a link's
  canonical URL is linked from the target page. Returns `[{url, canon, score}]`.
  """
  def score_links(links, child_depth, rel_p, in_target_out?, target_tokens, w) do
    base = w.rel * rel_p - w.depth * child_depth
    text? = w.title != 0.0

    links
    |> Enum.with_index()
    |> Enum.map(fn {{u, c}, i} ->
      s =
        base +
          if(in_target_out?.(c), do: w.out, else: 0.0) +
          if(text?, do: w.title * title_overlap(tokens(c), target_tokens), else: 0.0) +
          if(i < @lead_links, do: w.lead, else: 0.0)

      {u, c, s}
    end)
  end
end
