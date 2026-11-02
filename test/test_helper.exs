# Tests tagged :kiwix need a running Kiwix (see test/player/race_test.exs):
#   mix test --include kiwix
Code.require_file("support/fake_kiwix.exs", __DIR__)
ExUnit.start(exclude: [:kiwix])
