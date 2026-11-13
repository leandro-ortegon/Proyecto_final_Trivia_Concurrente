defmodule Trivia.BancoPreguntas do
  @moduledoc """
  Banco de preguntas del servidor.

  Al iniciar, el proceso solicita a `Trivia.Persistencia` el contenido de
  `data/questions.json`, valida cada pregunta y la indexa por tema y nivel.
  Para agregar temas o preguntas basta con editar el archivo y reiniciar
  el servidor: el código no contiene temas fijos.

  Estructura esperada de cada pregunta:

      {
        "id": "ciencia-b-01",
        "tema": "ciencia",
        "nivel": "basico" | "intermedio" | "avanzado",
        "enunciado": "...",
        "opciones": {"A": "...", "B": "...", "C": "...", "D": "..."},
        "respuesta": "A" | "B" | "C" | "D"
      }

  Las funciones de validación y sorteo son puras y públicas para poder
  probarlas sin procesos.
  """

  use GenServer
  require Logger

  alias Trivia.{Nivel, Persistencia}

  @letras ["A", "B", "C", "D"]

  @type pregunta :: %{
          id: String.t(),
          tema: String.t(),
          nivel: Nivel.t(),
          enunciado: String.t(),
          opciones: %{String.t() => String.t()},
          respuesta: String.t()
        }

  @type banco :: %{String.t() => %{Nivel.t() => [pregunta()]}}

  # ===========================================================================
  # API pública (proceso)
  # ===========================================================================

  @doc """
  Inicia el banco. Opciones: `:name` y `:persistencia` (servidor de
  persistencia del cual leer el archivo).
  """
  def start_link(opciones \\ []) do
    nombre = Keyword.get(opciones, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opciones, name: nombre)
  end

  @doc "Lista de temas disponibles, en orden alfabético."
  @spec temas(GenServer.server()) :: [String.t()]
  def temas(servidor \\ __MODULE__), do: GenServer.call(servidor, :temas)

  @doc "Indica si el tema existe en el banco."
  @spec tema_existe?(GenServer.server(), String.t()) :: boolean()
  def tema_existe?(servidor \\ __MODULE__, tema),
    do: GenServer.call(servidor, {:tema_existe?, tema})

  @doc """
  Sortea preguntas de un tema siguiendo una distribución por nivel.
  Devuelve las preguntas ordenadas de menor a mayor dificultad.
  """
  @spec sortear(GenServer.server(), String.t(), Nivel.distribucion()) ::
          {:ok, [pregunta()]} | {:error, :tema_inexistente | :preguntas_insuficientes}
  def sortear(servidor \\ __MODULE__, tema, distribucion),
    do: GenServer.call(servidor, {:sortear, tema, distribucion})

  # ===========================================================================
  # Funciones puras
  # ===========================================================================

  @doc """
  Construye el banco a partir de la lista cruda del JSON.

  Devuelve `{banco, errores}`; las preguntas inválidas o con identificador
  repetido no se incluyen y se informan en `errores`.
  """
  @spec construir([map()]) :: {banco(), [{term(), atom()}]}
  def construir(lista) when is_list(lista) do
    {validas, errores, _ids} =
      Enum.reduce(lista, {[], [], MapSet.new()}, fn cruda, {validas, errores, ids} ->
        case validar_pregunta(cruda) do
          {:ok, pregunta} ->
            if MapSet.member?(ids, pregunta.id) do
              {validas, [{pregunta.id, :id_repetido} | errores], ids}
            else
              {[pregunta | validas], errores, MapSet.put(ids, pregunta.id)}
            end

          {:error, motivo} ->
            {validas, [{identificador(cruda), motivo} | errores], ids}
        end
      end)

    {indexar(Enum.reverse(validas)), Enum.reverse(errores)}
  end

  defp identificador(%{"id" => id}), do: id
  defp identificador(_cruda), do: :sin_id

  @doc "Valida una pregunta cruda y la convierte a la representación interna."
  @spec validar_pregunta(term()) :: {:ok, pregunta()} | {:error, atom()}
  def validar_pregunta(%{} = cruda) do
    with {:ok, id} <- texto_no_vacio(cruda, "id", :id_invalido),
         {:ok, tema} <- texto_no_vacio(cruda, "tema", :tema_invalido),
         {:ok, nivel} <- nivel(cruda),
         {:ok, enunciado} <- texto_no_vacio(cruda, "enunciado", :enunciado_invalido),
         {:ok, opciones} <- opciones(cruda),
         {:ok, respuesta} <- respuesta(cruda) do
      {:ok,
       %{
         id: id,
         tema: String.downcase(tema),
         nivel: nivel,
         enunciado: enunciado,
         opciones: opciones,
         respuesta: respuesta
       }}
    end
  end

  def validar_pregunta(_otro), do: {:error, :no_es_objeto}

  defp texto_no_vacio(cruda, clave, error) do
    case Map.get(cruda, clave) do
      texto when is_binary(texto) and texto != "" -> {:ok, String.trim(texto)}
      _ -> {:error, error}
    end
  end

  defp nivel(cruda) do
    case Nivel.desde_texto(Map.get(cruda, "nivel")) do
      {:ok, nivel} -> {:ok, nivel}
      :error -> {:error, :nivel_invalido}
    end
  end

  defp opciones(%{"opciones" => %{} = opciones}) do
    claves_correctas = opciones |> Map.keys() |> Enum.sort() == @letras

    textos_validos =
      Enum.all?(opciones, fn {_letra, texto} -> is_binary(texto) and texto != "" end)

    if claves_correctas and textos_validos,
      do: {:ok, opciones},
      else: {:error, :opciones_invalidas}
  end

  defp opciones(_cruda), do: {:error, :opciones_invalidas}

  defp respuesta(%{"respuesta" => letra}) when letra in @letras, do: {:ok, letra}
  defp respuesta(_cruda), do: {:error, :respuesta_invalida}

  defp indexar(preguntas) do
    preguntas
    |> Enum.group_by(& &1.tema)
    |> Map.new(fn {tema, del_tema} -> {tema, Enum.group_by(del_tema, & &1.nivel)} end)
  end

  @doc "Cantidad de preguntas disponibles de un tema y nivel."
  @spec disponibles(banco(), String.t(), Nivel.t()) :: non_neg_integer()
  def disponibles(banco, tema, nivel) do
    banco |> Map.get(tema, %{}) |> Map.get(nivel, []) |> length()
  end

  @doc """
  Sortea preguntas sin repetición respetando la distribución.

  `aleatorio` permite inyectar la función de barajado (por defecto
  `Enum.shuffle/1`), útil para pruebas reproducibles.
  """
  @spec sortear_de(banco(), String.t(), Nivel.distribucion(), ([pregunta()] -> [pregunta()])) ::
          {:ok, [pregunta()]} | {:error, :tema_inexistente | :preguntas_insuficientes}
  def sortear_de(banco, tema, distribucion, barajar \\ &Enum.shuffle/1) do
    cond do
      not Map.has_key?(banco, tema) ->
        {:error, :tema_inexistente}

      not suficientes?(banco, tema, distribucion) ->
        {:error, :preguntas_insuficientes}

      true ->
        preguntas =
          Enum.flat_map(Nivel.niveles(), fn nivel ->
            banco
            |> Map.fetch!(tema)
            |> Map.get(nivel, [])
            |> barajar.()
            |> Enum.take(Map.get(distribucion, nivel, 0))
          end)

        {:ok, preguntas}
    end
  end

  defp suficientes?(banco, tema, distribucion) do
    Enum.all?(distribucion, fn {nivel, cantidad} ->
      disponibles(banco, tema, nivel) >= cantidad
    end)
  end

  @doc """
  Versión pública de una pregunta para enviar a los jugadores humanos:
  no incluye la respuesta correcta.
  """
  @spec publica(pregunta(), pos_integer(), pos_integer(), pos_integer()) :: map()
  def publica(pregunta, numero, total, tiempo) do
    %{
      numero: numero,
      total: total,
      tema: pregunta.tema,
      nivel: pregunta.nivel,
      enunciado: pregunta.enunciado,
      opciones: Enum.map(@letras, fn letra -> {letra, Map.fetch!(pregunta.opciones, letra)} end),
      tiempo: tiempo
    }
  end

  @doc "Letras válidas para responder."
  @spec letras() :: [String.t()]
  def letras, do: @letras

  # ===========================================================================
  # Callbacks
  # ===========================================================================

  @impl true
  def init(opciones) do
    persistencia = Keyword.get(opciones, :persistencia, Persistencia)

    case Persistencia.leer_preguntas(persistencia) do
      {:ok, lista} ->
        {banco, errores} = construir(lista)
        informar_carga(banco, errores)
        {:ok, %{banco: banco}}

      {:error, motivo} ->
        Logger.error("No se pudo cargar questions.json: #{inspect(motivo)}")
        {:stop, {:banco_no_disponible, motivo}}
    end
  end

  @impl true
  def handle_call(:temas, _from, estado),
    do: {:reply, estado.banco |> Map.keys() |> Enum.sort(), estado}

  def handle_call({:tema_existe?, tema}, _from, estado),
    do: {:reply, Map.has_key?(estado.banco, tema), estado}

  def handle_call({:sortear, tema, distribucion}, _from, estado),
    do: {:reply, sortear_de(estado.banco, tema, distribucion), estado}

  defp informar_carga(banco, errores) do
    total =
      banco |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.map(&length/1) |> Enum.sum()

    Logger.info("Banco de preguntas cargado: #{total} preguntas en #{map_size(banco)} temas.")

    Enum.each(errores, fn {id, motivo} ->
      Logger.warning("Pregunta descartada #{inspect(id)}: #{motivo}")
    end)
  end
end
