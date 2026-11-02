# Compares two benchmark runs case by case (only cases present in both).
#
#   mix run --no-start test/bench/compare.exs BASELINE.tsv NEW.tsv
#
# Prints, per level: % found, median time to first path, median of the
# per-case ratio new/baseline for that time, hops ratio and utilization.

Code.require_file("bench_stats.exs", __DIR__)

[base_file, new_file] = System.argv()
key = fn r -> {r["start"], r["target"]} end
base = base_file |> BenchStats.read() |> Map.new(&{key.(&1), &1})
new = new_file |> BenchStats.read() |> Enum.filter(&Map.has_key?(base, key.(&1)))

f = &BenchStats.fmt/1

change = fn
  nil, _ -> "-"
  _, nil -> "-"
  0, _ -> "-"
  a, b -> "#{if b <= a, do: "", else: "+"}#{f.(100 * (b - a) / a)}%"
end

IO.puts("""
## #{Path.basename(base_file)} → #{Path.basename(new_file)} (#{length(new)} casos en común)

| nivel | n | % found base → nuevo | inválidos nuevo | t_primer mediana base → nuevo (ms) | cambio | mediana por caso nuevo/base | hops ratio base → nuevo | utilización base → nuevo |
|---|---|---|---|---|---|---|---|---|\
""")

levels =
  BenchStats.by_level(new) |> Enum.map(&elem(&1, 0))

for l <- levels ++ [:total] do
  n_rows = if l == :total, do: new, else: Enum.filter(new, &(&1["level"] == l))
  b_rows = Enum.map(n_rows, &base[key.(&1)])
  b = BenchStats.stats(b_rows)
  n = BenchStats.stats(n_rows)

  per_case =
    Enum.zip(b_rows, n_rows)
    |> Enum.filter(fn {x, y} -> x["found"] && y["found"] && x["t_first_ms"] > 0 end)
    |> Enum.map(fn {x, y} -> y["t_first_ms"] / x["t_first_ms"] end)
    |> BenchStats.median()

  IO.puts(
    "| #{if l == :total, do: "**total**", else: l} | #{n.n} | #{f.(b.found_pct)} → #{f.(n.found_pct)} | " <>
      "#{n.invalid} | #{f.(b.t_first_med)} → #{f.(n.t_first_med)} | #{change.(b.t_first_med, n.t_first_med)} | " <>
      "#{f.(per_case)} | #{f.(b.hops_ratio)} → #{f.(n.hops_ratio)} | #{f.(b.util)} → #{f.(n.util)} |"
  )
end
