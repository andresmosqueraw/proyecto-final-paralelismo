# Benchmark: runs Player.Crawler on article pairs against a LOCAL Kiwix, acting
# as a fake harness, and verifies every reported path like the platform does.
#
#   mix run test/bench/run.exs CASES.exs [--filter easy] [--limit 20] \
#       [--kiwix http://localhost:8081/content/wikipedia_en_all_nopic/] \
#       [--time 120] [--out results.csv] [--concurrency N]
#
# CASES.exs evaluates to a list of %{start: title, target: title, note: text}
# (same format as platform/priv/article_pairs.exs).
#
# Never point --kiwix at the course server: this sends thousands of requests.

defmodule Bench do
  alias Player.URL

  def main(args) do
    {opts, [cases_file], _} =
      OptionParser.parse(args,
        strict: [
          filter: :string,
          limit: :integer,
          kiwix: :string,
          time: :integer,
          out: :string,
          concurrency: :integer
        ]
      )

    kiwix = Keyword.get(opts, :kiwix, "http://localhost:8081/content/wikipedia_en_all_nopic/")
    time_s = Keyword.get(opts, :time, 120)
    out = Keyword.get(opts, :out, "bench_results.csv")
    crawler_opts = Keyword.take(opts, [:concurrency])

    cases =
      cases_file
      |> Code.eval_file()
      |> elem(0)
      |> Enum.filter(fn c -> String.contains?(c.note, Keyword.get(opts, :filter, "")) end)
      |> Enum.take(Keyword.get(opts, :limit, 1_000_000))

    :erlang.system_flag(:scheduler_wall_time, true)
    :yes = :global.re_register_name(WikiRace.Harness.registered_name(), self())

    header =
      "start,target,found,t_first_ms,t_best_ms,articles,reports,invalid,fetched,status_max_us,utilization,note"

    rows =
      for {c, i} <- Enum.with_index(cases, 1) do
        r = run_case(slug(kiwix, c.start), slug(kiwix, c.target), time_s * 1_000, crawler_opts)

        IO.puts(
          "#{i}/#{length(cases)} #{c.start} -> #{c.target}: " <>
            if(r.found, do: "#{r.articles} articles in #{r.t_best} ms", else: "NOT FOUND") <>
            " (first #{r.t_first} ms, fetched #{r.fetched}, util #{r.util}, " <>
            "status max #{r.status_max} µs#{if r.invalid > 0, do: ", INVALID #{r.invalid}"})"
        )

        line =
          Enum.join(
            [
              csv(c.start),
              csv(c.target),
              r.found,
              r.t_first,
              r.t_best,
              r.articles,
              r.reports,
              r.invalid,
              r.fetched,
              r.status_max,
              r.util,
              csv(c.note)
            ],
            ","
          )

        {line, r}
      end

    File.write!(out, Enum.join([header | Enum.map(rows, &elem(&1, 0))], "\n") <> "\n")
    summary(Enum.map(rows, &elem(&1, 1)), out)
  end

  defp slug(kiwix, title), do: kiwix <> (title |> String.replace(" ", "_") |> URI.encode())
  defp csv(s), do: "\"" <> String.replace(s, "\"", "\"\"") <> "\""

  defp run_case(start, target, limit_ms, crawler_opts) do
    flush()
    sw0 = :erlang.statistics(:scheduler_wall_time_all)
    t0 = System.monotonic_time(:millisecond)
    {:ok, pid} = Player.Crawler.start(start, target, crawler_opts)
    ref = Process.monitor(pid)
    acc = loop(pid, t0, limit_ms, %{reports: [], status_max: 0, last: nil})
    sw1 = :erlang.statistics(:scheduler_wall_time_all)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    reports = Enum.reverse(acc.reports)
    invalid = Enum.count(reports, fn {_t, p} -> verify(p, start, target) != :ok end)
    best = Enum.min_by(reports, fn {_t, p} -> length(p) end, fn -> nil end)

    %{
      found: reports != [],
      t_first: with([{t, _} | _] <- reports, do: t, else: (_ -> "")),
      t_best: if(best, do: elem(best, 0), else: ""),
      articles: if(best, do: length(elem(best, 1)), else: ""),
      reports: length(reports),
      invalid: invalid,
      fetched: (acc.last && acc.last.visited_count) || 0,
      status_max: acc.status_max,
      util: utilization(sw0, sw1)
    }
  end

  # Fake harness: collect reports, poll status/1 every 250 ms like the real one.
  defp loop(pid, t0, limit_ms, acc) do
    now = System.monotonic_time(:millisecond) - t0

    cond do
      now >= limit_ms ->
        acc

      match?(%{state: :exhausted}, acc.last) ->
        acc

      match?(%{state: :found}, acc.last) and done?(pid) ->
        acc

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
    cond do
      not Player.Path.valid_shape?(path, start, target) ->
        {:error, :shape}

      true ->
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
    end
  end

  defp summary(results, out) do
    n = length(results)
    found = Enum.count(results, & &1.found)
    invalid = results |> Enum.map(& &1.invalid) |> Enum.sum()
    status_max = results |> Enum.map(& &1.status_max) |> Enum.max(fn -> 0 end)
    times = results |> Enum.filter(& &1.found) |> Enum.map(& &1.t_first) |> Enum.sort()

    med = if times == [], do: "-", else: Enum.at(times, div(length(times), 2))

    p90 =
      if times == [],
        do: "-",
        else: Enum.at(times, min(length(times) - 1, div(length(times) * 9, 10)))

    IO.puts(
      "\nfound #{found}/#{n}, invalid reports #{invalid}, " <>
        "t_first median #{med} ms, p90 #{p90} ms, status/1 max #{status_max} µs -> #{out}"
    )
  end
end

Bench.main(System.argv())
