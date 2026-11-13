defmodule Trivia.Nivel do
  @moduledoc """
  Cálculo del nivel de un jugador en un tema y de la distribución de
  preguntas por nivel de dificultad.

  El nivel se obtiene del puntaje histórico acumulado en el tema
  (que puede ser negativo):

    * menos de 60 puntos  → `:basico`
    * de 60 a 179 puntos  → `:intermedio`
    * 180 puntos o más    → `:avanzado`

  La distribución de preguntas depende del nivel. Las cantidades de los
  niveles distintos al del jugador se calculan por truncamiento y las
  preguntas sobrantes pertenecen al nivel del jugador.
  """

  @type t :: :basico | :intermedio | :avanzado
  @type distribucion :: %{
          basico: non_neg_integer(),
          intermedio: non_neg_integer(),
          avanzado: non_neg_integer()
        }

  @niveles [:basico, :intermedio, :avanzado]

  @umbral_intermedio 60
  @umbral_avanzado 180

  # Porcentajes enteros para evitar errores de redondeo de coma flotante.
  @porcentajes %{
    basico: %{basico: 70, intermedio: 30, avanzado: 0},
    intermedio: %{basico: 20, intermedio: 60, avanzado: 20},
    avanzado: %{basico: 0, intermedio: 30, avanzado: 70}
  }

  @doc "Niveles ordenados de menor a mayor dificultad."
  @spec niveles() :: [t()]
  def niveles, do: @niveles

  @doc """
  Calcula el nivel correspondiente a un puntaje histórico.

      iex> Trivia.Nivel.por_puntaje(59)
      :basico
      iex> Trivia.Nivel.por_puntaje(60)
      :intermedio
      iex> Trivia.Nivel.por_puntaje(180)
      :avanzado
  """
  @spec por_puntaje(integer()) :: t()
  def por_puntaje(puntaje) when is_integer(puntaje) and puntaje >= @umbral_avanzado,
    do: :avanzado

  def por_puntaje(puntaje) when is_integer(puntaje) and puntaje >= @umbral_intermedio,
    do: :intermedio

  def por_puntaje(puntaje) when is_integer(puntaje), do: :basico

  @doc "Porcentajes de preguntas por nivel para un jugador del nivel dado."
  @spec porcentajes(t()) :: %{t() => non_neg_integer()}
  def porcentajes(nivel) when is_map_key(@porcentajes, nivel), do: Map.fetch!(@porcentajes, nivel)

  @doc """
  Calcula cuántas preguntas de cada nivel corresponden a un jugador.

      iex> Trivia.Nivel.distribucion(:intermedio, 5)
      %{basico: 1, intermedio: 3, avanzado: 1}
      iex> Trivia.Nivel.distribucion(:basico, 5)
      %{basico: 4, intermedio: 1, avanzado: 0}
  """
  @spec distribucion(t(), pos_integer()) :: distribucion()
  def distribucion(nivel, total) when is_integer(total) and total > 0 do
    porcentajes = porcentajes(nivel)

    otros =
      for otro <- @niveles, otro != nivel, into: %{} do
        {otro, div(total * Map.fetch!(porcentajes, otro), 100)}
      end

    sobrante = total - Enum.sum(Map.values(otros))
    Map.put(otros, nivel, sobrante)
  end

  @doc "Convierte el texto de un nivel (como aparece en los archivos JSON) en átomo."
  @spec desde_texto(String.t()) :: {:ok, t()} | :error
  def desde_texto("basico"), do: {:ok, :basico}
  def desde_texto("intermedio"), do: {:ok, :intermedio}
  def desde_texto("avanzado"), do: {:ok, :avanzado}
  def desde_texto(_), do: :error

  @doc "Posición del nivel en el orden de dificultad (0 = básico)."
  @spec orden(t()) :: 0 | 1 | 2
  def orden(:basico), do: 0
  def orden(:intermedio), do: 1
  def orden(:avanzado), do: 2
end
