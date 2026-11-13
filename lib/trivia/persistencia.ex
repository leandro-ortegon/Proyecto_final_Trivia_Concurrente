defmodule Trivia.Persistencia do
  @moduledoc """
  Único proceso del servidor que accede a los archivos de datos.

  Archivos administrados (dentro del directorio de datos configurado):

    * `users.json`     – usuarios registrados (contraseñas con sal y SHA-256).
    * `questions.json` – banco de preguntas (solo lectura).
    * `results.log`    – historial de partidas, un objeto JSON por línea.

  Todas las lecturas y escrituras pasan por este GenServer, de modo que
  quedan serializadas y no existen conflictos de concurrencia entre
  partidas que terminan al mismo tiempo. Los clientes nunca llaman a este
  módulo: solo lo usan los procesos del servidor.

  El historial se recorre con `File.stream!/1` y `Stream`, sin cargar el
  archivo completo en memoria.
  """

  use GenServer
  require Logger

  alias Trivia.Estadisticas

  @archivo_usuarios "users.json"
  @archivo_preguntas "questions.json"
  @archivo_resultados "results.log"

  # ===========================================================================
  # API pública
  # ===========================================================================

  @doc """
  Inicia el proceso. Opciones:

    * `:directorio` – carpeta de datos (por defecto, la configuración
      `:directorio_datos` de la aplicación).
    * `:name` – nombre de registro (por defecto, `Trivia.Persistencia`).
  """
  def start_link(opciones \\ []) do
    nombre = Keyword.get(opciones, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opciones, name: nombre)
  end

  @doc "Lee el banco de preguntas crudo (lista de mapas tal como está en el JSON)."
  @spec leer_preguntas(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def leer_preguntas(servidor \\ __MODULE__), do: GenServer.call(servidor, :leer_preguntas)

  @doc "Lee los usuarios registrados como un mapa `usuario => datos`."
  @spec leer_usuarios(GenServer.server()) :: %{String.t() => map()}
  def leer_usuarios(servidor \\ __MODULE__), do: GenServer.call(servidor, :leer_usuarios)

  @doc "Guarda (crea o actualiza) un usuario en `users.json`."
  @spec guardar_usuario(GenServer.server(), map()) :: :ok | {:error, term()}
  def guardar_usuario(servidor \\ __MODULE__, %{"usuario" => _} = usuario),
    do: GenServer.call(servidor, {:guardar_usuario, usuario})

  @doc "Agrega el resultado de una partida al historial."
  @spec registrar_resultado(GenServer.server(), map()) :: :ok | {:error, term()}
  def registrar_resultado(servidor \\ __MODULE__, resultado) when is_map(resultado),
    do: GenServer.call(servidor, {:registrar_resultado, resultado})

  @doc "Calcula las estadísticas de todos los jugadores recorriendo el historial."
  @spec estadisticas(GenServer.server()) :: Estadisticas.t()
  def estadisticas(servidor \\ __MODULE__), do: GenServer.call(servidor, :estadisticas)

  @doc "Ruta absoluta del directorio de datos que usa el proceso."
  @spec directorio(GenServer.server()) :: String.t()
  def directorio(servidor \\ __MODULE__), do: GenServer.call(servidor, :directorio)

  # ===========================================================================
  # Funciones de lectura del historial (puras respecto al proceso)
  # ===========================================================================

  @doc """
  Devuelve un `Stream` con los resultados válidos del archivo de historial.
  Las líneas vacías o con JSON inválido se descartan.
  """
  @spec stream_historial(Path.t()) :: Enumerable.t()
  def stream_historial(ruta) do
    if File.exists?(ruta) do
      ruta
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode/1)
      |> Stream.flat_map(&solo_mapas/1)
    else
      []
    end
  end

  defp solo_mapas({:ok, mapa}) when is_map(mapa), do: [mapa]
  defp solo_mapas(_linea_invalida), do: []

  # ===========================================================================
  # Callbacks
  # ===========================================================================

  @impl true
  def init(opciones) do
    directorio =
      opciones
      |> Keyword.get(:directorio, Application.get_env(:trivia, :directorio_datos, "data"))
      |> Path.expand()

    File.mkdir_p!(directorio)
    {:ok, %{directorio: directorio}}
  end

  @impl true
  def handle_call(:leer_preguntas, _from, estado) do
    {:reply, leer_lista(ruta(estado, @archivo_preguntas), "preguntas"), estado}
  end

  def handle_call(:leer_usuarios, _from, estado) do
    {:reply, usuarios_en_disco(estado), estado}
  end

  def handle_call({:guardar_usuario, usuario}, _from, estado) do
    usuarios = estado |> usuarios_en_disco() |> Map.put(usuario["usuario"], usuario)
    {:reply, escribir_usuarios(estado, usuarios), estado}
  end

  def handle_call({:registrar_resultado, resultado}, _from, estado) do
    {:reply, agregar_linea(ruta(estado, @archivo_resultados), resultado), estado}
  end

  def handle_call(:estadisticas, _from, estado) do
    estadisticas =
      estado
      |> ruta(@archivo_resultados)
      |> stream_historial()
      |> Estadisticas.acumular()

    {:reply, estadisticas, estado}
  end

  def handle_call(:directorio, _from, estado), do: {:reply, estado.directorio, estado}

  # ===========================================================================
  # Utilidades de archivos
  # ===========================================================================

  defp ruta(estado, archivo), do: Path.join(estado.directorio, archivo)

  defp usuarios_en_disco(estado) do
    case leer_lista(ruta(estado, @archivo_usuarios), "usuarios") do
      {:ok, lista} ->
        for %{"usuario" => nombre} = usuario <- lista, into: %{}, do: {nombre, usuario}

      {:error, :no_existe} ->
        %{}

      {:error, motivo} ->
        Logger.error("No se pudo leer users.json: #{inspect(motivo)}")
        %{}
    end
  end

  defp leer_lista(ruta, clave) do
    with {:ok, contenido} <- leer_archivo(ruta),
         {:ok, %{^clave => lista}} when is_list(lista) <- Jason.decode(contenido) do
      {:ok, lista}
    else
      {:error, :no_existe} ->
        {:error, :no_existe}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:json_invalido, Exception.message(error)}}

      _otro ->
        {:error, {:estructura_invalida, clave}}
    end
  end

  defp leer_archivo(ruta) do
    case File.read(ruta) do
      {:ok, contenido} -> {:ok, contenido}
      {:error, :enoent} -> {:error, :no_existe}
      {:error, motivo} -> {:error, motivo}
    end
  end

  # Escritura atómica: se escribe un temporal y luego se renombra, para que
  # un fallo a mitad de la escritura nunca deje un users.json corrupto.
  defp escribir_usuarios(estado, usuarios) do
    lista = usuarios |> Map.values() |> Enum.sort_by(& &1["usuario"])
    destino = ruta(estado, @archivo_usuarios)
    temporal = destino <> ".tmp"

    with {:ok, json} <- Jason.encode(%{"usuarios" => lista}, pretty: true),
         :ok <- File.write(temporal, json),
         :ok <- File.rename(temporal, destino) do
      :ok
    end
  end

  defp agregar_linea(ruta, mapa) do
    with {:ok, json} <- Jason.encode(mapa) do
      File.write(ruta, json <> "\n", [:append])
    end
  end
end
