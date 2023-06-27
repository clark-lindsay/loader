defmodule Loader.ScheduledLoader do
  defmodule State do
    @enforce_keys [:load_profile]
    defstruct load_profile: nil,
              total_task_count: nil,
              work_spec: nil,
              wall_clock_start_time: nil,
              mono_start_time: nil,
              remaining_curve_points: nil,
              successes: [],
              failures: []
  end

  use GenServer, restart: :transient

  alias Loader.LoadProfile
  alias Loader.ScheduledLoader.State
  alias Loader.WorkSpec

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

    {[{_first_tick_index, task_count} | curve], total_task_count} =
      LoadProfile.plot_curve(load_profile)

    IO.inspect(total_task_count, label: "Total task count in curve")

    Process.send_after(self(), {:tick, task_count}, load_profile.tick_resolution)

    {:ok,
     %State{
       load_profile: load_profile,
       total_task_count: total_task_count,
       work_spec: work_spec,
       remaining_curve_points: curve,
       wall_clock_start_time: DateTime.utc_now(),
       mono_start_time: System.monotonic_time()
     }}
  end

  @impl GenServer
  def handle_info({:tick, task_count}, state) do
    Task.Supervisor.async_nolink(Loader.TaskSupervisor, fn ->
      # TODO: what happens when a task runs several times and fails?
      # should each task be wrapped in a `try`, since a failure is acceptable?
      case state.work_spec do
        %WorkSpec{task: task} when is_function(task) ->
          task.(task_count)

        # could the MFA option be a struct that has an MFA and a way to add the task_count
        # to the args, via a 2-arity callback?
        %WorkSpec{task: {module, function, args}} ->
          Kernel.apply(module, function, args ++ task_count)
      end
    end)

    {ticks, curve} =
      Enum.split_while(state.remaining_curve_points, fn {_tick_index, task_count} ->
        task_count <= 0
      end)

    {triggering_tick_as_list, curve} = Enum.split(curve, 1)

    # TODO: if `triggering_tick_as_list` is empty then we are done, and should start a shutdown
    # critical that all work items complete before shutdown (failure being acceptable)

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
  # a task completed successfully
  def handle_info({ref, response}, state) do
    Process.demonitor(ref, [:flush])

    state =
      case response do
        response when is_list(response) ->
          {goods, bads} = Enum.split_with(response, state.work_spec.is_success?)

          Map.update!(state, :successes, fn successes -> goods ++ successes end)
          |> Map.update!(:failures, fn failures -> bads ++ failures end)

        response ->
          if state.work_spec.is_success?.(response) do
            Map.update!(state, :successes, fn successes -> [response | successes] end)
          else
            Map.update!(state, :failures, fn failures -> [response | failures] end)
          end
      end

    {:noreply, state}
  end

  @impl GenServer
  # a task failed
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    state = Map.update!(state, :failures, fn failures -> [{:failure, reason} | failures] end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:await_remaining_tasks, state) do
    success_count = Enum.count(state.successes)
    failure_count = Enum.count(state.failures)

    if success_count + failure_count < state.total_task_count do
      IO.puts(
        "Waiting for #{state.total_task_count - (success_count + failure_count)} remaining tasks..."
      )

      Process.send_after(self(), :await_remaining_tasks, 50)

      {:noreply, state}
    else
      {:stop, :normal, state}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    IO.puts("Successes: #{Enum.count(state.successes)}")
    IO.puts("Failures: #{Enum.count(state.failures)}")

    IO.puts(
      "Total running time in ms: #{System.convert_time_unit(System.monotonic_time() - state.mono_start_time, :native, :millisecond)}"
    )

    IO.puts("Terminating with reason: #{reason}")
  end
end
