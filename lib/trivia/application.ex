defmodule Trivia.Application do
  @moduledoc """
  Aplicación OTP de Trivia Concurrente.

  El mismo proyecto Mix se ejecuta en el servidor y en los clientes; el
  rol del nodo decide qué procesos se levantan:

    * **Servidor** (nodo `servidor@host`, o variable `TRIVIA_ROL=servidor`):
      persistencia, banco de preguntas, gestores, supervisores de partidas
      y bots, y el `Trivia.Servidor` registrado globalmente.
    * **Cliente** (cualquier otro nodo): solo el supervisor del receptor de
      notificaciones. Un cliente nunca abre los archivos de datos.

  Árbol de supervisión del servidor (`:one_for_one`):

      Trivia.Supervisor
      ├── Trivia.Persistencia        (GenServer, único acceso a archivos)
      ├── Trivia.BancoPreguntas      (GenServer)
      ├── Trivia.GestorJugadores     (GenServer)
      ├── Trivia.SupervisorBots      (DynamicSupervisor)
      ├── Trivia.SupervisorPartidas  (DynamicSupervisor)
      ├── Trivia.GestorPartidas      (GenServer)
      ├── Trivia.TareasServidor      (Task.Supervisor)
      └── Trivia.Servidor            (GenServer, {:global, :trivia_servidor})
  """

  use Application
  require Logger

  @impl true
  def start(_tipo, _argumentos) do
    rol = rol()

    if rol == :servidor,
      do: Logger.info("Iniciando Trivia Concurrente como SERVIDOR en #{Node.self()}")

    Supervisor.start_link(hijos(rol), strategy: :one_for_one, name: Trivia.Supervisor)
  end

  @doc "Rol del nodo actual: `:servidor` o `:cliente`."
  @spec rol() :: :servidor | :cliente
  def rol do
    nombre_servidor = Application.get_env(:trivia, :nombre_servidor, "servidor")

    cond do
      System.get_env("TRIVIA_ROL") == "servidor" -> :servidor
      System.get_env("TRIVIA_ROL") == "cliente" -> :cliente
      Node.self() |> Atom.to_string() |> String.starts_with?(nombre_servidor <> "@") -> :servidor
      true -> :cliente
    end
  end

  defp hijos(:servidor) do
    [
      Trivia.Persistencia,
      Trivia.BancoPreguntas,
      Trivia.GestorJugadores,
      Trivia.SupervisorBots,
      Trivia.SupervisorPartidas,
      Trivia.GestorPartidas,
      {Task.Supervisor, name: Trivia.TareasServidor},
      Trivia.Servidor
    ]
  end

  defp hijos(:cliente) do
    [{DynamicSupervisor, name: Trivia.SupervisorCliente, strategy: :one_for_one}]
  end
end
