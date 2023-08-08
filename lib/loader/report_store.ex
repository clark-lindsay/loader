defmodule Loader.LocalReporter.ReportStore do
  # TODO: possible rethink: instead of just holding the measurements, should i be holding the entire
  # event, so that i have everything i could possibly need when i get a call to aggregate stats? 
  # what's the difference in storage and computational overhead?
  # TODO: if timeframe reporting is going to be important, should the ets table be an ordered set?
  # TODO: how much memory can the table consume before it should dump to disk and empty the table?
  # TODO: handle "tags", which will probably require storing the entire event, not just the measurement
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

        {:ok, %{event_name: event_name, metrics: metrics, registry: registry, table_id: table_id}}

      {:error, {:already_registered, pid}} ->
        IO.warn("This process has already been registered with PID: #{inspect(pid)}")

        :ignore

      # TODO: dive the registry source to see if dialyzer is correct here
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
    # the table_id makes it faster to access the ets table for other calls,
    # and should be used instead of the table name
    table_id =
      event_name
      |> telemetry_event_name_to_atom()
      |> :ets.whereis()

    # NOTE: this function needs to make sure that there will not be any
    # write-conflicts with the ets table, since we are not using message-
    # passing to synchronize/ block.

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
              # counter updates are atomic and isolated, and thus don't require a write-lock
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
  # TODO: should these take in the registry, instead of the particular server pid?
  # if they take in the registry, it can call _all_ of the child servers and flush everything at once

  # TODO: should csv be an option so people can load it into spreadsheets?
  # TODO: should have a default file name format, probably configured via host environment vars
  @doc """
  Write the contents of the store out to a file, as specified by the options, and delete all flushed entries from the table when successful.
  ## Options

    * `:file_type` - the format in which the file will be written out. Defaults to `:json`.
      * available values are:
        * `:ets` - uses the binary format from `:ets.tab2file`
        * `:json` - a JSON structure with two keys: `"entry_count"` and `"entries"`
    * `:directory` - the directory where flushed stores will be written. Defaults to `{:absolute, Path.expand("./reports")}`.
  """
  @spec flush_to_file(
          server :: pid(),
          opts :: nil | [file_type: :ets | :json, directory: {:absolute | :relative_to_cwd, binary()}]
        ) :: {:ok, path_to_file :: binary()} | {:error, term()}
  def flush_to_file(server, opts \\ []) do
    GenServer.call(server, {:flush_to_file, opts})
  end

  # TODO: add option for timeframe reporting (and then document); see note at top of module!
  # ^ this may require a re-structuring of the data in the ets table
  # TODO: if we know the location that files are being stored on the local machine, and we get a request
  # for a timeframe report, couldn't we also aggregate those files into the report, so that we aren't limited
  # to what is currently in ETS?
  # TODO: if we're doing all that ^ ... should i just pull in SQLite? and when we "flush" ETS, we create a SQLite
  # dump file?
  @doc """
  Scan all measurements for the `event_name` that are currently stored by the server to produce a report.

  ## Options

    * `:metrics` - a list of metric names to be included in the report. Metrics unknown to this `ReportStore` instance will be ignored. Defaults to `:all`.
  """
  @spec report(server :: pid(), opts :: nil | [metrics: [Telemetry.Metrics.normalized_metric_name()]]) :: %{
          optional(Telemetry.Metrics.normalized_metric_name()) =>
            number() | %Loader.Stats.Summary{} | Loader.Stats.histogram()
        }
  def report(server, opts \\ []) do
    GenServer.call(server, {:report, opts})
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
  def handle_call({:flush_to_file, opts}, _from, state) do
    # TODO: report directory is something that should also be configurable from an env var
    opts =
      opts
      |> Keyword.put_new(:directory, {:absolute, Path.expand("./reports")})
      |> Keyword.put_new(:file_type, :json)

    file_name =
      String.replace(
        telemetry_event_name_to_string(state.event_name) <> DateTime.to_string(DateTime.utc_now()),
        ~r/\s/,
        "_"
      )

    directory =
      case opts[:directory] do
        {:absolute, path} ->
          path

        {:relative_to_cwd, path} ->
          Path.expand(path)
      end

    file_path = Path.join(directory, file_name)

    write_status =
      case opts[:file_type] do
        :json ->
          # `:ets.foldl/3` has an unspecified traversal order, and so measurements will be out
          # of order unless a sort step is taken
          {entries, count} =
            :ets.foldl(
              fn {ref, name, measurement}, {list, count} ->
                {[[inspect(ref), name, measurement] | list], count + 1}
              end,
              {[], 0},
              state.table_id
            )

          with :ok <- File.mkdir_p(directory),
               {:ok, io_json} <-
                 Jason.encode_to_iodata(%{
                   "entry_count" => count,
                   "entries" => entries
                 }) do
            File.write(file_path <> ".json", io_json)
          end

        :ets ->
          with :ok <- File.mkdir_p(directory) do
            :ets.tab2file(state.table_id, String.to_charlist(file_path), extended_info: [:object_count])
          end
      end

    if write_status == :ok do
      # TODO: do i need to lock the table during this operation?
      # if we start time-stamping entries, we can just do a select-delete instead
      :ets.delete_all_objects(state.table_id)

      {:reply, {:ok, file_path}, state}
    else
      {:reply, write_status, state}
    end
  end

  @impl GenServer
  def handle_call({:report, opts}, _from, state) do
    metrics = opts[:metrics] || :all

    name_to_metric =
      if metrics == :all do
        Enum.reduce(state.metrics, %{}, &Map.put(&2, &1.name, &1))
      else
        for metric <- state.metrics, metric.name in metrics, reduce: %{} do
          acc -> Map.put(acc, metric.name, metric)
        end
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
            buckets =
              case Keyword.get(metric.reporter_options, :buckets) do
                nil ->
                  # if there are no `buckets` in `reporter_options`, calculate a summary
                  # and use [min, p25, median, p75] as the buckets
                  summary = Loader.Stats.summarize(measurements)

                  [summary.min, summary.percentiles[25], summary.median, summary.percentiles[75]]

                buckets when is_list(buckets) ->
                  buckets

                {:percentiles, percentile_buckets} ->
                  %{percentiles: percentiles} =
                    Loader.Stats.summarize(measurements, percentile_targets: percentile_buckets)

                  Map.values(percentiles)
              end

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

  defp keep?(%{keep: nil, drop: nil}, _metadata), do: true
  defp keep?(%{keep: keep}, metadata), do: keep.(metadata)
  defp keep?(%{drop: drop}, metadata), do: not(drop.(metadata))

  defp telemetry_event_name_to_atom(event_name) do
    event_name |> telemetry_event_name_to_string() |> String.to_atom()
  end

  defp telemetry_event_name_to_string(event_name) do
    Enum.map_join(event_name, ".", &Atom.to_string/1)
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
