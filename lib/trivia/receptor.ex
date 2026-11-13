defmodule Trivia.Receptor do
  @moduledoc """
  Proceso del **cliente** que recibe las notificaciones asíncronas del
  servidor (preguntas, resultados de ronda, fin de partida, reinicios…).

  Está separado del proceso que lee el teclado (`Trivia.Cliente`): mientras
  el usuario escribe, el receptor sigue recibiendo y mostrando mensajes.
  Su PID es el que el servidor registra en la sesión y en la partida.

  También vigila el nodo del servidor con `Node.monitor/2` para avisar si
  la conexión se pierde.
  """

  use GenServer, restart: :temporary

  alias Trivia.Presentacion

  @doc "Inicia el receptor bajo el supervisor del cliente."
  def iniciar(nodo_servidor) do
    DynamicSupervisor.start_child(Trivia.SupervisorCliente, {__MODULE__, nodo_servidor})
  end

  def start_link(nodo_servidor), do: GenServer.start_link(__MODULE__, nodo_servidor)

  @doc "Detiene el receptor."
  def detener(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(nodo_servidor) do
    if nodo_servidor != Node.self(), do: Node.monitor(nodo_servidor, true)
    {:ok, %{servidor: nodo_servidor}}
  end

  @impl true
  def handle_info({:trivia, evento}, estado) do
    case Presentacion.evento(evento) do
      nil -> :ok
      texto -> IO.puts(texto)
    end

    {:noreply, estado}
  end

  def handle_info({:nodedown, nodo}, estado) do
    IO.puts(
      "\n⚠ Se perdió la conexión con el servidor #{nodo}. Escribe exit y vuelve a iniciar el cliente."
    )

    {:noreply, estado}
  end

  def handle_info(_mensaje, estado), do: {:noreply, estado}
end
