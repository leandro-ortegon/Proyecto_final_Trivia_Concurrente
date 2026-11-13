defmodule Trivia.SupervisorPartidas do
  @moduledoc """
  `DynamicSupervisor` que inicia y supervisa los procesos `Trivia.Partida`.

  Cada partida es un hijo independiente con `restart: :transient`:

    * si termina normalmente (fin de juego, abandono) no se reinicia;
    * si falla, se reinicia con sus argumentos iniciales sin afectar a las
      demás partidas ni al servidor (estrategia `:one_for_one`).

  La intensidad de reinicios es alta a propósito: un supervisor que supera
  su intensidad muere y arrastra a todos sus hijos, y aquí cada hijo es una
  partida de un jugador distinto.
  """

  use DynamicSupervisor

  @max_reinicios 50
  @ventana_segundos 10

  def start_link(opciones \\ []) do
    nombre = Keyword.get(opciones, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: nombre)
  end

  @doc "Inicia una partida supervisada."
  @spec iniciar_partida(Supervisor.supervisor(), map()) :: DynamicSupervisor.on_start_child()
  def iniciar_partida(supervisor \\ __MODULE__, argumentos),
    do: DynamicSupervisor.start_child(supervisor, {Trivia.Partida, argumentos})

  @doc "PIDs de las partidas vivas."
  @spec partidas(Supervisor.supervisor()) :: [pid()]
  def partidas(supervisor \\ __MODULE__) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor), is_pid(pid), do: pid
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: @max_reinicios,
      max_seconds: @ventana_segundos
    )
  end
end
