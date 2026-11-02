defmodule Player.HeuristicTest do
  use ExUnit.Case, async: true

  alias Player.Heuristic

  @base "http://localhost:8080/content/wikipedia_en_all_nopic/"

  test "tokens decode the title, drop stopwords and short tokens" do
    tokens = &Heuristic.tokens(Player.URL.canonical(@base <> &1))
    assert tokens.("History_of_the_United_States") == ~w(history united states)
    assert tokens.("Alien%3A_Resurrection") == ~w(alien resurrection)
    assert tokens.("Human%E2%80%93wildlife_conflict") == ~w(human wildlife conflict)
    assert tokens.("Pok%C3%A9mon_(TV_series)") == ~w(pokémon tv series)
  end

  test "title overlap and rel stay in [0, 1]" do
    t = MapSet.new(~w(great white shark))
    assert Heuristic.title_overlap(~w(shark), t) == 1 / 3
    assert Heuristic.title_overlap(~w(cat), t) == 0.0
    assert Heuristic.title_overlap(~w(shark), MapSet.new()) == 0.0
    assert Heuristic.rel(0, 100, 100) == 0.0
    assert Heuristic.rel(100, 100, 100) == 1.0
    assert Heuristic.rel(5, 0, 100) == 0.0
  end

  test "scores rank target-related links first; bfs weights only use depth" do
    links = [
      {@base <> "Cat", @base <> "Cat"},
      {@base <> "Shark", @base <> "Shark"},
      {@base <> "Ocean", @base <> "Ocean"}
    ]

    tokens = MapSet.new(~w(great white shark))
    out? = &(&1 == @base <> "Ocean")
    w = Heuristic.weights(:default)

    [{_, _, cat}, {_, _, shark}, {_, _, ocean}] =
      Heuristic.score_links(links, 1, 0.0, out?, tokens, w)

    assert ocean > cat and shark > cat

    bfs = Heuristic.score_links(links, 2, 0.5, out?, tokens, Heuristic.weights(:bfs))
    assert Enum.all?(bfs, fn {_, _, s} -> s == -2.0 end)
  end
end
