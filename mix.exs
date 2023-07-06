defmodule Loader.MixProject do
  @name "Loader"
  @external_resource "README.md"

  use Mix.Project

  def project do
    [
      app: :loader,
      deps: deps(),
      description: description(),
      docs: [
        # The main page in the docs 
        main: @name
      ],
      elixir: "~> 1.14",
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: "0.2.0"
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
      {:decimal, "~> 2.0"},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:stream_data, "~> 0.5", only: :test, runtime: false},
      {:styler, "~> 0.8", only: [:dev, :test], runtime: false},
      {:telemetry, "~> 0.4 or ~> 1.2"}
    ]
  end

  defp description do
    "README.md"
    |> File.read!()
    |> String.split("<!-- DESCRIPTION !-->")
    |> Enum.fetch!(1)
  end

  defp package do
    [
      maintainers: ["Clark Lindsay"],
      licenses: ["MIT"],
      links: %{
        GitHub: "https://github.com/clark-lindsay/loader"
      },
      source_url: "https://github.com/clark-lindsay/loader"
    ]
  end
end
