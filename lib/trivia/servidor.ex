defmodule Trivia.Servidor do
  @moduledoc """
  Punto de entrada de las peticiones de los clientes.

  Se registra globalmente como `{:global, :trivia_servidor}` para que los
  clientes, desde otros nodos, lo encuentren después de `Node.connect/1`.

  Cada petición tiene la forma `{:comando, token, linea, pid_receptor}`:

    * `token`        – identifica la sesión (`nil` antes de `connect`).
    * `linea`        – texto escrito por el usuario, sin interpretar.
    * `pid_receptor` – proceso del cliente que recibe las notificaciones.

  ## Concurrencia

  El servidor no procesa las peticiones dentro de su propio proceso: lanza
  una tarea supervisada (`Task.Supervisor.async_nolink/2`) por petición y
  responde cuando la tarea termina. Así, una consulta lenta o una partida
  ocupada nunca bloquea a los demás clientes, y si una tarea falla el
  cliente recibe un error en lugar de quedarse esperando.

  La función `procesar/4` contiene el enrutamiento y puede probarse sin
  nodos distribuidos.
  """

  use GenServer
  require Logger

  alias Trivia.{
    BancoPreguntas,
    Comandos,
    Errores,
    GestorJugadores,
    GestorPartidas,
    Nivel,
    Partida
  }

  @nombre_global :trivia_servidor

  # ===========================================================================
  # API pública
  # ===========================================================================

  def start_link(opciones \\ []) do
    nombre = Keyword.get(opciones, :name, {:global, @nombre_global})
    GenServer.start_link(__MODULE__, opciones, name: nombre)
  end

  @doc "Nombre global con el que los clientes localizan al servidor."
  def nombre_global, do: @nombre_global

  @doc """
  Envía una petición al servidor y espera la respuesta. Lo usa el cliente.
  """
  @spec peticion(String.t() | nil, String.t(), pid(), timeout()) :: term()
  def peticion(token, linea, pid_receptor, timeout \\ 10_000) do
    GenServer.call({:global, @nombre_global}, {:comando, token, linea, pid_receptor}, timeout)
  catch
    :exit, _motivo -> {:error, :servidor_no_disponible, Errores.mensaje(:servidor_no_disponible)}
  end

  @doc """
  Interpreta y ejecuta una petición. Devuelve `{:ok, respuesta}` o
  `{:error, codigo, mensaje}` con el mensaje ya traducido al español.
  """
  @spec procesar(String.t() | nil, String.t(), pid(), keyword()) ::
          {:ok, term()} | {:error, atom(), String.t()}
  def procesar(token, linea, pid_receptor, opciones \\ []) do
    resultado =
      with {:ok, comando} <- Comandos.interpretar(linea) do
        ejecutar(comando, token, pid_receptor, opciones)
      end

    formatear(resultado)
  end

  # ===========================================================================
  # Callbacks
  # ===========================================================================

  @impl true
  def init(opciones) do
    {:ok,
     %{
       tareas: Keyword.get(opciones, :tareas, Trivia.TareasServidor),
       opciones: Keyword.get(opciones, :dependencias, []),
       pendientes: %{}
     }}
  end

  @impl true
  def handle_call({:comando, token, linea, pid}, from, estado) do
    opciones = estado.opciones

    tarea =
      Task.Supervisor.async_nolink(estado.tareas, fn -> procesar(token, linea, pid, opciones) end)

    {:noreply, %{estado | pendientes: Map.put(estado.pendientes, tarea.ref, from)}}
  end

  @impl true
  def handle_info({ref, respuesta}, estado) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, responder(estado, ref, respuesta)}
  end

  def handle_info({:DOWN, ref, :process, _pid, motivo}, estado) do
    Logger.error("Una petición falló: #{inspect(motivo)}")
    {:noreply, responder(estado, ref, formatear({:error, :error_interno}))}
  end

  def handle_info(_mensaje, estado), do: {:noreply, estado}

  defp responder(estado, ref, respuesta) do
    case Map.pop(estado.pendientes, ref) do
      {nil, _} ->
        estado

      {from, pendientes} ->
        GenServer.reply(from, respuesta)
        %{estado | pendientes: pendientes}
    end
  end

  # ===========================================================================
  # Enrutamiento
  # ===========================================================================

  defp ejecutar({:connect, usuario, clave}, token, pid, opciones) do
    case GestorJugadores.usuario_de(dep(opciones, :jugadores), token) do
      {:ok, _ya_conectado} -> {:error, :ya_conectado}
      {:error, :no_autenticado} -> conectar(usuario, clave, pid, opciones)
    end
  end

  defp ejecutar(comando, token, pid, opciones) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(dep(opciones, :jugadores), token) do
      ejecutar_autenticado(comando, usuario, token, pid, opciones)
    end
  end

  defp conectar(usuario, clave, pid, opciones) do
    with {:ok, sesion} <- GestorJugadores.conectar(dep(opciones, :jugadores), usuario, clave, pid) do
      {:ok, {:conectado, sesion}}
    end
  end

  defp ejecutar_autenticado(:disconnect, usuario, token, _pid, opciones) do
    abandonar_si_juega(usuario, opciones)
    :ok = GestorJugadores.desconectar(dep(opciones, :jugadores), token)
    {:ok, :desconectado}
  end

  defp ejecutar_autenticado(:score, usuario, _token, _pid, opciones),
    do: {:ok, {:score, GestorJugadores.score(usuario, consultas(opciones))}}

  defp ejecutar_autenticado({:ranking, tema}, _usuario, _token, _pid, opciones) do
    if tema == nil or BancoPreguntas.tema_existe?(dep(opciones, :banco), tema) do
      {:ok, {:ranking, tema, GestorJugadores.ranking(tema, consultas(opciones))}}
    else
      {:error, :tema_inexistente}
    end
  end

  defp ejecutar_autenticado({:create_game, parametros}, usuario, _token, pid, opciones) do
    crear_partida(parametros, usuario, pid, opciones)
  end

  defp ejecutar_autenticado({:add_bot, dificultad}, usuario, _token, _pid, opciones) do
    with {:ok, partida} <- partida_de(usuario, opciones),
         {:ok, bot} <- Partida.agregar_bot(partida, usuario, dificultad) do
      {:ok, {:bot_agregado, bot}}
    end
  end

  defp ejecutar_autenticado(:start_game, usuario, _token, _pid, opciones) do
    with {:ok, partida} <- partida_de(usuario, opciones),
         {:ok, info} <- Partida.iniciar(partida, usuario) do
      {:ok, {:partida_iniciando, info}}
    end
  end

  defp ejecutar_autenticado({:answer, letra}, usuario, _token, _pid, opciones) do
    with {:ok, partida} <- partida_de(usuario, opciones),
         {:ok, info} <- Partida.responder(partida, usuario, letra) do
      {:ok, {:respuesta_registrada, info}}
    end
  end

  defp ejecutar_autenticado(:leave_game, usuario, _token, _pid, opciones) do
    with {:ok, partida} <- partida_de(usuario, opciones),
         {:ok, :abandonada} <- Partida.abandonar(partida, usuario) do
      {:ok, :partida_abandonada}
    end
  end

  defp ejecutar_autenticado({:connect, _, _}, _usuario, _token, _pid, _opciones),
    do: {:error, :ya_conectado}

  # Validaciones previas a crear la partida: tema, ocupación del jugador,
  # nivel histórico y sorteo de preguntas. El gestor vuelve a comprobar la
  # ocupación de forma atómica al registrar la partida.
  defp crear_partida(%{tema: tema, preguntas: cantidad, tiempo: tiempo}, usuario, pid, opciones) do
    banco = dep(opciones, :banco)

    with :ok <- tema_existe(banco, tema),
         :ok <- libre(usuario, opciones),
         nivel = GestorJugadores.nivel_en_tema(usuario, tema, consultas(opciones)),
         distribucion = Nivel.distribucion(nivel, cantidad),
         {:ok, preguntas} <- BancoPreguntas.sortear(banco, tema, distribucion),
         argumentos = %{
           creador: usuario,
           pid_cliente: pid,
           tema: tema,
           nivel: nivel,
           tiempo: tiempo,
           preguntas: preguntas
         },
         {:ok, %{id: id}} <- GestorPartidas.crear(dep(opciones, :partidas), argumentos) do
      {:ok,
       {:partida_creada,
        %{
          id: id,
          tema: tema,
          preguntas: cantidad,
          tiempo: tiempo,
          nivel: nivel,
          distribucion: distribucion
        }}}
    end
  end

  defp tema_existe(banco, tema) do
    if BancoPreguntas.tema_existe?(banco, tema), do: :ok, else: {:error, :tema_inexistente}
  end

  defp libre(usuario, opciones) do
    case GestorPartidas.partida_de(dep(opciones, :partidas), usuario) do
      {:ok, _pid} -> {:error, :ya_en_partida}
      {:error, :sin_partida} -> :ok
    end
  end

  defp partida_de(usuario, opciones),
    do: GestorPartidas.partida_de(dep(opciones, :partidas), usuario)

  defp abandonar_si_juega(usuario, opciones) do
    case partida_de(usuario, opciones) do
      {:ok, partida} -> Partida.abandonar(partida, usuario)
      {:error, :sin_partida} -> :ok
    end
  end

  # ===========================================================================
  # Utilidades
  # ===========================================================================

  # Permite que las pruebas inyecten procesos con otros nombres.
  defp dep(opciones, :jugadores), do: Keyword.get(opciones, :jugadores, GestorJugadores)
  defp dep(opciones, :partidas), do: Keyword.get(opciones, :partidas, GestorPartidas)
  defp dep(opciones, :banco), do: Keyword.get(opciones, :banco, BancoPreguntas)

  defp consultas(opciones) do
    [
      banco: dep(opciones, :banco),
      persistencia: Keyword.get(opciones, :persistencia, Trivia.Persistencia)
    ]
  end

  defp formatear({:ok, respuesta}), do: {:ok, respuesta}
  defp formatear(:ok), do: {:ok, :hecho}

  defp formatear({:error, codigo}) when is_atom(codigo),
    do: {:error, codigo, Errores.mensaje(codigo)}
end
