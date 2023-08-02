defmodule Loader.LocalReporter do
  @moduledoc """
  ## Options

    * `:name` - **Required.** The name of the reporter instance. Functions as described in the "Name registration" section in the `GenServer` module docs.
    * `:metrics` - **Required.** The list of `Telemetry.Metrics` structs to be reported on.

  ### Reporter Options

  Additional options can be passed to the metric definitions, depending on the type of metric.
  All metrics will use the `:reporter_options` key to pass these options.

  #### Distribution (histogram)

    * `:buckets` - Define buckets to group measurements into. However the buckets are defined, a measurement will fall into a bucket when `bucket_fencepost <= value < next_largest_fencepost`. Values that do not fall into one of the defined buckets (e.g. a negative measurement that was not anticipated) will go into a bucket with the key `:out_of_range`. Defaults to `{:percentiles, [0, 25, 50. 75]}`. Buckets can be defined in one of two ways:
      * as a list, e.g. `[0, 1_000, 5_000, 10_000]`
      * as percentiles, e.g. `{:percentiles, [0, 25, 50, 75, 90, 95, 99]}`

  #### Summary

    * `:mode_rounding_places` - The number of decimal places to which measurements will be rounded for aggregating the "mode". Defaults to `4`.
    * `:percentile_targets` - The percentile values to be returned in the summary. Defaults to `[25, 50, 75, 90, 95, 99]`.

  """
  use Supervisor

  alias Loader.LocalReporter.ReportStore

  def start_link(opts) do
    supervisor_opts = Keyword.take(opts, [:name])

    Supervisor.start_link(__MODULE__, opts, supervisor_opts)
  end

  @impl Supervisor
  def init(opts) do
    metrics =
      opts[:metrics] ||
        raise ArgumentError, "the :metrics option is required by #{inspect(__MODULE__)}"

    name =
      opts[:name] ||
        raise ArgumentError, "the :name option is required by #{inspect(__MODULE__)}"

    groups = Enum.group_by(metrics, & &1.event_name)

    for {event, metrics} <- groups do
      id = {__MODULE__, event, self()}

      :ok = :telemetry.attach(id, event, &__MODULE__.handle_event/4, metrics: metrics, name: name)
    end

    children = [
      {Registry, name: registry_name(name), keys: :unique},
      {DynamicSupervisor, name: {:via, Registry, {registry_name(name), DynamicSupervisor}}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def report(instance_name, event_name, opts \\ []) do
    registry = registry_name(instance_name)

    case Registry.lookup(registry, event_name) do
      [{report_store_pid, _value}] ->
        ReportStore.report(report_store_pid, opts)

      _ ->
        {:error, "Multiple stores found with the same event name"}
    end
  end

  def handle_event(event_name, measurements, metadata, config) do
    name = config[:name]
    registry = registry_name(name)
    metrics = config[:metrics]
    report_store_config = {registry, metrics}

    case Registry.lookup(registry, event_name) do
      [_report_store_entry] ->
        ReportStore.record_measurement(event_name, measurements, metadata, report_store_config)

      [] ->
        [{dynamic_supervisor_pid, _value}] = Registry.lookup(registry, DynamicSupervisor)

        DynamicSupervisor.start_child(
          dynamic_supervisor_pid,
          {Loader.LocalReporter.ReportStore, Keyword.merge(config, registry: registry)}
        )

        ReportStore.record_measurement(event_name, measurements, metadata, report_store_config)

      _length_greater_than_1 ->
        # TODO: should maybe restart the whole supervisor after logging a useful error struct
        IO.warn("More than 1 process registered for a single event_name!!")
    end
  end

  defp registry_name(instance_name), do: String.to_atom("#{instance_name}.Registry")
end
