defmodule Loader.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Loader.ExecutionStore, %{}},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Loader.TaskSupervisors},
      {DynamicSupervisor, name: Loader.DynamicSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Loader.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
