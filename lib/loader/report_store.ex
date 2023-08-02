defmodule Loader.LocalReporter.ReportStore do
  # TODO: possible rethink: instead of just holding the measurements, should i be holding the entire
  # event, so that i have everything i could possibly need when i get a call to aggregate stats? 
  # what's the difference in storage and computational overhead?
  @moduledoc """
  This GenServer creates a new `ets` table for storing measurements
  for the `:metric` option, and registers itself with the provided registry. 

  Its purpose is to store all values that may be needed to create metric reports,
  for a single event name (e.g. `[:http_client, :request, :stop]`), and make it
  easy to manage and isolate the ownership and lifecycle of the `ets` table.

  All entries in the `ets` table "held" by this process should have the following format:
  ```
  {
    nearly_unique_ref OR `[:counter | metric_name]` OR `[:last_value | metric_name]`, # refs via make_ref/0
    metric_name, # e.g. `[:http_client, :request, :stop, :duration]`
    metric_measurement, # number, as `nil`s are ignored
  }
  ```
  """

  use GenServer

  # tuple indices in `ets` are 1-indexed
  @measurement_position 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    metrics = opts[:metrics] || raise(ArgumentError, "the :metrics option is required by #{inspect(__MODULE__)}")

    if Enum.any?(metrics, fn metric ->
         metric.event_name != hd(metrics).event_name
       end) do
      raise(
        ArgumentError,
        "the `:metrics` option for #{inspect(__MODULE__)} cannot be empty, and all metrics must have the same event name"
      )
    end

    registry = opts[:registry] || raise(ArgumentError, "the :registry option is required by #{inspect(__MODULE__)}")

    %{event_name: event_name} = hd(metrics)

    case Registry.register(registry, event_name, metrics) do
      {:ok, _} ->
        table_id =
          event_name
          |> telemetry_event_name_to_atom()
          |> :ets.new([:named_table, :set, :public])

        {:ok, %{metrics: metrics, registry: registry, table_id: table_id}}

      {:error, {:already_registered, pid}} ->
        IO.warn("This process has already been registered with PID: #{inspect(pid)}")

        :ignore

      # Dialyzer says that this can never match... is that true?
      # the spec agrees, but is the spec wrong? need to dive the source
      {:error, term} ->
        IO.warn("Error when registering a #{inspect(__MODULE__)} for event: #{inspect(event_name)}")
        raise term
    end
  end

  # ----- Client Interface -----

  @spec record_measurement(:telemetry.event_name(), map(), map(), {Registry.registry(), [Telemetry.Metrics.t()]}) ::
          [{:ok, reference() | [atom()] | {:cast, [atom()]}} | {:error, term()}] | {:error, term()}
  def record_measurement(event_name, measurements, metadata, {registry, metrics}) do
    # NOTE: the table_id makes it faster to access the ets table for other calls,
    # and should be used instead of the table name
    table_id =
      event_name
      |> telemetry_event_name_to_atom()
      |> :ets.whereis()

    # TODO: return an error if there is no measurement? or is that ok?
    # TODO: should this module deal with `keep?`

    # NOTE: this function needs to make sure that there will not be any
    # write-conflicts with the ets table, since we are not using message-
    # passing to synchronize/ block.

    # variables:
    #   - measurement -> nil or not
    #   - keep? -> true or false
    #   - ets table? -> exists or doesn't

    # TODO: would it be better to use the registry to shorten this list? or is the filter fast enough?
    if table_id != :undefined do
      for metric <- metrics, event_name == metric.event_name, keep?(metric, metadata) do
        measurement = extract_measurement(metric, measurements, metadata)

        if not is_nil(measurement) do
          %metric_type{name: metric_name} = metric

          insert_measurement = fn ->
            ref = make_ref()

            if :ets.insert_new(table_id, {ref, metric_name, measurement}) do
              {:ok, ref}
            else
              {:error, "insert into ETS table failed"}
            end
          end

          case metric_type do
            Telemetry.Metrics.Counter ->
              # updates are atomic and isolated, and thus don't require a write-lock
              :ets.update_counter(
                table_id,
                [:counter | metric_name],
                {@measurement_position, 1},
                {[:counter | metric_name], metric_name, 0}
              )

              {:ok, [:counter | metric_name]}

            Telemetry.Metrics.LastValue ->
              [{event_server_pid, _value}] = Registry.lookup(registry, event_name)
              GenServer.cast(event_server_pid, {:new_last_value, {metric, measurement}})

              {:ok, {:cast, [:last_value | metric_name]}}

            Telemetry.Metrics.Summary ->
              insert_measurement.()

            Telemetry.Metrics.Distribution ->
              insert_measurement.()

            Telemetry.Metrics.Sum ->
              insert_measurement.()

            _other ->
              {:error, "must be a Telemetry.Metrics struct"}
          end
        end
      end
    else
      {:error, "ETS table does not exist for this event"}
    end
  end

  # TODO: should this take an option so a user can get partial reports, just for the
  # particular metric(s) they're interested in at the time?
  # TODO: should have a default file name format, probably configured via host environment vars
  # TODO: should these take in the registry, instead of the particular server pid?
  # if they take in the registry, it can call _all_ of the child servers and flush everything at once
  # TODO: add docs
  def flush_measurements_to_file(server, filename) do
    GenServer.call(server, {:flush_to_file, filename})
  end

  # TODO: add docs
  # TODO: add option for timeframe reporting
  def report(server, opts \\ []) do
    metrics = opts[:metrics] || :all

    GenServer.call(server, {:report, metrics})
  end

  # ----- Message Handling -----

  @impl GenServer
  def handle_cast({:new_last_value, {metric, measurement}}, state) do
    # updates are _not_ isolated, and thus require a write-lock (via casting to the ets-owner process)
    # to maintain that guarantee
    if match?([{_key, _metric_name, _measurement}], :ets.lookup(state.table_id, [:last_value | metric.name])) do
      :ets.update_element(state.table_id, [:last_value | metric.name], {@measurement_position, measurement})
    else
      :ets.insert_new(state.table_id, {[:last_value | metric.name], metric.name, measurement})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:flush_to_file, _filename}, _from, state) do
    # TODO: write all measurements from `ets` out to a file
    # should it be csv so people can load it into spreadsheets?

    # TODO: replace with file location that we wrote to
    {:reply, "file_name", state}
  end

  @impl GenServer
  def handle_call({:report, metrics}, _from, state) do
    # TODO: calculate all report stats, and return as a map: `%{metric_name => %Summary{}}`
    name_to_metric =
      if metrics == :all do
        Enum.reduce(state.metrics, %{}, &Map.put(&2, &1.name, &1))
      else
        Enum.reduce(metrics, %{}, &Map.put(&2, &1.name, &1))
      end

    report_measurements =
      :ets.foldl(
        fn element, acc ->
          case element do
            {[:counter | _remaining_metric_name], metric_name, measurement} ->
              if Map.has_key?(name_to_metric, metric_name) do
                Map.put(acc, metric_name, {Map.fetch!(name_to_metric, metric_name), measurement})
              else
                acc
              end

            {[:last_value | _remaining_metric_name], metric_name, measurement} ->
              if Map.has_key?(name_to_metric, metric_name) do
                Map.put(acc, metric_name, {Map.fetch!(name_to_metric, metric_name), measurement})
              else
                acc
              end

            {_unique_ref, metric_name, measurement} ->
              if Map.has_key?(name_to_metric, metric_name) do
                Map.update(
                  acc,
                  metric_name,
                  {Map.fetch!(name_to_metric, metric_name), [measurement]},
                  &{elem(&1, 0), [measurement | elem(&1, 1)]}
                )
              else
                acc
              end
          end
        end,
        %{},
        state.table_id
      )

    report =
      for {key, {metric, measurements}} <- report_measurements, into: %{} do
        type = metric_type(metric)

        case type do
          :summary ->
            {key, Loader.Stats.summarize(measurements)}

          :distribution ->
            # TODO: add a "percentiles" option for `reporter_options` so that one can ask for percentiles as buckets,
            # e.g. `reporter_options: [buckets: {:percentiles, [0, 25, 50, 75, 90, 95, 99]}]`
            # if there are no `buckets` in `reporter_options`, calculate a summary
            # and use [min, p25, median, p75] as the buckets
            buckets =
              Keyword.get_lazy(metric.reporter_options, :buckets, fn ->
                if Enum.empty?(measurements) do
                  []
                else
                  summary = Loader.Stats.summarize(measurements)

                  [summary.min, summary.percentiles[25], summary.median, summary.percentiles[75]]
                end
              end)

            {key, Loader.Stats.to_histogram(measurements, buckets)}

          :sum ->
            {key, Enum.sum(measurements)}

          _last_value_or_counter ->
            {key, measurements}
        end
      end

    {:reply, report, state}
  end

  # ----- Private Functions -----

  defp extract_measurement(metric, measurements, metadata) do
    measurement =
      case metric.measurement do
        fun when is_function(fun, 2) -> fun.(measurements, metadata)
        fun when is_function(fun, 1) -> fun.(measurements)
        key -> measurements[key]
      end

    if is_number(measurement) do
      measurement
    else
      nil
    end
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp telemetry_event_name_to_atom(event_name) do
    event_name |> Enum.map_join(".", &Atom.to_string/1) |> String.to_atom()
  end

  defp metric_type(%struct{} = _metric) do
    case struct do
      Telemetry.Metrics.Counter -> :counter
      Telemetry.Metrics.Sum -> :sum
      Telemetry.Metrics.LastValue -> :last_value
      Telemetry.Metrics.Distribution -> :distribution
      Telemetry.Metrics.Summary -> :summary
    end
  end
end
