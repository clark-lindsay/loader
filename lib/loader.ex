defmodule Loader do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  defmodule WorkResponse do
    @moduledoc """
    The response type that all "tasks" should use in their return type,
    returning either a single "response" or a list of them.
    """
    defstruct [:response, :response_time]

    @type t :: %__MODULE__{
            response: any(),
            response_time: integer()
          }
  end

  defmodule WorkSpec do
    @moduledoc """
    A specification for some "work" to do, to generate load.
    """
    defstruct [:task, :is_success?]

    @type t :: %__MODULE__{
            task: (() -> Loader.WorkResponse.t() | [Loader.WorkResponse.t()]) | mfa(),
            is_success?: (Loader.WorkResponse.t() -> boolean())
          }
  end

  @doc """
  Time measurements in the results are given in **microseconds** (i.e. 10^(-6))
  """
  def send_requests(http_method, uri, opts \\ []) do
    count = opts[:count] || 1
    headers = opts[:headers] || []
    body = opts[:body] || nil

    Task.Supervisor.async_stream_nolink(Loader.TaskSupervisor, 1..count, fn req_index ->
      body =
        if is_function(body) do
          body.(req_index)
        else
          body
        end

      req_start = System.monotonic_time()

      # don't care if the tag is `:ok` or `:error`, it's up to the callback in the `WorkSpec` to
      # decide what's good and what's bad
      response =
        Finch.build(http_method, uri, headers, body)
        |> Finch.request(Loader.Finch)

      %Loader.WorkResponse{
        response: response,
        response_time:
          (System.monotonic_time() - req_start)
          |> System.convert_time_unit(:native, :microsecond)
      }
    end)
    |> Enum.map(fn {_tag, response} -> response end)
  end

  @doc """
  Execute tasks from the `work_spec` based on the parameters in the `load_profile`
  """
  @spec execute_profile(Loader.LoadProfile.t(), Loader.WorkSpec.t()) ::
          DynamicSupervisor.on_start_child()
  def execute_profile(load_profile, work_spec) do
    DynamicSupervisor.start_child(
      Loader.DynamicSupervisor,
      Loader.ScheduledLoader.child_spec(load_profile: load_profile, work_spec: work_spec)
    )
  end

  @doc """
  Execute several `LoadProfile`s simultaneously, each with their supplied `WorkSpec`
  """
  @spec execute_profiles([{Loader.LoadProfile.t(), Loader.WorkSpec.t()}]) :: [
          DynamicSupervisor.on_start_child()
        ]
  def execute_profiles(profile_spec_pairs) do
    Enum.map(profile_spec_pairs, fn {profile, spec} -> execute_profile(profile, spec) end)
  end
end
