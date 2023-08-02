defmodule Loader.Stats do
  @moduledoc """
  Functions for aggregating statistics on measurements.
  """

  defmodule Summary do
    @moduledoc """
    It is assumed that we are "sampling" for the standard deviation, and so the formula
    for the "sampled standard deviation" is used. See WikiPedia for more details.
    """
    defstruct [
      :max,
      :mean,
      :median,
      :min,
      :mode,
      :percentiles,
      :standard_deviation
    ]
  end

  @doc """
  Return summary statistics for a set of measurement values. 

  ## Options

    * `:mode_rounding_places` - The number of decimal places to which measurements will be rounded for aggregating the "mode". Defaults to `4`.

  ## Examples

  ```elixir
  iex> measurements = [1.55, 1.547, 1.6]
  iex> summary = summarize(measurements, mode_rounding_places: 2)
  iex> {[1.55], 2} = summary.mode
  iex> more_precise_summary = summarize(measurements, mode_rounding_places: 4) 
  iex> {[1.6, 1.55, 1.547], 1} = more_precise_summary.mode
  ```
  """
  @spec summarize([number()]) :: %Summary{}
  def summarize([]) do
    %Summary{
      percentiles: %{}
    }
  end

  def summarize(measurements, opts \\ []) do
    mode_rounding_places = opts[:mode_rounding_places] || 4

    total_measurements = Enum.count(measurements)

    percentile_indices =
      for p_target <- [25, 50, 75, 90, 95, 99], reduce: %{} do
        acc ->
          index =
            (p_target / 100 * (total_measurements - 1))
            |> Decimal.from_float()
            |> Decimal.round(0, :ceiling)
            |> Decimal.to_integer()
            |> min(total_measurements - 1)

          Map.update(acc, index, [p_target], fn targets -> [p_target | targets] end)
      end

    initial_accumulator =
      %Summary{}
      |> Map.from_struct()
      |> Map.merge(%{index: 0, percentiles: %{}, frequencies: %{}, sum: 0, squared_sum: 0})

    first_pass =
      measurements
      |> Enum.sort()
      |> Enum.reduce(initial_accumulator, fn measurement, acc ->
        acc =
          if Map.has_key?(percentile_indices, acc[:index]) do
            percentiles =
              percentile_indices
              |> Map.fetch!(acc[:index])
              |> Enum.map(&{&1, measurement})
              |> Map.new()

            Map.update!(acc, :percentiles, &Map.merge(&1, percentiles))
          else
            acc
          end

        acc
        |> Map.update!(:index, &(&1 + 1))
        |> Map.update(:min, measurement, &Decimal.min(to_decimal(&1), to_decimal(measurement)))
        |> Map.update(:max, measurement, &Decimal.max(to_decimal(&1), to_decimal(measurement)))
        |> Map.update!(:frequencies, fn freqs ->
          key =
            measurement
            |> to_decimal()
            |> Decimal.round(mode_rounding_places)
            |> Decimal.to_float()

          Map.update(freqs, key, 1, &(&1 + 1))
        end)
        |> Map.update(:sum, measurement, &(&1 + measurement))
        |> Map.update(:squared_sum, measurement, &(&1 + measurement ** 2))
      end)

    {{mode_occurrence_count, mode_values}, _} =
      first_pass[:frequencies]
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.reduce_while({{0, []}, nil}, fn {value, frequency}, {{count, values}, min_frequency} ->
        cond do
          is_nil(min_frequency) ->
            {:cont, {{frequency, [value | values]}, frequency}}

          frequency == min_frequency ->
            {:cont, {{frequency, [value | values]}, min_frequency}}

          frequency < min_frequency ->
            {:halt, {{count, values}, min_frequency}}
        end
      end)

    first_pass
    |> Map.take(~w(min max percentiles)a)
    |> Map.merge(%{
      mean: first_pass[:sum] / total_measurements,
      median: first_pass[:percentiles][50],
      standard_deviation:
        (first_pass[:squared_sum] / total_measurements - (first_pass[:sum] / total_measurements) ** 2.0)
        |> to_decimal()
        |> Decimal.sqrt(),
      mode: {mode_values, mode_occurrence_count}
    })
    |> Enum.map(fn {key, val} ->
      case val do
        %Decimal{} ->
          {key, Decimal.to_float(val)}

        _ ->
          {key, val}
      end
    end)
    |> then(&struct!(Summary, &1))
  end

  # TODO: add docs
  def to_histogram([], _), do: %{}

  def to_histogram(measurements, [single_bucket_fencepost]) do
    Enum.reduce(measurements, %{out_of_range: []}, fn measurement, acc ->
      if measurement >= single_bucket_fencepost do
        Map.update(acc, single_bucket_fencepost, [measurement], &[measurement | &1])
      else
        Map.update!(acc, :out_of_range, &[measurement | &1])
      end
    end)
  end

  def to_histogram(measurements, buckets) do
    bucket_brackets =
      buckets
      |> Enum.uniq()
      |> Enum.sort()
      # =>   [0, 0.25, 0.5, 0.75, 1]
      |> Enum.chunk_every(2, 1)

    # =>   [[0, 0.25], [0.25, 0.5], ..., [0.75, 1]]

    Enum.reduce(measurements, %{}, fn measurement, acc ->
      histogram_key =
        Enum.reduce_while(bucket_brackets, :out_of_range, fn
          [max_bucket], _acc ->
            if measurement >= max_bucket do
              {:halt, max_bucket}
            else
              {:halt, :out_of_range}
            end

          [low, high], acc ->
            if measurement >= low and measurement < high do
              {:halt, low}
            else
              {:cont, acc}
            end
        end)

      Map.update(acc, histogram_key, [measurement], &[measurement | &1])
    end)
  end

  defp to_decimal(float) when is_float(float), do: Decimal.from_float(float)
  defp to_decimal(nil), do: Decimal.new("NaN")
  defp to_decimal(num), do: Decimal.new(num)
end
