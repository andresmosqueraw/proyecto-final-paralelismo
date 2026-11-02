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

  # The lead bonus did not help (fase3_hallazgos.md). depth 1.5 looked better
  # on 60 cases (fase4), but on all 240 cases with arrival-time timestamps
  # depth 1.0 halves the very_hard p90 and wins the simulated matches, at a
  # small cost in path length (fase6_hallazgos.md).
  @default %{out: 2.0, title: 1.5, rel: 2.0, lead: 0.0, depth: 1.0}
  @lead_links 40
  @rel_scale 5.0

  @stopwords ~w(the of and in on at to for a an by with from as is de la le el los las du des
                der die das und list lists)

  @doc "Default weights, or `:bfs` for depth-only ordering."
  def weights(:bfs), do: %{out: 0.0, title: 0.0, rel: 0.0, lead: 0.0, depth: 1.0}
  def weights(:default), do: @default
  def weights(%{} = w), do: Map.merge(@default, w)

  # A plain list: a compiled pattern is a reference and cannot be a module attribute.
  @separators ~w(_ \( \) , . - – — ' " : ; / ! ? & + ’) ++ [" "]

  @doc """
  Lowercase word tokens of the title of a **canonical** (already decoded) URL.
  Plain binary splitting: this runs for every link of every page.
  """
  @spec tokens(String.t()) :: [String.t()]
  def tokens(canon) do
    canon
    |> last_segment()
    |> String.downcase()
    |> :binary.split(@separators, [:global, :trim_all])
    |> Enum.reject(&(byte_size(&1) < 2 or &1 in @stopwords))
    |> Enum.uniq()
  end

  defp last_segment(path) do
    case :binary.matches(path, "/") do
      [] ->
        path

      ms ->
        {pos, 1} = List.last(ms)
        binary_part(path, pos + 1, byte_size(path) - pos - 1)
    end
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
    prefilter = if w.title != 0.0, do: prefilter(target_tokens)

    links
    |> Enum.with_index()
    |> Enum.map(fn {{u, c}, i} ->
      s =
        base +
          if(in_target_out?.(c), do: w.out, else: 0.0) +
          title_score(prefilter, c, target_tokens, w.title) +
          if(i < @lead_links, do: w.lead, else: 0.0)

      {u, c, s}
    end)
  end

  # Tokenizing every link is the costly part, and almost no link shares a
  # word with the target: a case-insensitive substring check skips those
  # (a match only means "tokenize and check properly").
  defp prefilter(%MapSet{map: m}) when map_size(m) == 0, do: nil

  defp prefilter(target_tokens) do
    alternatives = target_tokens |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    Regex.compile!(alternatives, "iu")
  end

  defp title_score(nil, _c, _target_tokens, _w), do: 0.0

  defp title_score(re, c, target_tokens, w) do
    if Regex.match?(re, last_segment(c)),
      do: w * title_overlap(tokens(c), target_tokens),
      else: 0.0
  end
end
