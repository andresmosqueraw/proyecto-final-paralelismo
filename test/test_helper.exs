# Tests tagged :kiwix need a running Kiwix (see test/player/race_test.exs):
#   mix test --include kiwix
ExUnit.start(exclude: [:kiwix])
