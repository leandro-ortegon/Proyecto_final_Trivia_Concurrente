defmodule Trivia.MixProject do
  use Mix.Project

  def project do
    [
      app: :trivia,
      version: "1.0.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # La aplicación OTP decide qué procesos levantar según el rol del nodo
  # (servidor o cliente). Ver Trivia.Application.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Trivia.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
