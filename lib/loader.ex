defmodule Loader do
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  use Supervisor

  @external_resource "README.md"

  defmodule WorkResponse do
    @moduledoc """
    Internal data structure used to represent the results of executing a `WorkSpec`

    ## Properties

      - `:data` -  whatever important data is returned by the work

      - `:response_time` - **must be an integer number, in microseconds**, which is the "client-side" view of how long the work took. I recommend using `System.monotonic_time/0` or `:timer.tc/1`
    """
    defstruct [:data, :kind, :response_time]

    @type t :: %__MODULE__{
            data: any(),
            kind: :ok | :error,
            response_time: integer()
          }
  end

  defmodule WorkSpec do
    @moduledoc """
    A specification for some "work" to do, to generate load.
    """
    # TODO: should a `reason` be attached to the `is_success?` callback? so that a user can do something like `{false, "too slow"}`?
    defstruct [:task, :is_success?]

    @type t :: %__MODULE__{
            task: (() -> term()) | mfa(),
            is_success?: (Loader.WorkResponse.t() -> boolean())
          }
  end

  @doc """
  Start an instance of `Loader`

  ## Options

    * `:name` - The name of your Loader instance. This field is required.
  """
  def start_link(opts) do
    name = opts[:name] || raise(ArgumentError, "must supply a name")

    config = %{
      dynamic_supervisor_name: dynamic_supervisor_name(name),
      execution_store_name: execution_store_name(name),
      task_supervisors_name: task_supervisors_name(name)
    }

    Supervisor.start_link(__MODULE__, config, name: :"#{name}.Supervisor")
  end

  def child_spec(opts) do
    %{
      id: opts[:name] || raise(ArgumentError, "must supply a name"),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl Supervisor
  def init(config) do
    children = [
      # {Loader.LocalReporter,
      #  name: LocalReporter,
      #  metrics: [
      #    Telemetry.Metrics.last_value("loader.task.stop.last_value",
      #      event_name: "loader.task.stop",
      #      measurement: :duration,
      #      unit: {:native, :microsecond}
      #    ),
      #    Telemetry.Metrics.counter("loader.task.stop.counter", event_name: "loader.task.stop", measurement: :duration),
      #    Telemetry.Metrics.sum("loader.task.stop.sum", event_name: "loader.task.stop", measurement: :duration),
      #    Telemetry.Metrics.summary("loader.task.stop.summary",
      #       reporter_options: [mode_rounding_places: 0, percentile_targets: [0, 10, 25, 75, 90, 95, 99]],
      #      event_name: "loader.task.stop",
      #       measurement: :duration,
      #      tags: [:scheduled_loader_ref, :work_spec, :instance_name],
      #      tag_values: fn metadata ->
      #        %{
      #          scheduled_loader_ref: metadata |> Map.get(:scheduled_loader_ref, "") |> inspect(),
      #          work_spec: metadata |> Map.get(:work_spec, "") |> inspect(),
      #          instance_name: Map.fetch!(metadata, :instance_name)
      #        }
      #      end,
      #      unit: {:native, :microsecond}
      #    ),
      #    Telemetry.Metrics.distribution("loader.task.stop.distribution",
      #     reporter_options: [buckets: {:percentiles, [0, 10, 25, 75, 90, 95, 99]}],
      #      event_name: "loader.task.stop",
      #       measurement: :duration,
      #      tags: [:scheduled_loader_ref, :work_spec, :instance_name],
      #      tag_values: fn metadata ->
      #        %{
      #          scheduled_loader_ref: metadata |> Map.get(:scheduled_loader_ref, "") |> inspect(),
      #          work_spec: metadata |> Map.get(:work_spec, "") |> inspect(),
      #          instance_name: Map.fetch!(metadata, :instance_name)
      #        }
      #      end,
      #      unit: {:native, :microsecond}
      #    )
      #  ]},
      {Loader.ExecutionStore, name: config.execution_store_name},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: config.task_supervisors_name},
      {DynamicSupervisor, name: config.dynamic_supervisor_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Execute tasks defined by the `work_spec`, scheduled based on the `load_profile`. When provided with a list, all profiles will be executed concurrently.

  See `Loader.LoadProfile` for more information on how to define a profile.
  """
  @spec execute({Loader.LoadProfile.t(), Loader.WorkSpec.t()}, atom()) ::
          DynamicSupervisor.on_start_child()
  def execute({load_profile, work_spec}, instance_name) do
    DynamicSupervisor.start_child(
      dynamic_supervisor_name(instance_name),
      Loader.ScheduledLoader.child_spec(load_profile: load_profile, work_spec: work_spec, instance_name: instance_name)
    )
  end

  @spec execute([{Loader.LoadProfile.t(), Loader.WorkSpec.t()}], atom()) :: [
          DynamicSupervisor.on_start_child()
        ]
  def execute(profile_spec_pairs, instance_name) do
    Enum.map(profile_spec_pairs, fn {profile, spec} -> execute({profile, spec}, instance_name) end)
  end

  @doc false
  def execution_store_name(instance_name), do: :"#{instance_name}.ExecutionStore"
  @doc false
  def task_supervisors_name(instance_name), do: :"#{instance_name}.TaskSupervisors"
  @doc false
  def dynamic_supervisor_name(instance_name), do: :"#{instance_name}.DynamicSupervisor"
end
