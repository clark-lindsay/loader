defmodule LoadProfileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loader.LoadProfile.Curves

  # with extremely large numbers (e.g. `5e300`) there are `ArithmeticError`s when evaluating
  # the function, and those numbers seem so preposterously large as to never be useful when calling this function.
  # as such, i have opted to produce numbers within a reasonably large bound instead
  def bounded_integer() do
    StreamData.integer(-10_000_000..10_000_000)
  end

  def bounded_float() do
    StreamData.float(min: -10_000_000.0, max: 10_000_000.0)
  end

  def bounded_number() do
    StreamData.one_of([bounded_integer(), bounded_float()])
  end

  describe "`Curves`" do
    property "all `sine_wave/2` values should be non-negative for a non-negative, integer `x`" do
      check all(
              x <- bounded_integer(),
              amplitude <- bounded_number(),
              ordinary_frequency <- bounded_number(),
              phase <- StreamData.one_of([StreamData.integer(0..2), StreamData.float(min: 0.0, max: 2.0)]),
              angular_frequency <- bounded_number(),
              max_runs: 3_000,
              max_run_time: :infinity
            ) do
        assert 0 <=
                 Curves.sine_wave(x,
                   amplitude: amplitude,
                   frequency: ordinary_frequency,
                   phase: phase
                 )

        # the `:frequency` and `:angular_frequency` options have to be checked separately
        # since they are mutually exclusive
        assert 0 <=
                 Curves.sine_wave(x,
                   amplitude: amplitude,
                   angular_frequency: angular_frequency,
                   phase: phase
                 )
      end
    end
  end
end
