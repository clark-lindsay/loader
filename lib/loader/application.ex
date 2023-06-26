defmodule Loader.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Loader.Finch},
      {Task.Supervisor, name: Loader.TaskSupervisor},
      {DynamicSupervisor, name: Loader.DynamicSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Loader.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
