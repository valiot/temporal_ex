defmodule TemporalEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :temporal_ex,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: "Ergonomic Temporal client SDK for Elixir",
      package: package(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TemporalEx.Application, []}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/valiot/temporal_ex"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:temporalio, "~> 1.21"},
      {:grpc, "~> 0.11"},
      {:castore, "~> 1.0"},
      {:jason, "~> 1.4"},

      # Dev/Test
      {:mox, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
