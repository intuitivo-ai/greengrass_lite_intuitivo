defmodule GreenGrassLite.MixProject do
  use Mix.Project

  @version "0.2.1"

  def project do
    [
      app: :greengrass_lite,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir manager for AWS IoT Greengrass Nucleus Lite daemons on Nerves"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GreenGrassLite.Application, []}
    ]
  end

  defp deps do
    [
      {:muontrap, "~> 1.0"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"}
    ]
  end
end
