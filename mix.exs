defmodule Loader.MixProject do
  use Mix.Project

  @name "Loader"

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
      version: "0.5.3"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.0"},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 0.5", only: :test, runtime: false},
      {:styler, "~> 0.8", only: [:dev, :test], runtime: false},
      {:telemetry, "~> 0.4 or ~> 1.2"},
      {:telemetry_metrics, "~> 0.6"}
    ]
  end

  defp description do
    "Load-generation with arbitrary distributions, defined like mathematical functions"
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
