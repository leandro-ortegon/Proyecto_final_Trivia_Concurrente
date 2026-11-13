defmodule Trivia.SupervisorBots do
  @moduledoc """
  `DynamicSupervisor` de los bots. Cada bot es un proceso independiente
  con `restart: :temporary`: un bot que falla no se reinicia y no afecta a
  su partida (esta cierra la ronda por tiempo). Cuando una partida termina
  o se reinicia, sus bots se detienen porque monitorean a la partida.
  """

  use DynamicSupervisor

  def start_link(opciones \\ []) do
    nombre = Keyword.get(opciones, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: nombre)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
