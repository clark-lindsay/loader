defmodule Loader do
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

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
    # TODO: should a user be able to specify a task that does not take a count? could we batch them ourselves?
    # is it a good design to force the user to tell us how to execute their work in
    # batches?
    # maybe they can give us either `arity-0 func`, `arity-1 func`, or `{arity-0, arity-1}` and we
    # handle batching as best we can?
    # TODO: should a `reason` be attached to the `is_success?` callback? so that a user can do something like `{false, "too slow"}`?
    defstruct [:task, :is_success?]

    @type t :: %__MODULE__{
            task: (() -> term()) | mfa(),
            is_success?: (Loader.WorkResponse.t() -> boolean())
          }
  end

  @doc """
  Execute tasks based on the `work_spec`, scheduled based on the parameters in the `load_profile`
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
