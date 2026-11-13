defmodule Trivia.Puntuacion do
  @moduledoc """
  Reglas de puntuación de una ronda. Son funciones puras: el GenServer de
  la partida les entrega los instantes medidos y ellas calculan los puntos.

  | Nivel       | Correcta | Incorrecta | Sin responder |
  |-------------|----------|------------|---------------|
  | básico      | +10      | -5         | 0             |
  | intermedio  | +15      | -8         | 0             |
  | avanzado    | +20      | -10        | 0             |

  Bonificación por rapidez (solo para respuestas correctas):

      bonificacion = trunc(5 * segundos_restantes / tiempo_pregunta)
      puntos_ronda = puntos_nivel + bonificacion

  Los tiempos se manejan en milisegundos, lo que equivale a usar segundos
  con fracción en la fórmula.
  """

  alias Trivia.Nivel

  @type resultado :: :correcta | :incorrecta | :sin_responder

  @tabla %{
    basico: %{correcta: 10, incorrecta: -5},
    intermedio: %{correcta: 15, incorrecta: -8},
    avanzado: %{correcta: 20, incorrecta: -10}
  }

  @bonificacion_maxima 5

  @doc """
  Puntos base según el nivel de la pregunta y el resultado de la respuesta.

      iex> Trivia.Puntuacion.puntos_base(:intermedio, :incorrecta)
      -8
  """
  @spec puntos_base(Nivel.t(), resultado()) :: integer()
  def puntos_base(_nivel, :sin_responder), do: 0
  def puntos_base(nivel, resultado), do: @tabla |> Map.fetch!(nivel) |> Map.fetch!(resultado)

  @doc """
  Bonificación por rapidez a partir del tiempo restante y el tiempo total
  de la pregunta (ambos en milisegundos).

      iex> Trivia.Puntuacion.bonificacion(15_000, 15_000)
      5
      iex> Trivia.Puntuacion.bonificacion(7_000, 15_000)
      2
  """
  @spec bonificacion(integer(), pos_integer()) :: non_neg_integer()
  def bonificacion(restante_ms, tiempo_ms) when is_integer(tiempo_ms) and tiempo_ms > 0 do
    restante = restante_ms |> max(0) |> min(tiempo_ms)
    trunc(@bonificacion_maxima * restante / tiempo_ms)
  end

  @doc "Clasifica una respuesta comparándola con la letra correcta."
  @spec resultado(String.t() | nil, String.t()) :: resultado()
  def resultado(nil, _correcta), do: :sin_responder
  def resultado(letra, letra), do: :correcta
  def resultado(_letra, _correcta), do: :incorrecta

  @doc """
  Puntos totales de una ronda para un jugador.

  `restante_ms` es el tiempo que faltaba para el cierre cuando llegó la
  respuesta. La bonificación solamente se suma a las respuestas correctas.
  """
  @spec puntos_ronda(Nivel.t(), resultado(), integer(), pos_integer()) :: integer()
  def puntos_ronda(nivel, :correcta, restante_ms, tiempo_ms),
    do: puntos_base(nivel, :correcta) + bonificacion(restante_ms, tiempo_ms)

  def puntos_ronda(nivel, resultado, _restante_ms, _tiempo_ms), do: puntos_base(nivel, resultado)
end
