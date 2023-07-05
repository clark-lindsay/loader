defmodule Loader.ScheduledLoader do
  @moduledoc false
  use GenServer, restart: :transient

  alias Loader.ExecutionStore
  alias Loader.LoadProfile
  alias Loader.ScheduledLoader.State
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
              failures: []
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
    load_profile = opts[:load_profile] || raise(ArgumentError, "must provide a load profile")
    work_spec = opts[:work_spec] || raise(ArgumentError, "must provide a work specification")

    {[{_first_tick_index, task_count} | curve], total_task_count} = LoadProfile.plot_curve(load_profile)

    {:ok, %{ref: ref, mono_start_time: mono_start_time, wall_clock_start_time: wall_clock_start_time}} =
      ExecutionStore.new_scheduled_loader(self(), total_task_count)

    Process.send_after(self(), {:tick, task_count}, load_profile.tick_resolution)

    {:ok,
     %State{
       load_profile: load_profile,
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
    Task.Supervisor.async_nolink(
      {:via, PartitionSupervisor, {Loader.TaskSupervisors, self()}},
      fn ->
        {:via, PartitionSupervisor, {Loader.TaskSupervisors, self()}}
        |> Task.Supervisor.async_stream_nolink(
          1..task_count,
          fn _ ->
            task_mono_start = System.monotonic_time()

            response =
              try do
                data =
                  case state.work_spec do
                    %WorkSpec{task: task} when is_function(task) ->
                      task.()

                    # could the MFA option be a struct that has an MFA and a way to add the task_count
                    # to the args, via a 2-arity callback?
                    %WorkSpec{task: {module, function, args}} ->
                      Kernel.apply(module, function, args)
                  end

                response_time =
                  System.convert_time_unit(
                    System.monotonic_time() - task_mono_start,
                    :native,
                    :microsecond
                  )

                %WorkResponse{data: data, kind: :ok, response_time: response_time}
              rescue
                any_error ->
                  response_time =
                    System.convert_time_unit(
                      System.monotonic_time() - task_mono_start,
                      :native,
                      :microsecond
                    )

                  %WorkResponse{kind: :error, data: any_error, response_time: response_time}
              catch
                kind, value ->
                  response_time =
                    System.convert_time_unit(
                      System.monotonic_time() - task_mono_start,
                      :native,
                      :microsecond
                    )

                  %WorkResponse{kind: kind, data: value, response_time: response_time}
              end

            if state.work_spec.is_success?.(response) do
              ExecutionStore.increment_successes(state.ref)
            else
              ExecutionStore.increment_failures(state.ref)
            end
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
    {total, successes, fails} = ExecutionStore.task_counts(state.ref)

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
    ExecutionStore.log_successful_termination(state.ref)
    {_total, successes, failures} = ExecutionStore.task_counts(state.ref)

    IO.puts("ETS log finalized with ref: #{inspect(state.ref)}")
    IO.puts("Successes: #{successes}")
    IO.puts("Failures: #{failures}")

    IO.puts(
      "Total running time in ms: #{System.convert_time_unit(System.monotonic_time() - state.mono_start_time, :native, :millisecond)}"
    )

    IO.puts("Terminating with reason: #{reason}")
  end
end
