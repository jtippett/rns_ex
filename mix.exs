defmodule RNS.MixProject do
  use Mix.Project

  def project do
    [
      app: :rns_ex,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      dialyzer: [plt_add_apps: [:crypto]],
      name: "RNS",
      description: "Elixir port of the Reticulum Network Stack",
      source_url: "https://github.com/TODO/rns_ex",
      docs: [main: "RNS", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {RNS.Application, []}
    ]
  end

  defp deps do
    [
      {:eddy, "~> 1.0"},
      {:msgpax, "~> 2.4"},
      # Dev/test only
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: :test}
    ]
  end
end
