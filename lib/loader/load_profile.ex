defmodule Loader.LoadProfile do
  @moduledoc """
  A struct representing a distribution of discrete work tasks over a period of time,
  and functions for working with that data.

  See `Loader.LoadProfile.Curves` for details on defining the `function` of a `LoadProfile`, which
  determines the distribution of work tasks.

  A `LoadProfile` is defined independently from the type of work being done. It could describe
  calls made against a remote service as easily as work done in a local module.
  """

  defstruct target_running_time: System.convert_time_unit(10, :second, :millisecond),
            function: nil,
            tick_resolution: 10

  @type t :: %__MODULE__{
          target_running_time: integer(),
          function: (integer() -> number()),
          tick_resolution: 10
        }

  @doc """
  Returns a new `LoadProfile` based on the given props, with incorrect props set to default values.

  ## Rules for props:
    - `target_running_time`: **must** be a positive integer
    - `function`: **must** be a 1-arity function. It should also return a number, but this isn't enforced
  """
  def new(props \\ %{}) do
    props =
      Map.update(props, :target_running_time, 10_000, fn
        time when is_integer(time) and time > 0 ->
          time * 1_000

        _ ->
          10_000
      end)
      |> Map.update(:function, &Loader.LoadProfile.Curves.uniform(&1, 10), fn func ->
        if Function.info(func)[:arity] == 1 do
          func
        else
          &Loader.LoadProfile.Curves.uniform(&1, 10)
        end
      end)

    # the longer the running time, the more acceptable it is to space out the curve points and lose
    # precision in order to avoid scheduling overheads. the larger "steps" will be smoothed by the long
    # running time
    tick_resolution =
      cond do
        props[:target_running_time] <= :timer.seconds(2) ->
          100

        props[:target_running_time] <= :timer.seconds(10) ->
          200

        props[:target_running_time] <= :timer.minutes(5) ->
          350

        true ->
          500
      end

    props =
      Map.merge(
        %{
          tick_resolution: tick_resolution
        },
        props
      )

    struct(Loader.LoadProfile, props)
  end

  @doc """
  Returns a 2-tuple: a plot of points that represents how tasks would be distributed for the given profile,
  and the total number of tasks "under the curve" (an approximate integral of the function, but reflecting
  the total number of tasks that will be executed).
  """
  @spec plot_curve(t()) :: {[{integer(), integer()}], integer()}
  def plot_curve(profile) do
    %Loader.LoadProfile{
      target_running_time: target_running_time,
      function: function,
      tick_resolution: tick_resolution
    } = profile

    # TODO: can i somehow represent all the "floats" as integers, so that i don't have to
    # use `map_reduce`, and can thus use a stream instead so as not to materialize this
    # whole list?

    # basically calculating the "left Riemann sum" with width of 0.005
    tick_count = Integer.floor_div(target_running_time, 5)

    {task_series, _acc} =
      Enum.map_reduce(0..(tick_count - 1), 0.0, fn tick_index, acc ->
        {int_component, float_component} = split_float(function.(tick_index * 0.005) * 0.005)
        carry_over = acc + float_component

        cond do
          tick_index == tick_count - 1 ->
            # using `ceil` since we'd rather send 1 extra than 1 less
            task_count =
              (int_component + float_component + carry_over)
              |> Float.ceil()
              |> Decimal.from_float()
              |> Decimal.to_integer()

            {{tick_index, task_count}, 0}

          carry_over >= 1 ->
            {carry_over_int, carry_over_float} = split_float(carry_over)

            {{tick_index, int_component + carry_over_int}, carry_over_float}

          true ->
            {{tick_index, int_component}, acc + float_component}
        end
      end)

    {task_series, {total_tasks, _final_index}} =
      task_series
      |> Enum.chunk_every(Integer.floor_div(tick_resolution, 5))
      |> Enum.map_reduce({0, 0}, fn task_group, {total_tasks, index} ->
        task_count_for_group =
          Enum.reduce(task_group, 0, fn {_index, task_count}, acc ->
            acc + task_count
          end)

        {{index, task_count_for_group}, {total_tasks + task_count_for_group, index + 1}}
      end)

    {task_series, total_tasks}
  end

  defp split_float(num) when is_integer(num), do: {num, 0.0}

  defp split_float(f) when is_float(f) do
    integer_component = trunc(f)

    float_component =
      Decimal.from_float(f)
      |> Decimal.sub(Decimal.new(integer_component))
      |> Decimal.to_float()

    {integer_component, float_component}
  end
end

# TODO: add other "out-of-the-box" distributions:
# - quadratic
# - exponential growth/ decay
# - sine waves (using `:math`)
defmodule Loader.LoadProfile.Curves do
  @moduledoc """
  Convenience functions for defining typical "curves" (i.e. "functions") for the request distribution
  in a `LoadProfile`.

  The unit for `x` is **always seconds**.
  """
  def uniform(_x, y_intercept), do: linear(0, 0, y_intercept)

  def linear(x, slope, y_intercept), do: x * slope + y_intercept
end
