# Simulates head-to-head races between two benchmark runs, case by case, with
# the platform's rules (platform/lib/wiki_race_platform/race/{instance,player,result}.ex):
#
#   * a report is verified `--verify-ms` after it arrives (default 300 ms);
#   * a player settles when its first path is verified, and the race ends when
#     both have settled (or at the time limit): later reports do not count;
#   * the harness keeps each player's shortest verified path with the arrival
#     time of the report that sent it;
#   * score = 0.40 found + 0.15 first + 0.20 * shortest_len / len
#             + 0.15 * fastest_time / time + 0.10 * utilization.
#
#   mix run --no-start test/bench/match.exs A.tsv B.tsv [--verify-ms 300] [--limit-ms 120000]
#
# Uses the report_log column; for older runs without it, the reports are
# rebuilt from t_first/t_best/articles (first path assumed one article longer).

Code.require_file("bench_stats.exs", __DIR__)

defmodule Match do
  def reports(%{"report_log" => log}) when is_binary(log) and log != "" do
    for r <- String.split(log, ";") do
      [t, l] = String.split(r, ":")
      {String.to_integer(t), String.to_integer(l)}
    end
  end

  def reports(%{"found" => true} = r) do
    if r["t_first_ms"] == r["t_best_ms"],
      do: [{r["t_first_ms"], r["articles"]}],
      else: [{r["t_first_ms"], r["articles"] + 1}, {r["t_best_ms"], r["articles"]}]
  end

  def reports(_), do: []

  defp settle([], _v, limit), do: limit
  defp settle([{t, _} | _], v, _limit), do: t + v

  # Shortest path verified before the race ends, with its arrival time.
  defp kept(reports, v, race_end) do
    reports
    |> Enum.filter(fn {t, _} -> t + v <= race_end end)
    |> Enum.reduce(nil, fn
      {t, l}, nil -> {t, l, t}
      {t, l}, {_bt, bl, first} when l < bl -> {t, l, first}
      _, acc -> acc
    end)
  end

  def race(a, b, v, limit) do
    ra = reports(a)
    rb = reports(b)
    race_end = min(limit, max(settle(ra, v, limit), settle(rb, v, limit)))
    ka = kept(ra, v, race_end)
    kb = kept(rb, v, race_end)
    fin = Enum.reject([ka, kb], &is_nil/1)
    best_len = fin |> Enum.map(&elem(&1, 1)) |> Enum.min(fn -> nil end)
    best_t = fin |> Enum.map(&elem(&1, 0)) |> Enum.min(fn -> nil end)
    first_t = fin |> Enum.map(&elem(&1, 2)) |> Enum.min(fn -> nil end)

    score = fn
      nil, row ->
        %{total: 0.10 * (row["utilization"] || 0.0), found: 0.0, first: 0.0, hops: 0.0, time: 0.0}

      {t, l, first}, row ->
        parts = %{
          found: 0.40,
          first: if(first == first_t, do: 0.15, else: 0.0),
          hops: 0.20 * best_len / l,
          time: 0.15 * best_t / max(t, 1)
        }

        Map.put(parts, :total, Enum.sum(Map.values(parts)) + 0.10 * (row["utilization"] || 0.0))
    end

    {score.(ka, a), score.(kb, b)}
  end

  def main(args) do
    {opts, [fa, fb], _} =
      OptionParser.parse(args, strict: [verify_ms: :integer, limit_ms: :integer])

    v = Keyword.get(opts, :verify_ms, 300)
    limit = Keyword.get(opts, :limit_ms, 120_000)
    key = fn r -> {r["start"], r["target"]} end
    b_rows = fb |> BenchStats.read() |> Map.new(&{key.(&1), &1})
    pairs = for a <- BenchStats.read(fa), b = b_rows[key.(a)], do: {a, b}

    results = for {a, b} <- pairs, do: {a["level"], race(a, b, v, limit)}
    f = &BenchStats.fmt/1
    na = Path.basename(fa, ".tsv")
    nb = Path.basename(fb, ".tsv")

    IO.puts("""
    ## Simulación #{na} (A) vs #{nb} (B): #{length(pairs)} carreras, verificación #{v} ms

    | nivel | n | score A | score B | gana A | gana B | empate | A: first / hops / time | B: first / hops / time |
    |---|---|---|---|---|---|---|---|---|\
    """)

    levels = results |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    for l <- levels ++ [:total] do
      rs = for {lv, r} <- results, l == :total or lv == l, do: r
      mean = fn side, k -> rs |> Enum.map(&Map.fetch!(elem(&1, side), k)) |> BenchStats.mean() end
      wins_a = Enum.count(rs, fn {x, y} -> x.total > y.total + 1.0e-9 end)
      wins_b = Enum.count(rs, fn {x, y} -> y.total > x.total + 1.0e-9 end)

      IO.puts(
        "| #{if l == :total, do: "**total**", else: l} | #{length(rs)} | #{f.(mean.(0, :total))} | " <>
          "#{f.(mean.(1, :total))} | #{wins_a} | #{wins_b} | #{length(rs) - wins_a - wins_b} | " <>
          "#{f.(mean.(0, :first))} / #{f.(mean.(0, :hops))} / #{f.(mean.(0, :time))} | " <>
          "#{f.(mean.(1, :first))} / #{f.(mean.(1, :hops))} / #{f.(mean.(1, :time))} |"
      )
    end
  end
end

Match.main(System.argv())
