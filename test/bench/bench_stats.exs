# Shared by test/bench/run.exs and test/bench/compare.exs: reads the TSV the
# benchmark writes and builds the per-level summary.

defmodule BenchStats do
  @columns ~w(level start target dist_2007 found t_first_ms t_best_ms articles reports
              invalid complete opt_ref hops_ratio fetched errors status_max_us utilization
              report_log)
  @levels ~w(easy medium hard very_hard)

  def columns, do: @columns

  def to_line(row), do: Enum.map_join(@columns, "\t", &to_string(Map.fetch!(row, &1)))
  def header, do: Enum.join(@columns, "\t")

  def read(path) do
    [header | lines] = path |> File.read!() |> String.split("\n", trim: true)
    keys = String.split(header, "\t")

    for line <- lines do
      keys |> Enum.zip(String.split(line, "\t")) |> Map.new(fn {k, v} -> {k, parse(v)} end)
    end
  end

  # report_log ("t_ms:articles;t_ms:articles") is not a number, so it stays a string.
  defp parse("true"), do: true
  defp parse("false"), do: false
  defp parse(""), do: nil

  defp parse(v) do
    case Integer.parse(v) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(v) do
          {f, ""} -> f
          _ -> v
        end
    end
  end

  ## Statistics

  def median([]), do: nil
  def median(xs), do: percentile(xs, 50)

  def percentile([], _), do: nil

  def percentile(xs, p) do
    s = Enum.sort(xs)
    Enum.at(s, min(length(s) - 1, div(length(s) * p, 100)))
  end

  def mean([]), do: nil
  def mean(xs), do: Enum.sum(xs) / length(xs)

  defp vals(rows, key), do: rows |> Enum.map(& &1[key]) |> Enum.reject(&is_nil/1)

  def stats(rows) do
    found = Enum.filter(rows, & &1["found"])

    %{
      n: length(rows),
      found: length(found),
      found_pct: pct(length(found), length(rows)),
      invalid: rows |> vals("invalid") |> Enum.sum(),
      t_first_med: found |> vals("t_first_ms") |> median(),
      t_first_p90: found |> vals("t_first_ms") |> percentile(90),
      t_best_med: found |> vals("t_best_ms") |> median(),
      hops_ratio: found |> vals("hops_ratio") |> mean(),
      complete_pct: pct(Enum.count(rows, & &1["complete"]), length(rows)),
      util: rows |> vals("utilization") |> mean(),
      fetched_med: rows |> vals("fetched") |> median(),
      errors: rows |> vals("errors") |> Enum.sum(),
      status_max: rows |> vals("status_max_us") |> Enum.max(fn -> 0 end)
    }
  end

  defp pct(_, 0), do: 0.0
  defp pct(a, b), do: Float.round(100 * a / b, 1)

  def by_level(rows) do
    levels = rows |> Enum.map(& &1["level"]) |> Enum.uniq()
    ordered = Enum.filter(@levels, &(&1 in levels)) ++ (levels -- @levels)
    for l <- ordered, do: {l, stats(Enum.filter(rows, &(&1["level"] == l)))}
  end

  def fmt(nil), do: "-"
  def fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  def fmt(x), do: to_string(x)

  def summary_markdown(rows, title) do
    head =
      "| nivel | n | found | % found | inválidos | t_primer mediana (ms) | t_primer p90 (ms) | " <>
        "t_mejor mediana (ms) | hops óptimo/nuestro | % BFS completo | utilización | " <>
        "fetches mediana | errores fetch | status/1 máx (µs) |\n" <>
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"

    lines =
      for {label, s} <- by_level(rows) ++ [{"**total**", stats(rows)}] do
        "| #{label} | #{s.n} | #{s.found} | #{fmt(s.found_pct)} | #{s.invalid} | " <>
          "#{fmt(s.t_first_med)} | #{fmt(s.t_first_p90)} | #{fmt(s.t_best_med)} | " <>
          "#{fmt(s.hops_ratio)} | #{fmt(s.complete_pct)} | #{fmt(s.util)} | " <>
          "#{fmt(s.fetched_med)} | #{s.errors} | #{s.status_max} |\n"
      end

    "## #{title}\n\n" <> head <> Enum.join(lines)
  end
end
