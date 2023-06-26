defmodule Loader.LoadProfile do
  @moduledoc """
  A struct representing a distribution of discrete work tasks over a period of time,
  and functions for working with that data.

  A `LoadProfile` is defined independently from the type of work being done. It could describe
  calls made against a remote service as easily as work done in a local module.
  """

  # TODO: add other distributions:
  # - linear
  # - quadratic
  # - exponential growth/ decay
  # - arbitrary function (how will they define this? just a callback that takes `x`?)
  defstruct distribution_target: :uniform,
            running_time: System.convert_time_unit(10, :second, :millisecond),
            total_task_count: 100,
            tick_resolution: 10

  @type t :: %__MODULE__{
          distribution_target: atom(),
          running_time: integer(),
          total_task_count: integer(),
          tick_resolution: 10
        }

  # i have simplified the problem space, because i am not the mathematician i once was.
  # tick_resolution is **fixed** at 10 ms, and the running_time will always be given in an
  # integer number of seconds

  @doc """
  Returns a plot of points that represents how tasks would be distributed for the given profile.
  """
  @spec plot_curve(t()) :: [{integer(), integer()}]
  def plot_curve(profile) do
    %Loader.LoadProfile{
      running_time: running_time,
      total_task_count: total_task_count,
      distribution_target: distribution_target,
      tick_resolution: tick_resolution
    } = profile

    # TODO: can i somehow represent all the "floats" as integers, so that i don't have to
    # use `map_reduce`, and can thus use a stream instead so as not to materialize this
    # whole list?
    case distribution_target do
      :uniform ->
        # always an integer because `tick_resolution` is fixed at 10 ms and `running_time` is given in whole seconds
        tick_count = Integer.floor_div(running_time, tick_resolution)

        task_per_tick = total_task_count / tick_count

        {req_series, _acc} =
          Enum.map_reduce(0..(tick_count - 1), 0, fn tick_index, acc ->
            {int_component, float_component} = split_float(task_per_tick)
            carry_over = acc + float_component

            cond do
              tick_index == tick_count - 1 ->
                # using `ceil` since we'd rather send 1 extra than 1 less
                req_count =
                  (int_component + float_component + carry_over)
                  |> Float.ceil()
                  |> Decimal.from_float()
                  |> Decimal.to_integer()

                {{tick_index, req_count}, 0}

              carry_over > 1 ->
                {carry_over_int, carry_over_float} = split_float(carry_over)

                {{tick_index, int_component + carry_over_int}, carry_over_float}

              true ->
                {{tick_index, int_component}, acc + float_component}
            end
          end)

        req_series
    end
  end

  defp split_float(f) when is_float(f) do
    integer_component = trunc(f)

    float_component =
      Decimal.from_float(f)
      |> Decimal.sub(Decimal.new(integer_component))
      |> Decimal.to_float()

    {integer_component, float_component}
  end
end
