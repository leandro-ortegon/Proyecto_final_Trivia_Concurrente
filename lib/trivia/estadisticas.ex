defmodule Trivia.Estadisticas do
  @moduledoc """
  Cálculo de estadísticas y rankings históricos a partir del historial de
  partidas (`data/results.log`).

  El historial es la **fuente de verdad**: no se guardan puntajes
  acumulados en ningún otro lugar. Las funciones reciben cualquier
  `Enumerable` de resultados (normalmente un `Stream` que recorre el
  archivo línea a línea) y nunca cargan el historial completo en memoria.

  Los bots se ignoran: solamente cuentan los jugadores de tipo `"humano"`.
  """

  alias Trivia.Nivel

  @type estadistica_jugador :: %{
          total: integer(),
          partidas: non_neg_integer(),
          por_tema: %{String.t() => integer()}
        }
  @type t :: %{String.t() => estadistica_jugador()}

  @doc """
  Acumula las estadísticas de todos los jugadores humanos.

  Cada elemento del enumerable es un resultado de partida con las claves
  `"tema"` y `"jugadores"` (lista de mapas con `"nombre"`, `"tipo"` y
  `"puntos"`). Los elementos mal formados se ignoran.
  """
  @spec acumular(Enumerable.t()) :: t()
  def acumular(resultados) do
    Enum.reduce(resultados, %{}, &acumular_resultado/2)
  end

  defp acumular_resultado(%{"tema" => tema, "jugadores" => jugadores}, acc)
       when is_binary(tema) and is_list(jugadores) do
    jugadores
    |> Stream.filter(&humano_valido?/1)
    |> Enum.reduce(acc, fn %{"nombre" => nombre, "puntos" => puntos}, acc_interno ->
      Map.update(acc_interno, nombre, nueva_estadistica(tema, puntos), fn estadistica ->
        sumar(estadistica, tema, puntos)
      end)
    end)
  end

  defp acumular_resultado(_mal_formado, acc), do: acc

  defp humano_valido?(%{"tipo" => "humano", "nombre" => nombre, "puntos" => puntos}),
    do: is_binary(nombre) and is_integer(puntos)

  defp humano_valido?(_), do: false

  defp nueva_estadistica(tema, puntos),
    do: %{total: puntos, partidas: 1, por_tema: %{tema => puntos}}

  defp sumar(estadistica, tema, puntos) do
    %{
      total: estadistica.total + puntos,
      partidas: estadistica.partidas + 1,
      por_tema: Map.update(estadistica.por_tema, tema, puntos, &(&1 + puntos))
    }
  end

  @doc "Estadística vacía para un jugador que todavía no tiene partidas."
  @spec vacia() :: estadistica_jugador()
  def vacia, do: %{total: 0, partidas: 0, por_tema: %{}}

  @doc "Puntaje histórico de un jugador en un tema (0 si nunca lo jugó)."
  @spec puntaje_en_tema(t(), String.t(), String.t()) :: integer()
  def puntaje_en_tema(estadisticas, usuario, tema) do
    estadisticas
    |> Map.get(usuario, vacia())
    |> Map.fetch!(:por_tema)
    |> Map.get(tema, 0)
  end

  @doc "Nivel de un jugador en un tema, calculado desde su puntaje histórico."
  @spec nivel_en_tema(t(), String.t(), String.t()) :: Nivel.t()
  def nivel_en_tema(estadisticas, usuario, tema) do
    estadisticas |> puntaje_en_tema(usuario, tema) |> Nivel.por_puntaje()
  end

  @doc """
  Resumen de un jugador para el comando `score`: total, partidas jugadas y,
  por cada tema indicado, el puntaje y el nivel.
  """
  @spec resumen_jugador(t(), String.t(), [String.t()]) :: map()
  def resumen_jugador(estadisticas, usuario, temas) do
    estadistica = Map.get(estadisticas, usuario, vacia())

    temas_resumen =
      (temas ++ Map.keys(estadistica.por_tema))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn tema ->
        puntos = Map.get(estadistica.por_tema, tema, 0)
        %{tema: tema, puntos: puntos, nivel: Nivel.por_puntaje(puntos)}
      end)

    %{
      usuario: usuario,
      total: estadistica.total,
      partidas: estadistica.partidas,
      temas: temas_resumen
    }
  end

  @doc """
  Ranking histórico. Con `nil` ordena por puntaje total; con un tema,
  por el puntaje en ese tema (solo jugadores que lo han jugado). El ranking
  global incluye además el número de partidas jugadas.
  Los empates se ordenan alfabéticamente.
  """
  @spec ranking(t(), String.t() | nil) :: [map()]
  def ranking(estadisticas, tema \\ nil) do
    estadisticas
    |> Enum.flat_map(&entrada_ranking(&1, tema))
    |> Enum.sort_by(fn entrada -> {-entrada.puntos, entrada.usuario} end)
    |> Enum.with_index(1)
    |> Enum.map(fn {entrada, posicion} -> Map.put(entrada, :posicion, posicion) end)
  end

  defp entrada_ranking({usuario, estadistica}, nil),
    do: [%{usuario: usuario, puntos: estadistica.total, partidas: estadistica.partidas}]

  defp entrada_ranking({usuario, estadistica}, tema) do
    case Map.fetch(estadistica.por_tema, tema) do
      {:ok, puntos} -> [%{usuario: usuario, puntos: puntos}]
      :error -> []
    end
  end
end
