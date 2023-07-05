defmodule Loader.ExecutionStore do
  @moduledoc """
  All entries in the `ets` tables "held" by this process should have the following format:
  TODO: add duration after mono completion time
  ```
  {
    unique_ref, # via `make_ref/0`
    pid,
    monotomic_start_time,
    successful_monotomic_completion_time,
    wall_clock_start_time,
    successful_wall_clock_completion_time,
    total_tasks_to_execute,
    success_count,
    failure_count
  }
  ```

  The details of the `ets` table and the tuple format are an internal detail,
  and should not be relied upon by other modules.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(ExecutionStore, [:named_table, :set, :public])

    {:ok, %{}}
  end

  def new_scheduled_loader(pid, total_task_count) do
    loader_ref = make_ref()
    wall_clock_start_time = DateTime.utc_now()
    mono_start_time = System.monotonic_time()

    was_insert_success? =
      :ets.insert_new(
        ExecutionStore,
        {
          loader_ref,
          pid,
          mono_start_time,
          nil,
          wall_clock_start_time,
          nil,
          total_task_count,
          0,
          0
        }
      )

    if was_insert_success? do
      {:ok, %{ref: loader_ref, wall_clock_start_time: wall_clock_start_time, mono_start_time: mono_start_time}}
    else
      {:error, "key already exists in table"}
    end
  end

  # intentionally not handling errors here b/c an issue here would be truly exceptional:
  # it would either mean that there is a bug in the library code, or that somehow a 
  # `ScheduledLoader` is trying to increment a counter or terminate when it has not been properly initialized
  def increment_successes(scheduled_loader_ref) do
    :ets.update_counter(ExecutionStore, scheduled_loader_ref, {8, 1})
  end

  def increment_failures(scheduled_loader_ref) do
    :ets.update_counter(ExecutionStore, scheduled_loader_ref, {9, 1})
  end

  def task_counts(scheduled_loader_ref) do
    [{_, _, _, _, _, _, total, successes, fails}] = :ets.lookup(ExecutionStore, scheduled_loader_ref)

    {total, successes, fails}
  end

  def log_successful_termination(scheduled_loader_ref) do
    true =
      :ets.update_element(ExecutionStore, scheduled_loader_ref, [
        {4, System.monotonic_time()},
        {6, DateTime.utc_now()}
      ])
  end
end
