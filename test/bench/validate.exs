# Does the heuristic score predict closeness to the target? (Wilt & Ruml 12)
#
#   mix run --no-start test/bench/validate.exs TRACE.tsv
#
# TRACE.tsv comes from `run.exs --trace`: one row per fetched page (depth >= 1)
# with its score and whether it links to the target, i.e. d* = 1 (links) or
# d* >= 2 (does not). Per case it computes:
#
#   * Spearman rho between score and -d*  (ties get average ranks)
#   * AUC: probability that a page with d* = 1 outscores one with d* >= 2
#
# and prints the median over cases with both kinds of pages. Caveat: only pages
# the crawler chose to fetch are in the trace, so this measures the ranking
# among candidates that already scored well enough to be fetched.

defmodule Validate do
  def ranks(xs) do
    xs
    |> Enum.with_index()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.reduce({%{}, 1}, fn group, {acc, next} ->
      n = length(group)
      avg = next + (n - 1) / 2
      {Enum.reduce(group, acc, fn {_x, i}, a -> Map.put(a, i, avg) end), next + n}
    end)
    |> elem(0)
    |> then(fn m -> Enum.map(0..(length(xs) - 1), &m[&1]) end)
  end

  def pearson(xs, ys) do
    n = length(xs)
    mx = Enum.sum(xs) / n
    my = Enum.sum(ys) / n
    cov = Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> (x - mx) * (y - my) end) |> Enum.sum()
    sx = xs |> Enum.map(&((&1 - mx) ** 2)) |> Enum.sum() |> :math.sqrt()
    sy = ys |> Enum.map(&((&1 - my) ** 2)) |> Enum.sum() |> :math.sqrt()
    if sx == 0 or sy == 0, do: nil, else: cov / (sx * sy)
  end

  def spearman(xs, ys), do: pearson(ranks(xs), ranks(ys))

  def auc(scores, labels) do
    r = ranks(scores)
    pos = Enum.zip(r, labels) |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
    n_pos = length(pos)
    n_neg = length(labels) - n_pos

    if n_pos == 0 or n_neg == 0,
      do: nil,
      else: (Enum.sum(pos) - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)
  end

  # With a binary d* and a share p of positives, even a perfect ranking only
  # reaches rho = sqrt(3 p (1 - p)), so rho is also reported relative to that.
  def norm_rho(nil, _p), do: nil
  def norm_rho(_rho, p) when p <= 0 or p >= 1, do: nil
  def norm_rho(rho, p), do: rho / :math.sqrt(3 * p * (1 - p))

  def median([]), do: nil
  def median(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))

  def main([file]) do
    [_ | lines] = file |> File.read!() |> String.split("\n", trim: true)

    rows =
      for l <- lines do
        [level, s, t, d, score, hit] = String.split(l, "\t")

        %{
          level: level,
          case: {s, t},
          depth: String.to_integer(d),
          score: elem(Float.parse(score), 0),
          hit: hit == "true"
        }
      end

    per_case =
      rows
      |> Enum.group_by(& &1.case)
      |> Enum.map(fn {{s, t}, rs} ->
        scores = Enum.map(rs, & &1.score)
        labels = Enum.map(rs, & &1.hit)
        dneg = Enum.map(labels, &if(&1, do: -1.0, else: -2.0))

        %{
          case: "#{s} -> #{t}",
          level: hd(rs).level,
          n: length(rs),
          hits: Enum.count(labels, & &1),
          rho: spearman(scores, dneg),
          rho_norm: norm_rho(spearman(scores, dneg), Enum.count(labels, & &1) / length(labels)),
          auc: auc(scores, labels)
        }
      end)
      |> Enum.filter(&(&1.rho != nil and &1.auc != nil))

    f = fn
      nil -> "-"
      x -> :erlang.float_to_binary(x * 1.0, decimals: 2)
    end

    IO.puts("""
    ## Validación de la heurística (#{Path.basename(file)})

    #{length(per_case)} casos con páginas de ambos tipos (enlaza al destino / no).

    | nivel | casos | páginas (mediana) | con enlace al destino (mediana) | Spearman ρ(score, −d*) mediana | ρ / ρ_máx mediana | AUC mediana |
    |---|---|---|---|---|---|---|\
    """)

    groups = Enum.group_by(per_case, & &1.level)

    for {l, cs} <-
          Enum.sort_by(groups, fn {l, _} ->
            Enum.find_index(~w(easy medium hard very_hard), &(&1 == l)) || 9
          end) ++
            [{"**total**", per_case}] do
      IO.puts(
        "| #{l} | #{length(cs)} | #{median(Enum.map(cs, & &1.n))} | #{median(Enum.map(cs, & &1.hits))} | " <>
          "#{f.(median(Enum.map(cs, & &1.rho)))} | " <>
          "#{f.(median(cs |> Enum.map(& &1.rho_norm) |> Enum.reject(&is_nil/1)))} | " <>
          "#{f.(median(Enum.map(cs, & &1.auc)))} |"
      )
    end
  end
end

Validate.main(System.argv())
