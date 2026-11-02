defmodule Player.URLPathTest do
  use ExUnit.Case, async: true

  alias Player.{Path, URL}

  @base "http://localhost:8080/content/wikipedia_en_all_nopic/"

  test "canonical matches the verifier's rules" do
    assert URL.canonical(@base <> "Human%E2%80%93wildlife_conflict") ==
             "http://localhost:8080/content/wikipedia_en_all_nopic/Human–wildlife_conflict"

    assert URL.canonical(@base <> "Tiger#Diet") == URL.canonical(@base <> "Tiger")
    assert URL.canonical(@base <> "Tiger?x=1") == URL.canonical(@base <> "Tiger")
    assert URL.canonical(@base <> "Tiger/") == URL.canonical(@base <> "Tiger")
    assert URL.canonical("http://h:80/a") == "http://h/a"
    refute URL.canonical(@base <> "tiger") == URL.canonical(@base <> "Tiger")
  end

  test "resolve keeps only article links" do
    assert URL.resolve(@base <> "Tiger", "Bengal_tiger") ==
             {@base <> "Bengal_tiger", @base <> "Bengal_tiger"}

    assert {@base <> "Trapping", _} = URL.resolve(@base <> "Tiger", "Trapping#Snares")

    for href <- ["#x", "./_mw_/a.css", "../-/search?x", "/abs", "https://e.org", "mailto:a@b", ""] do
      assert URL.resolve(@base <> "Tiger", href) == nil, href
    end
  end

  test "valid_shape? follows the verifier's check_shape" do
    s = @base <> "Beer"
    t = @base <> "Sun"
    assert Path.valid_shape?([s, @base <> "Yeast", t], s, t)
    assert Path.valid_shape?([s, t], s, t)
    refute Path.valid_shape?([s], s, s)
    refute Path.valid_shape?([], s, t)
    refute Path.valid_shape?([@base <> "Wine", t], s, t)
    refute Path.valid_shape?([s, @base <> "Yeast"], s, t)
    refute Path.valid_shape?([s, @base <> "Yeast", @base <> "Yeast#x", t], s, t)
  end

  test "reconstruct walks parents back to the start" do
    v = :ets.new(:v, [:set])
    :ets.insert(v, {"a", nil, "A", 0})
    :ets.insert(v, {"b", "a", "B", 1})
    :ets.insert(v, {"c", "b", "C", 2})
    assert Path.reconstruct(v, "c") == ["A", "B", "C"]
    assert Path.to_target(v, "c", "START", "T") == ["START", "B", "C", "T"]
    assert Path.to_target(v, "missing", "START", "T") == []
  end
end
