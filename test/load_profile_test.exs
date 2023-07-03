defmodule LoadProfileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loader.LoadProfile
  alias Loader.LoadProfile.Curves

  # with extremely large numbers (e.g. `5e300`) there are `ArithmeticError`s when evaluating
  # the curve functions, and those numbers seem so preposterously large as to never be useful
  # in the context of these modules. as such, i have opted to produce numbers within a reasonably
  # large bound instead
  def bounded_integer do
    StreamData.integer(-10_000_000..10_000_000)
  end

  def bounded_float do
    StreamData.float(min: -10_000_000.0, max: 10_000_000.0)
  end

  def bounded_number do
    StreamData.one_of([bounded_integer(), bounded_float()])
  end

  describe "`LoadProfile.plot_curve/1`" do
    property "the total number of planned requests is approximately equal (+/- 1%) to the integral of the curve above the x-axis" do
      check all(
              slope <- StreamData.float(min: 0.0, max: 100.0),
              y_intercept <- StreamData.float(min: 0.0, max: 1000.0),
              target_running_time <- StreamData.integer(0..1_000)
            ) do
        profile =
          LoadProfile.new(%{
            function: &Curves.linear(&1, slope, y_intercept),
            target_running_time: target_running_time
          })

        definite_integral = slope * target_running_time ** 2 / 2 + y_intercept * target_running_time
        {_req_plots, approximate_integral} = LoadProfile.plot_curve(profile)

        assert_in_delta(definite_integral, approximate_integral, max(0.01 * definite_integral, 1))
      end
    end
  end

  describe "`Curves`" do
    property "all `sine_wave/2` values should be non-negative for a non-negative, integer `x`" do
      check all(
              x <- bounded_integer(),
              amplitude <- bounded_number(),
              ordinary_frequency <- bounded_number(),
              phase <- StreamData.one_of([StreamData.integer(0..2), StreamData.float(min: 0.0, max: 2.0)]),
              angular_frequency <- bounded_number()
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

    property "uniform/2 always returns the same value" do
      check all(
              x <- bounded_integer(),
              reqs_per_second <- bounded_number()
            ) do
        assert reqs_per_second == Curves.uniform(x, reqs_per_second)
      end
    end

    property "the distance between any two results from `linear/3` is a product of slope * (difference of x)" do
      check all(
              x_zero <- bounded_integer(),
              x_one <- bounded_integer(),
              slope <- bounded_integer(),
              y_intercept <- bounded_integer()
            ) do
        y_zero = Curves.linear(x_zero, slope, y_intercept)
        y_one = Curves.linear(x_one, slope, y_intercept)

        assert y_one - y_zero == slope * (x_one - x_zero)
      end
    end
  end
end
