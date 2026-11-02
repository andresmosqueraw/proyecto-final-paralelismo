# Benchmark: runs Player.Crawler on article pairs against a LOCAL Kiwix, acting
# as a fake harness, and verifies every reported path like the platform does.
#
#   mix run test/bench/run.exs CASES.exs [options]
#
#   --kiwix URL        book base URL (default http://localhost:8081/content/wikipedia_en_all_nopic/)
#   --time S           race time limit in seconds (default 120, like the tournament)
#   --filter TEXT      keep cases whose note contains TEXT (e.g. easy)
#   --per-level N      keep the first N cases of each level
#   --limit N          keep at most N cases
#   --out FILE.tsv     per-case results (default bench_results.tsv); FILE.md gets the summary
#   --concurrency N    passed to Player.Crawler.start/3
#   --label TEXT       title of the summary
#
# CASES.exs evaluates to a list of %{start: title, target: title, note: text}
# (same format as platform/priv/article_pairs.exs). The note starts with the
# level and contains dist_2007=N (distance in the 2007 Wikispeedia graph).
#
# One case runs at a time, so time and utilization are not distorted.
# Never point --kiwix at the course server: this sends thousands of requests.

Code.require_file("bench_stats.exs", __DIR__)

defmodule Bench do
  alias Player.URL

  def main(args) do
    {opts, [cases_file], _} =
      OptionParser.parse(args,
        strict: [
          filter: :string,
          per_level: :integer,
          limit: :integer,
          kiwix: :string,
          time: :integer,
          out: :string,
          concurrency: :integer,
          label: :string
        ]
      )

    kiwix = Keyword.get(opts, :kiwix, "http://localhost:8081/content/wikipedia_en_all_nopic/")
    time_s = Keyword.get(opts, :time, 120)
    out = Keyword.get(opts, :out, "bench_results.tsv")
    crawler_opts = Keyword.take(opts, [:concurrency])

    cases =
      cases_file
      |> Code.eval_file()
      |> elem(0)
      |> Enum.map(&Map.merge(&1, parse_note(&1.note)))
      |> Enum.filter(&String.contains?(&1.note, Keyword.get(opts, :filter, "")))
      |> per_level(Keyword.get(opts, :per_level))
      |> Enum.take(Keyword.get(opts, :limit, 1_000_000))

    :erlang.system_flag(:scheduler_wall_time, true)
    :yes = :global.re_register_name(WikiRace.Harness.registered_name(), self())

    File.write!(out, BenchStats.header() <> "\n")
    t0 = System.monotonic_time(:second)

    rows =
      for {c, i} <- Enum.with_index(cases, 1) do
        row = run_case(c, kiwix, time_s * 1_000, crawler_opts)
        File.write!(out, BenchStats.to_line(row) <> "\n", [:append])

        IO.puts(
          "#{i}/#{length(cases)} [#{c.level}] #{c.start} -> #{c.target}: " <>
            if(row["found"],
              do: "#{row["articles"]} articles (ref #{row["opt_ref"]}) in #{row["t_best_ms"]} ms",
              else: "NOT FOUND"
            ) <>
            " | first #{row["t_first_ms"]} ms, fetched #{row["fetched"]}, errors #{row["errors"]}, " <>
            "complete #{row["complete"]}, util #{row["utilization"]}, status max #{row["status_max_us"]} µs" <>
            if(row["invalid"] > 0, do: " | INVALID #{row["invalid"]}", else: "")
        )

        row
      end

    label =
      Keyword.get(opts, :label, Path.basename(out, ".tsv")) <>
        " (#{length(cases)} casos, límite #{time_s} s, #{System.schedulers_online()} schedulers, " <>
        "#{System.monotonic_time(:second) - t0} s en total)"

    md = BenchStats.summary_markdown(rows, label)
    File.write!(Path.rootname(out) <> ".md", md)
    IO.puts("\n" <> md)
  end

  defp parse_note(note) do
    level = note |> String.split([",", " "], parts: 2) |> hd()

    dist =
      case Regex.run(~r/dist_2007=(\d+)/, note) do
        [_, d] -> String.to_integer(d)
        _ -> nil
      end

    %{level: level, dist: dist}
  end

  defp per_level(cases, nil), do: cases

  defp per_level(cases, n) do
    {kept, _counts} =
      Enum.flat_map_reduce(cases, %{}, fn c, counts ->
        k = Map.get(counts, c.level, 0)
        if k < n, do: {[c], Map.put(counts, c.level, k + 1)}, else: {[], counts}
      end)

    kept
  end

  defp slug(kiwix, title), do: kiwix <> (title |> String.replace(" ", "_") |> URI.encode())

  defp run_case(c, kiwix, limit_ms, crawler_opts) do
    start = slug(kiwix, c.start)
    target = slug(kiwix, c.target)
    flush()
    sw0 = :erlang.statistics(:scheduler_wall_time_all)
    t0 = System.monotonic_time(:millisecond)
    {:ok, pid} = Player.Crawler.start(start, target, crawler_opts)
    ref = Process.monitor(pid)
    acc = loop(pid, t0, limit_ms, %{reports: [], status_max: 0, last: nil, complete: false})
    sw1 = :erlang.statistics(:scheduler_wall_time_all)

    errors =
      case Player.Registry.lookup(pid) do
        %{counters: cnt} -> :counters.get(cnt, 2)
        nil -> 0
      end

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    reports = Enum.reverse(acc.reports)
    invalid = Enum.count(reports, fn {_t, p} -> verify(p, start, target) != :ok end)
    best = Enum.min_by(reports, fn {_t, p} -> length(p) end, fn -> nil end)
    articles = if best, do: length(elem(best, 1))
    ref_2007 = if c.dist, do: c.dist + 1

    # Reference for the optimum, in articles. If the pruned BFS ran to the end,
    # our path is the shortest one (up to dedupe races). Otherwise use the
    # 2007 distance, never above what we found.
    opt_ref =
      cond do
        articles && acc.complete -> articles
        articles && ref_2007 -> min(articles, ref_2007)
        articles -> articles
        true -> ref_2007
      end

    %{
      "level" => c.level,
      "start" => c.start,
      "target" => c.target,
      "dist_2007" => c.dist || "",
      "found" => reports != [],
      "t_first_ms" => with([{t, _} | _] <- reports, do: t, else: (_ -> "")),
      "t_best_ms" => if(best, do: elem(best, 0), else: ""),
      "articles" => articles || "",
      "reports" => length(reports),
      "invalid" => invalid,
      "complete" => acc.complete,
      "opt_ref" => opt_ref || "",
      "hops_ratio" =>
        if(articles && opt_ref, do: Float.round((opt_ref - 1) / (articles - 1), 3), else: ""),
      "fetched" => (acc.last && acc.last.visited_count) || 0,
      "errors" => errors,
      "status_max_us" => acc.status_max,
      "utilization" => utilization(sw0, sw1)
    }
  end

  # Fake harness: collect reports, poll status/1 every 250 ms like the real one.
  defp loop(pid, t0, limit_ms, acc) do
    now = System.monotonic_time(:millisecond) - t0

    cond do
      now >= limit_ms ->
        acc

      match?(%{state: :exhausted}, acc.last) ->
        %{acc | complete: true}

      match?(%{state: :found}, acc.last) and done?(pid) ->
        %{acc | complete: true}

      true ->
        receive do
          {:path_found, _from, path} ->
            loop(pid, t0, limit_ms, %{acc | reports: [{now, path} | acc.reports]})

          {:exhausted, _from} ->
            loop(pid, t0, limit_ms, acc)
        after
          250 ->
            {us, st} = :timer.tc(fn -> Player.Crawler.status(pid) end)
            loop(pid, t0, limit_ms, %{acc | last: st, status_max: max(acc.status_max, us)})
        end
    end
  end

  defp done?(pid), do: :sys.get_state(pid).finished

  defp flush do
    receive do
      {:path_found, _, _} -> flush()
      {:exhausted, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp utilization(sw0, sw1) do
    {active, total} =
      Enum.zip(Enum.sort(sw0), Enum.sort(sw1))
      |> Enum.reduce({0, 0}, fn {{_, a0, t0}, {_, a1, t1}}, {a, t} ->
        {a + a1 - a0, t + t1 - t0}
      end)

    if total > 0, do: Float.round(active / total, 3), else: 0.0
  end

  # Same checks as WikiRacePlatform.Race.Verifier.verify/3.
  def verify(path, start, target) do
    if Player.Path.valid_shape?(path, start, target) do
      path
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(:ok, fn [from, to] ->
        case Req.get(from, retry: false, receive_timeout: 10_000) do
          {:ok, %{status: 200, body: body}} ->
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

          other ->
            {:error, {:fetch, from, other}}
        end
      end)
    else
      {:error, :shape}
    end
  end
end

Bench.main(System.argv())
