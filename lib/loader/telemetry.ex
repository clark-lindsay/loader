defmodule Loader.Telemetry do
  @moduledoc """
  Telemetry integration.

  Unless specified, all times are in `:native` units.

  Loader executes the following events:

  ### Load Profile Execution Start

  `[:loader, :load_profile_execution, :start]` - emitted when `Loader.execute/2` is called.

  #### Measurements

    * `:system_time` - system time, as reported by `System.system_time/0`

  #### Metadata

    * `:instance_name` - the `:name` used to start the root supervisor for `Loader`
    * `:load_profile` - profile (`Loader.LoadProfile`)
    * `:scheduled_loader_ref` - (almost) unique reference generated for the process that is handling execution of the profile. Generated with `make_ref/0`
    * `:work_spec` - specification for each task to be executed (`Loader.WorkSpec`)

  ### Load Profile Execution Stop

  `[:loader, :load_profile_execution, :stop]` - emitted when a `LoadProfile` has been fully executed, regardless of the number of successes or failures of individual tasks

  #### Measurements

    * `:duration` - time elapsed since the load profile execution start event

  #### Metadata

    * `:failures` - number of tasks deemed unsuccessful, based on the `WorkSpec`
    * `:instance_name` - the `:name` used to start the root supervisor for `Loader`
    * `:load_profile` - profile (`Loader.LoadProfile`)
    * `:scheduled_loader_ref` - (almost) unique reference generated for the process that handled execution of the profile. Generated with `make_ref/0`
    * `:successes` - number of tasks deemed successful, based on the `WorkSpec`
    * `:work_spec` - specification for each task to be executed (`Loader.WorkSpec`)

  ### Task Start

  `[:loader, :task, :start]` - emitted when the `:task` callback from a `Loader.WorkSpec` is invoked

  #### Measurements

    * `:monotonic_time` - system monotonic time, as reported by `:erlang.monotonic_time/0` (see the `:telemetry` docs `span/3` function for more details)
    * `:system_time` - system time, as reported by `:erlang.system_time/0` (see the `:telemetry` docs `span/3` function for more details)

  #### Metadata

    * `:instance_name` - the `:name` used to start the root supervisor for `Loader`
    * `:scheduled_loader_ref` - (almost) unique reference generated for the process that handled execution of the profile. Generated with `make_ref/0`
    * `:telemetry_span_context` - (almost) unique reference generated for the span execution
    * `:work_spec` - specification for the task (`Loader.WorkSpec`)

  ### Task Stop

  `[:loader, :task, :stop]` - emitted when the `:task` callback from a `Loader.WorkSpec` is invoked

  #### Measurements

    * `:monotonic_time` - system monotonic time, as reported by `:erlang.monotonic_time/0` (see the `:telemetry` docs `span/3` function for more details)
    * `:system_time` - system time, as reported by `:erlang.system_time/0` (see the `:telemetry` docs `span/3` function for more details)

  #### Metadata

    * `:instance_name` - the `:name` used to start the root supervisor for `Loader`
    * `:scheduled_loader_ref` - (almost) unique reference generated for the process that handled execution of the profile. Generated with `make_ref/0`
    * `:telemetry_span_context` - (almost) unique reference generated for the span execution
    * `:was_success?` - whether or not the task was successful, according to the `WorkSpec`
    * `:work_spec` - specification for the task (`Loader.WorkSpec`)

  ### Task Exception

  `[:loader, :task, :exception]` - emitted if there is an uncaught exception while invoking the `:task` callback from a `Loader.WorkSpec`

  #### Measurements

    * `:monotonic_time` - system monotonic time, as reported by `:erlang.monotonic_time/0` (see the `:telemetry` docs `span/3` function for more details)
    * `:system_time` - system time, as reported by `:erlang.system_time/0` (see the `:telemetry` docs `span/3` function for more details)

  #### Metadata

    * `:instance_name` - the `:name` used to start the root supervisor for `Loader`
    * `:kind` - the type of exception
    * `:reason` - whatever reason is given by the exception
    * `:scheduled_loader_ref` - (almost) unique reference generated for the process that handled execution of the profile. Generated with `make_ref/0`
    * `:stacktrace` - the stacktrace of the exception
    * `:telemetry_span_context` - (almost) unique reference generated for the span execution
    * `:work_spec` - specification for the task (`Loader.WorkSpec`)

  """

  @doc false
  # emits a `:start` telemetry event and returns the (monotonic) start_time
  def start(event, meta_data \\ %{}, extra_measurements \\ %{}) do
    start_time = System.monotonic_time()
    system_time = System.system_time()
    measurements = Map.merge(extra_measurements, %{system_time: system_time})

    :telemetry.execute(
      [:loader, event, :start],
      measurements,
      meta_data
    )

    start_time
  end

  @doc false
  # emits a `:stop` telemetry event and returns the (monotonic) stop_time
  def stop(event, start_time, meta_data \\ %{}, extra_measurements \\ %{}) do
    end_time = System.monotonic_time()
    measurements = Map.merge(extra_measurements, %{duration: end_time - start_time})

    :telemetry.execute(
      [:loader, event, :stop],
      measurements,
      meta_data
    )

    end_time
  end

  @doc false
  # emits an `:exception` telemetry event
  def exception(event, start_time, kind, reason, stacktrace, meta_data \\ %{}, extra_measurements \\ %{}) do
    end_time = System.monotonic_time()
    measurements = Map.merge(extra_measurements, %{duration: end_time - start_time})

    meta_data =
      meta_data
      |> Map.put(:kind, kind)
      |> Map.put(:reason, reason)
      |> Map.put(:stacktrace, stacktrace)

    :telemetry.execute(
      [:loader, event, :exception],
      measurements,
      meta_data
    )
  end

  @doc false
  # convenience wrapper for creating telemetry spans
  def span(event, start_meta_data, fun) do
    :telemetry.span(
      [:loader, event],
      start_meta_data,
      fun
    )
  end
end
