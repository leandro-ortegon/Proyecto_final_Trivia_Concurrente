defmodule Trivia.GestorJugadores do
  @moduledoc """
  Registro, autenticación y sesiones de los jugadores humanos, además de
  las consultas de estadísticas y rankings históricos.

  ## Sesiones

  Cada sesión se identifica con un *token* aleatorio que el cliente envía
  en todas sus peticiones. La sesión guarda el PID del proceso receptor
  del cliente y lo monitorea: si el nodo del cliente cae, la sesión se
  libera automáticamente. No se permiten dos sesiones simultáneas del
  mismo usuario.

  ## Contraseñas

  Se guardan con una sal aleatoria y SHA-256 (`:crypto`), nunca en texto
  plano.

  ## Estadísticas

  `score/2`, `ranking/2` y `nivel_en_tema/3` no usan el estado de este
  proceso: consultan el historial a través de `Trivia.Persistencia`, que
  es la fuente de verdad.
  """

  use GenServer

  alias Trivia.{BancoPreguntas, Estadisticas, Persistencia}

  @prefijo_bot "bot_"
  @formato_usuario ~r/^[A-Za-z0-9_]{3,20}$/

  # ===========================================================================
  # API pública
  # ===========================================================================

  @doc "Inicia el gestor. Opciones: `:name` y `:persistencia`."
  def start_link(opciones \\ []) do
    nombre = Keyword.get(opciones, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opciones, name: nombre)
  end

  @doc """
  Conecta a un usuario. Si no existe lo registra; si existe valida la
  contraseña. `pid_cliente` es el proceso que recibirá las notificaciones.
  """
  @spec conectar(GenServer.server(), String.t(), String.t(), pid()) ::
          {:ok, %{usuario: String.t(), token: String.t(), nuevo: boolean()}} | {:error, atom()}
  def conectar(servidor \\ __MODULE__, usuario, clave, pid_cliente) do
    with :ok <- validar_usuario(usuario),
         :ok <- validar_clave(clave) do
      GenServer.call(servidor, {:conectar, usuario, clave, pid_cliente})
    end
  end

  @doc "Cierra la sesión asociada al token."
  @spec desconectar(GenServer.server(), String.t() | nil) :: :ok
  def desconectar(servidor \\ __MODULE__, token),
    do: GenServer.call(servidor, {:desconectar, token})

  @doc "Devuelve el usuario dueño del token."
  @spec usuario_de(GenServer.server(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :no_autenticado}
  def usuario_de(servidor \\ __MODULE__, token),
    do: GenServer.call(servidor, {:usuario_de, token})

  @doc "Lista de usuarios con sesión activa."
  @spec conectados(GenServer.server()) :: [String.t()]
  def conectados(servidor \\ __MODULE__), do: GenServer.call(servidor, :conectados)

  @doc """
  Valida el formato del nombre de usuario y el prefijo reservado `bot_`.

      iex> Trivia.GestorJugadores.validar_usuario("bot_pedro")
      {:error, :prefijo_reservado}
  """
  @spec validar_usuario(term()) :: :ok | {:error, :usuario_invalido | :prefijo_reservado}
  def validar_usuario(usuario) when is_binary(usuario) do
    cond do
      usuario |> String.downcase() |> String.starts_with?(@prefijo_bot) ->
        {:error, :prefijo_reservado}

      Regex.match?(@formato_usuario, usuario) ->
        :ok

      true ->
        {:error, :usuario_invalido}
    end
  end

  def validar_usuario(_), do: {:error, :usuario_invalido}

  @doc "Prefijo reservado para los bots."
  @spec prefijo_bot() :: String.t()
  def prefijo_bot, do: @prefijo_bot

  defp validar_clave(clave) when is_binary(clave) and clave != "", do: :ok
  defp validar_clave(_), do: {:error, :clave_invalida}

  # --- Consultas sobre el historial ------------------------------------------

  @doc "Resumen histórico de un jugador (comando `score`)."
  @spec score(String.t(), keyword()) :: map()
  def score(usuario, opciones \\ []) do
    temas = BancoPreguntas.temas(Keyword.get(opciones, :banco, BancoPreguntas))

    opciones
    |> Keyword.get(:persistencia, Persistencia)
    |> Persistencia.estadisticas()
    |> Estadisticas.resumen_jugador(usuario, temas)
  end

  @doc "Ranking histórico global (`tema = nil`) o por tema."
  @spec ranking(String.t() | nil, keyword()) :: [map()]
  def ranking(tema, opciones \\ []) do
    opciones
    |> Keyword.get(:persistencia, Persistencia)
    |> Persistencia.estadisticas()
    |> Estadisticas.ranking(tema)
  end

  @doc "Nivel histórico del jugador en un tema."
  @spec nivel_en_tema(String.t(), String.t(), keyword()) :: Trivia.Nivel.t()
  def nivel_en_tema(usuario, tema, opciones \\ []) do
    opciones
    |> Keyword.get(:persistencia, Persistencia)
    |> Persistencia.estadisticas()
    |> Estadisticas.nivel_en_tema(usuario, tema)
  end

  # ===========================================================================
  # Callbacks
  # ===========================================================================

  @impl true
  def init(opciones) do
    persistencia = Keyword.get(opciones, :persistencia, Persistencia)

    {:ok,
     %{
       persistencia: persistencia,
       usuarios: Persistencia.leer_usuarios(persistencia),
       # token => %{usuario, pid, ref}
       sesiones: %{},
       # usuario => token
       tokens: %{}
     }}
  end

  @impl true
  def handle_call({:conectar, usuario, clave, pid}, _from, estado) do
    cond do
      Map.has_key?(estado.tokens, usuario) ->
        {:reply, {:error, :sesion_activa}, estado}

      Map.has_key?(estado.usuarios, usuario) ->
        autenticar(estado, usuario, clave, pid)

      true ->
        registrar(estado, usuario, clave, pid)
    end
  end

  def handle_call({:desconectar, token}, _from, estado),
    do: {:reply, :ok, cerrar_sesion(estado, token)}

  def handle_call({:usuario_de, token}, _from, estado) do
    case Map.fetch(estado.sesiones, token) do
      {:ok, sesion} -> {:reply, {:ok, sesion.usuario}, estado}
      :error -> {:reply, {:error, :no_autenticado}, estado}
    end
  end

  def handle_call(:conectados, _from, estado),
    do: {:reply, estado.tokens |> Map.keys() |> Enum.sort(), estado}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _motivo}, estado) do
    token =
      Enum.find_value(estado.sesiones, fn {token, sesion} -> if sesion.ref == ref, do: token end)

    {:noreply, cerrar_sesion(estado, token)}
  end

  def handle_info(_mensaje, estado), do: {:noreply, estado}

  # ===========================================================================
  # Lógica interna
  # ===========================================================================

  defp autenticar(estado, usuario, clave, pid) do
    registro = Map.fetch!(estado.usuarios, usuario)

    if hash(registro["sal"], clave) == registro["clave_hash"] do
      {estado, token} = abrir_sesion(estado, usuario, pid)
      {:reply, {:ok, %{usuario: usuario, token: token, nuevo: false}}, estado}
    else
      {:reply, {:error, :clave_incorrecta}, estado}
    end
  end

  defp registrar(estado, usuario, clave, pid) do
    sal = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    registro = %{
      "usuario" => usuario,
      "sal" => sal,
      "clave_hash" => hash(sal, clave),
      "registrado_en" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case Persistencia.guardar_usuario(estado.persistencia, registro) do
      :ok ->
        estado = %{estado | usuarios: Map.put(estado.usuarios, usuario, registro)}
        {estado, token} = abrir_sesion(estado, usuario, pid)
        {:reply, {:ok, %{usuario: usuario, token: token, nuevo: true}}, estado}

      {:error, _motivo} ->
        {:reply, {:error, :error_interno}, estado}
    end
  end

  defp abrir_sesion(estado, usuario, pid) do
    token = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    ref = Process.monitor(pid)

    estado = %{
      estado
      | sesiones: Map.put(estado.sesiones, token, %{usuario: usuario, pid: pid, ref: ref}),
        tokens: Map.put(estado.tokens, usuario, token)
    }

    {estado, token}
  end

  defp cerrar_sesion(estado, token) do
    case Map.pop(estado.sesiones, token) do
      {nil, _sesiones} ->
        estado

      {sesion, sesiones} ->
        Process.demonitor(sesion.ref, [:flush])
        %{estado | sesiones: sesiones, tokens: Map.delete(estado.tokens, sesion.usuario)}
    end
  end

  defp hash(sal, clave), do: :sha256 |> :crypto.hash(sal <> clave) |> Base.encode16(case: :lower)
end
