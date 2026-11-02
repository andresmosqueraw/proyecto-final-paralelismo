defmodule Player.ReportPolicyTest do
  use ExUnit.Case, async: true

  import Player.Race, only: [worth_reporting?: 4]

  test "a shorter path is worth reporting only if it comes soon enough" do
    # 5 -> 4 articles: Hops gains 0.04, so Time may lose at most that:
    # 0.15 * (1 - t1/t2) < 0.04  <=>  t2 < 1.36 * t1
    assert worth_reporting?(5, 1_000, 4, 1_300)
    refute worth_reporting?(5, 1_000, 4, 1_400)

    # 4 -> 3 articles: gain 0.05, allowed up to t2 < 1.5 * t1
    assert worth_reporting?(4, 1_000, 3, 1_400)
    refute worth_reporting?(4, 1_000, 3, 1_600)

    # Big improvements are almost always worth it.
    assert worth_reporting?(8, 1_000, 3, 5_000)
    # Same length is never worth it.
    refute worth_reporting?(4, 1_000, 4, 1_000)
  end
end
