defmodule StatsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loader.Stats

  doctest Loader.Stats

  describe "`summarize/1`" do
    property "the min, max, mode, median, and percentile values are members of the input list" do
      check all(measurements <- StreamData.list_of(StreamData.float(), min_length: 1)) do
        measurements = Enum.map(measurements, &(&1 |> Decimal.from_float() |> Decimal.round(4) |> Decimal.to_float()))
        summary = Stats.summarize(measurements, mode_rounding_places: 4)

        assert summary.min in measurements
        assert summary.max in measurements
        assert summary.median in measurements

        {mode_values, _count} = summary.mode

        for value <- mode_values do
          assert value in measurements
        end

        for {_percentile_mark, percentile_value} <- summary.percentiles do
          assert percentile_value in measurements
        end
      end
    end

    test "sane defaults for an empty list" do
      summary = Stats.summarize([])

      for numeric_field <- ~w(min max mean median standard_deviation mode)a do
        assert is_nil(Map.fetch!(summary, numeric_field))
      end

      assert %{} = summary.percentiles
    end

    test "correct summary for a list of integers" do
      summary = Stats.summarize(1..100)

      assert summary.min == 1
      assert summary.max == 100
      assert summary.mean == 50.5

      assert summary.standard_deviation
             |> Decimal.from_float()
             |> Decimal.round(3)
             # using the "sampled standard deviation"
             |> Decimal.eq?(Decimal.new("28.866"))

      assert summary.median == 51

      for {percentile, measurement} <- summary.percentiles do
        # percentile values will occur at their index, but will have a 
        # value of the index + 1, due to zero indexing
        # e.g. the "25th percentile" will be at index 25, w/ a value of 26
        assert measurement == percentile + 1
      end

      {mode_values, mode_occurrences} = summary.mode

      assert mode_occurrences == 1
      assert Enum.count(mode_values) == 100

      # every value appears once, so we shouldn't drop a single one
      mode_values = Enum.sort(mode_values)

      for {initial_measurement, mode_value} <-
            Enum.zip(Enum.map(1..100, fn num -> num |> Decimal.new() |> Decimal.to_float() end), mode_values) do
        assert initial_measurement == mode_value
      end
    end

    test "correct summary for a list of floats" do
      summary = Stats.summarize(1..100)

      assert summary.min == 1
      assert summary.max == 100
      assert summary.mean == 50.5

      assert summary.standard_deviation
             |> Decimal.from_float()
             |> Decimal.round(3)
             # using the "sampled standard deviation"
             |> Decimal.eq?(Decimal.new("28.866"))

      assert summary.median == 51

      for {percentile, measurement} <- summary.percentiles do
        assert measurement == percentile + 1
      end

      {mode_values, mode_occurrences} = summary.mode

      assert mode_occurrences == 1
      assert Enum.count(mode_values) == 100

      # every value appears once, so we shouldn't drop a single one
      mode_values = Enum.sort(mode_values)

      for {initial_measurement, mode_value} <-
            Enum.zip(Enum.map(1..100, fn num -> num |> Decimal.new() |> Decimal.to_float() end), mode_values) do
        assert initial_measurement == mode_value
      end
    end
  end

  describe "to_histogram/2" do
    property "cardinality of measurements is the sum of the cardinality of all buckets" do
      check all(
              measurements <- StreamData.list_of(StreamData.float()),
              buckets <- StreamData.list_of(StreamData.float(), min_length: 1)
            ) do
        histogram = Stats.to_histogram(measurements, buckets)

        sum_of_bucket_cardinalities =
          Enum.reduce(histogram, 0, fn {_key, bucket}, acc ->
            acc + Enum.count(bucket)
          end)

        assert Enum.count(measurements) == sum_of_bucket_cardinalities
      end
    end

    property "every measure in a bucket with a numeric fencepost is >= the fencepost value" do
      check all(
              measurements <- StreamData.list_of(StreamData.float()),
              buckets <- StreamData.list_of(StreamData.float(), min_length: 1)
            ) do
        histogram = Stats.to_histogram(measurements, buckets)

        for {fencepost, bucket} <- histogram, is_number(fencepost), value <- bucket do
          assert value >= fencepost
        end
      end
    end

    property "values in the `:out_of_range` bucket are less than the value of any fencepost" do
      check all(
            measurements <- StreamData.list_of(StreamData.float()),
            buckets <- StreamData.list_of(StreamData.float(), min_length: 1)
      ) do
        histogram = Stats.to_histogram(measurements, buckets)

        out_of_range_values = histogram[:out_of_range] || []
        for {fencepost, _bucket} <- histogram, is_number(fencepost), value <- out_of_range_values do
          assert value < fencepost
        end
      end
    end
  end
end
