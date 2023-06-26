defmodule Loader.MixProject do
  use Mix.Project

  def project do
    [
      app: :loader,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Loader.Application, []}
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.16"},
      {:decimal, "~> 2.0"}
    ]
  end
end
