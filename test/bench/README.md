# Banco de pruebas

Corre `Player.Crawler` sobre pares de artículos contra un **Kiwix local**, haciendo de
harness falso:

- captura `report/1` con marca de tiempo;
- llama `status/1` cada 250 ms y mide su latencia;
- verifica **cada** reporte con la misma lógica de la plataforma (forma, más un fetch y Floki por salto);
- mide la utilización con `:erlang.statistics(:scheduler_wall_time_all)`.

Corre un caso a la vez, para que el tiempo y la utilización no se distorsionen.

> Nunca apuntar `--kiwix` al servidor del curso: el banco hace miles de requests.

## Uso (imagen del torneo)

```sh
docker run --rm --network host -v "$PWD":/app -v player_deps:/app/deps -v player_build:/app/_build \
  -v "$PWD/../testcases":/cases:ro -v "$PWD/../bench_results":/out -w /app \
  hexpm/elixir:1.20.2-erlang-28.5.0.4-debian-bookworm-20260713-slim \
  sh -c "mix local.hex --force >/dev/null; mix run test/bench/run.exs /cases/cases.exs \
         --per-level 15 --time 120 --out /out/NOMBRE.tsv --label 'Descripción'"
```

### Opciones de `run.exs`

| Opción | Efecto |
|---|---|
| `--kiwix URL` | Base del libro. Por defecto `http://localhost:8081/content/wikipedia_en_all_nopic/`. |
| `--time S` | Límite por carrera. Por defecto 120 s, como en el torneo. |
| `--filter TXT` / `--per-level N` / `--limit N` | Elegir casos. `--per-level` toma los N primeros de cada nivel, que son los más jugados por humanos. |
| `--out F.tsv` | Una fila por caso. El resumen por nivel se escribe en `F.md`. |
| `--concurrency N` | Se pasa a `Player.Crawler.start/3`. |

## Columnas del TSV

Es TSV porque algunos títulos tienen comas.

| Columna | Significado |
|---|---|
| `level`, `dist_2007` | Nivel y distancia en el grafo de Wikispeedia de 2007, sacados de la nota del caso. |
| `found`, `t_first_ms`, `t_best_ms` | Si encontró camino, cuándo llegó el primer reporte y cuándo llegó el más corto. |
| `articles`, `reports`, `invalid` | Largo del mejor camino, cuántos reportes hubo y cuántos fallaron la verificación. **`invalid` debe ser siempre 0.** |
| `complete` | La búsqueda terminó sola antes del límite. Con BFS podado, eso significa que el camino es el más corto. |
| `opt_ref` | Referencia del óptimo, en artículos. Es nuestro camino si `complete`; si no, `min(nuestro, dist_2007 + 1)`. |
| `hops_ratio` | `(opt_ref − 1) / (articles − 1)`, igual que el componente Hops del puntaje. |
| `fetched`, `errors` | Páginas descargadas y fetches fallidos. |
| `status_max_us`, `utilization` | Peor latencia de `status/1` y utilización de schedulers durante la carrera. |

## Comparar contra la línea base

```sh
mix run --no-start test/bench/compare.exs /out/baseline_mvp_bfs.tsv /out/NUEVO.tsv
```

Compara solo los casos que están en los dos archivos. Por nivel muestra:

- % found;
- mediana de `t_first` y su cambio;
- mediana por caso de `t_first nuevo / base`;
- `hops_ratio` y utilización.
