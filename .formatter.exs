# Used by "mix format". Source paths only: bench/results and simulator/simulations_data
# hold run evidence that must stay byte for byte as recorded
[
  inputs: [
    "{mix,.formatter,.dialyzer_ignore,.iex}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "bench/release_benchmark/**/*.{ex,exs}",
    "{example,simulator}/{mix,.formatter}.exs",
    "{example,simulator}/{config,lib,test}/**/*.{ex,exs}"
  ]
]
