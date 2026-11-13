defmodule Trivia.GestorPartidas do
  @moduledoc """
  Registro de las partidas activas del servidor.

  Responsabilidades:

    * Crear partidas bajo `Trivia.SupervisorPartidas` con un identificador
      único, garantizando que un jugador participe en una sola partida a la vez.
    * Ubicar el proceso de la partida de un jugador.
    * Detectar los reinicios: cada partida avisa con un **cast** desde su
      `init/1`. Si el PID cambió, hubo un reinicio y se notifica al creador.
    * Liberar al jugador cuando su partida termina.

  Este proceso nunca hace llamadas síncronas a una partida mientras atiende
  una petición, de modo que una partida lenta o caída no lo bloquea.
  """

  use GenServer
  require Logger

  alias Trivia.{Partida, SupervisorPartidas}

  @espera_reinicio_ms 2_000

  # ===========================================================================
  # API pública
  # ===========================================================================

  @doc "Inicia el gestor. Opciones: `:name` y `:supervisor` (de partidas)."
  def start_link(opciones \\ []) do
    nombre = Keyword.get(opciones, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opciones, name: nombre)
  end

  @doc """
  Crea una partida. `argumentos` contiene `:creador`, `:pid_cliente`,
  `:tema`, `:nivel`, `:tiempo` y `:preguntas` (ya sorteadas).
  """
  @spec crear(GenServer.server(), map()) ::
          {:ok, %{id: String.t(), pid: pid()}} | {:error, atom()}
  def crear(servidor \\ __MODULE__, argumentos),
    do: GenServer.call(servidor, {:crear, argumentos})

  @doc "PID de la partida en la que participa el jugador."
  @spec partida_de(GenServer.server(), String.t()) :: {:ok, pid()} | {:error, :sin_partida}
  def partida_de(servidor \\ __MODULE__, usuario),
    do: GenServer.call(servidor, {:partida_de, usuario})

  @doc "Lista de las partidas activas."
  @spec listar(GenServer.server()) :: [map()]
  def listar(servidor \\ __MODULE__), do: GenServer.call(servidor, :listar)

  @doc """
  Provoca un fallo en la partida indicada (solo para demostración desde la
  consola del servidor): `Trivia.GestorPartidas.simular_fallo("P-1A2B3C")`.
  """
  @spec simular_fallo(GenServer.server(), String.t()) :: :ok | {:error, :sin_partida}
  def simular_fallo(servidor \\ __MODULE__, id) do
    case GenServer.call(servidor, {:pid_de_partida, id}) do
      {:ok, pid} -> Partida.simular_fallo(pid)
      error -> error
    end
  end

  # ===========================================================================
  # Callbacks
  # ===========================================================================

  @impl true
  def init(opciones) do
    estado = %{
      supervisor: Keyword.get(opciones, :supervisor, SupervisorPartidas),
      # id => %{pid, ref, creador, pid_cliente, tema}
      partidas: %{},
      # usuario => id
      jugadores: %{}
    }

    {:ok, estado, {:continue, :recuperar_partidas}}
  end

  # Si este gestor se reinicia, reconstruye su registro a partir de las
  # partidas que siguen vivas bajo el supervisor.
  @impl true
  def handle_continue(:recuperar_partidas, estado) do
    estado =
      estado.supervisor
      |> partidas_vivas()
      |> Enum.reduce(estado, fn pid, acc ->
        case Partida.resumen(pid) do
          %{id: id} = resumen -> registrar(acc, id, pid, resumen)
          {:error, _} -> acc
        end
      end)

    {:noreply, estado}
  end

  @impl true
  def handle_call({:crear, argumentos}, _from, estado) do
    creador = Map.fetch!(argumentos, :creador)

    if Map.has_key?(estado.jugadores, creador) do
      {:reply, {:error, :ya_en_partida}, estado}
    else
      id = generar_id(estado)

      case SupervisorPartidas.iniciar_partida(estado.supervisor, Map.put(argumentos, :id, id)) do
        {:ok, pid} ->
          {:reply, {:ok, %{id: id, pid: pid}}, registrar(estado, id, pid, argumentos)}

        {:error, motivo} ->
          Logger.error("No se pudo iniciar la partida: #{inspect(motivo)}")
          {:reply, {:error, :error_interno}, estado}
      end
    end
  end

  def handle_call({:partida_de, usuario}, _from, estado) do
    with {:ok, id} <- Map.fetch(estado.jugadores, usuario),
         {:ok, %{pid: pid}} <- Map.fetch(estado.partidas, id) do
      {:reply, {:ok, pid}, estado}
    else
      :error -> {:reply, {:error, :sin_partida}, estado}
    end
  end

  def handle_call({:pid_de_partida, id}, _from, estado) do
    case Map.fetch(estado.partidas, id) do
      {:ok, %{pid: pid}} -> {:reply, {:ok, pid}, estado}
      :error -> {:reply, {:error, :sin_partida}, estado}
    end
  end

  def handle_call(:listar, _from, estado) do
    lista =
      Enum.map(estado.partidas, fn {id, p} ->
        %{id: id, creador: p.creador, tema: p.tema, pid: p.pid}
      end)

    {:reply, lista, estado}
  end

  @impl true
  def handle_cast({:partida_iniciada, id, pid}, estado) do
    case Map.fetch(estado.partidas, id) do
      {:ok, %{pid: ^pid}} -> {:noreply, estado}
      {:ok, partida} -> {:noreply, registrar_reinicio(estado, id, partida, pid)}
      :error -> {:noreply, estado}
    end
  end

  def handle_cast({:partida_terminada, id, pid}, estado),
    do: {:noreply, eliminar_si_coincide(estado, id, pid)}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, motivo}, estado) do
    case buscar_por_ref(estado, ref) do
      nil ->
        {:noreply, estado}

      id when motivo in [:normal, :shutdown] ->
        {:noreply, eliminar_si_coincide(estado, id, pid)}

      id ->
        # Fallo: el supervisor la reiniciará y la nueva instancia avisará
        # con :partida_iniciada. Si no llega a tiempo, se libera al jugador.
        Logger.warning("La partida #{id} falló (#{inspect(motivo)}); esperando su reinicio")
        Process.send_after(self(), {:verificar_reinicio, id, pid}, @espera_reinicio_ms)
        {:noreply, estado}
    end
  end

  def handle_info({:verificar_reinicio, id, pid_anterior}, estado) do
    case Map.fetch(estado.partidas, id) do
      {:ok, %{pid: ^pid_anterior} = partida} ->
        send(partida.pid_cliente, {:trivia, {:partida_perdida, %{id: id}}})
        {:noreply, eliminar(estado, id)}

      _ya_reiniciada_o_eliminada ->
        {:noreply, estado}
    end
  end

  def handle_info(_mensaje, estado), do: {:noreply, estado}

  # ===========================================================================
  # Lógica interna
  # ===========================================================================

  defp registrar(estado, id, pid, datos) do
    partida = %{
      pid: pid,
      ref: Process.monitor(pid),
      creador: Map.fetch!(datos, :creador),
      pid_cliente: Map.fetch!(datos, :pid_cliente),
      tema: Map.fetch!(datos, :tema)
    }

    %{
      estado
      | partidas: Map.put(estado.partidas, id, partida),
        jugadores: Map.put(estado.jugadores, partida.creador, id)
    }
  end

  defp registrar_reinicio(estado, id, partida, pid_nuevo) do
    Process.demonitor(partida.ref, [:flush])
    Logger.info("La partida #{id} se reinició con el PID #{inspect(pid_nuevo)}")

    send(partida.pid_cliente, {:trivia, {:partida_reiniciada, %{id: id, tema: partida.tema}}})
    actualizada = %{partida | pid: pid_nuevo, ref: Process.monitor(pid_nuevo)}
    %{estado | partidas: Map.put(estado.partidas, id, actualizada)}
  end

  defp eliminar_si_coincide(estado, id, pid) do
    case Map.fetch(estado.partidas, id) do
      {:ok, %{pid: ^pid}} -> eliminar(estado, id)
      _ -> estado
    end
  end

  defp eliminar(estado, id) do
    {partida, partidas} = Map.pop(estado.partidas, id)
    Process.demonitor(partida.ref, [:flush])
    %{estado | partidas: partidas, jugadores: Map.delete(estado.jugadores, partida.creador)}
  end

  defp buscar_por_ref(estado, ref) do
    Enum.find_value(estado.partidas, fn {id, partida} -> if partida.ref == ref, do: id end)
  end

  defp partidas_vivas(supervisor) when is_pid(supervisor),
    do: SupervisorPartidas.partidas(supervisor)

  defp partidas_vivas(supervisor) when is_atom(supervisor) do
    if Process.whereis(supervisor), do: SupervisorPartidas.partidas(supervisor), else: []
  end

  defp generar_id(estado) do
    id = "P-" <> (3 |> :crypto.strong_rand_bytes() |> Base.encode16())
    if Map.has_key?(estado.partidas, id), do: generar_id(estado), else: id
  end
end
