defmodule Loader.ScheduledLoader do
  @moduledoc false
  use GenServer, restart: :transient

  alias Loader.ExecutionStore
  alias Loader.LoadProfile
  alias Loader.ScheduledLoader.State
  alias Loader.Telemetry
  alias Loader.WorkResponse
  alias Loader.WorkSpec

  defmodule State do
    @moduledoc false
    @enforce_keys [:load_profile]
    defstruct load_profile: nil,
              total_task_count: nil,
              work_spec: nil,
              ref: nil,
              wall_clock_start_time: nil,
              mono_start_time: nil,
              remaining_curve_points: nil,
              successes: [],
              failures: [],
              instance_name: nil
  end

  # based on the load profile i can calculate a curve and then send a message to myself every
  # (however many) milliseconds (based on the curve) to fire off some number of tasks, inside a Task,
  # which will send a message back to myself to aggregate the results

  def child_spec(opts) do
    %{
      id: opts[:name],
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    instance_name = opts[:instance_name] || raise(ArgumentError, "must provide an instance name")
    load_profile = opts[:load_profile] || raise(ArgumentError, "must provide a load profile")
    work_spec = opts[:work_spec] || raise(ArgumentError, "must provide a work specification")

    {[{_first_tick_index, task_count} | curve], total_task_count} = LoadProfile.plot_curve(load_profile)

    {:ok, %{ref: ref, mono_start_time: mono_start_time, wall_clock_start_time: wall_clock_start_time}} =
      ExecutionStore.new_scheduled_loader(instance_name, self(), total_task_count)

    Telemetry.start(:load_profile_execution, %{
      scheduled_loader_ref: ref,
      load_profile: load_profile,
      work_spec: work_spec,
      instance_name: instance_name
    })

    Process.send_after(self(), {:tick, task_count}, load_profile.tick_resolution)

    {:ok,
     %State{
       load_profile: load_profile,
       instance_name: instance_name,
       total_task_count: total_task_count,
       work_spec: work_spec,
       remaining_curve_points: curve,
       wall_clock_start_time: wall_clock_start_time,
       mono_start_time: mono_start_time,
       ref: ref
     }}
  end

  @impl GenServer
  def handle_info({:tick, task_count}, state) do
    via_partition_supervisor = {:via, PartitionSupervisor, {Loader.task_supervisors_name(state.instance_name), self()}}

    Task.Supervisor.async_nolink(
      via_partition_supervisor,
      fn ->
        via_partition_supervisor
        |> Task.Supervisor.async_stream_nolink(
          1..task_count,
          fn _ ->
            start_meta_data = %{
              scheduled_loader_ref: state.ref,
              work_spec: state.work_spec,
              instance_name: state.instance_name
            }

            Telemetry.span(:task, start_meta_data, fn ->
              task_mono_start = System.monotonic_time()

              response =
                try do
                  data =
                    case state.work_spec do
                      %WorkSpec{task: task} when is_function(task) ->
                        task.()

                      %WorkSpec{task: {module, function, args}} ->
                        Kernel.apply(module, function, args)
                    end

                  %WorkResponse{data: data, kind: :ok, response_time: elapsed_microseconds(task_mono_start)}
                rescue
                  any_error ->
                    # rescue clause is separate from `catch` so that erlang errors are coerced to elixir errors
                    %WorkResponse{kind: :error, data: any_error, response_time: elapsed_microseconds(task_mono_start)}
                catch
                  kind, value ->
                    %WorkResponse{kind: kind, data: value, response_time: elapsed_microseconds(task_mono_start)}
                end

              is_success? = state.work_spec.is_success?.(response)

              if is_success? do
                ExecutionStore.increment_successes(state.instance_name, state.ref)
              else
                ExecutionStore.increment_failures(state.instance_name, state.ref)
              end

              {response, Map.put(start_meta_data, :was_success?, is_success?)}
            end)
          end
        )
        |> Stream.run()
      end
    )

    {ticks, curve} =
      Enum.split_while(state.remaining_curve_points, fn {_tick_index, task_count} ->
        task_count <= 0
      end)

    {triggering_tick_as_list, curve} = Enum.split(curve, 1)

    if Enum.empty?(triggering_tick_as_list) do
      state = Map.put(state, :remaining_curve_points, curve)
      send(self(), :await_remaining_tasks)

      {:noreply, state}
    else
      ticks_until_next_message = Enum.count(ticks) + 1
      [{_next_task_tick_index, next_task_count}] = triggering_tick_as_list

      # need to send the next message **only** when it would have gone out without scanning
      # for "empty" ticks, to preserve the desired curve of the load profile
      Process.send_after(
        self(),
        {:tick, next_task_count},
        ticks_until_next_message * state.load_profile.tick_resolution
      )

      state = Map.put(state, :remaining_curve_points, curve)

      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:await_remaining_tasks, state) do
    {total, successes, fails} = ExecutionStore.task_counts(state.instance_name, state.ref)

    if successes + fails < total do
      IO.puts("Waiting for #{total - (successes + fails)} remaining tasks...")

      Process.send_after(self(), :await_remaining_tasks, 50)

      {:noreply, state}
    else
      {:stop, :normal, state}
    end
  end

  @impl GenServer
  # a `Task` started via `TaskSupervisor.async_nolink` has completed successfully
  def handle_info({ref, _return_value}, state) do
    # We don't care about the DOWN message now, so let's demonitor and flush it
    Process.demonitor(ref, [:flush])

    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    {_total, successes, failures} = ExecutionStore.task_counts(state.instance_name, state.ref)
    ExecutionStore.log_successful_termination(state.instance_name, state.ref)

    end_time =
      Telemetry.stop(
        :load_profile_execution,
        state.mono_start_time,
        %{
          failures: failures,
          instance_name: state.instance_name,
          load_profile: state.load_profile,
          scheduled_loader_ref: state.ref,
          successes: successes,
          work_spec: state.work_spec
        }
      )

    IO.puts("ETS log finalized with ref: #{inspect(state.ref)}")
    IO.puts("Successes: #{successes}")
    IO.puts("Failures: #{failures}")

    IO.puts(
      "Total running time in ms: #{System.convert_time_unit(end_time - state.mono_start_time, :native, :millisecond)}"
    )

    IO.puts("Terminating with reason: #{reason}")
  end

  defp elapsed_microseconds(native_start_time) do
    System.convert_time_unit(
      System.monotonic_time() - native_start_time,
      :native,
      :microsecond
    )
  end
end
