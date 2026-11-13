defmodule Trivia.Reglas do
  @moduledoc """
  Validaciones centralizadas de las reglas de una partida.

  Son funciones puras que reciben el estado de la partida (`%Trivia.Partida{}`)
  y la acción solicitada, y devuelven `:ok` o `{:error, codigo}`. El
  GenServer de la partida valida **antes** de modificar su estado, de modo
  que una petición inválida nunca deja la partida a medias.

  Reglas de armado:

    * Cada partida tiene un humano (el creador) y de 2 a 3 bots.
    * Solo el creador agrega bots e inicia la partida.
    * Los bots solo se agregan mientras la partida está esperando.

  Reglas de respuesta:

    * Solo se responde con A, B, C o D.
    * Solo hay respuestas mientras una ronda está abierta y antes de que
      venza su tiempo.
    * Se acepta únicamente la primera respuesta válida de cada jugador.
  """

  alias Trivia.BancoPreguntas

  @minimo_bots 2
  @maximo_bots 3
  @dificultades %{"facil" => :facil, "dificil" => :dificil}

  @doc "Mínimo de bots para iniciar una partida."
  def minimo_bots, do: @minimo_bots

  @doc "Máximo de bots por partida."
  def maximo_bots, do: @maximo_bots

  @doc """
  Convierte el texto de una dificultad en átomo.

      iex> Trivia.Reglas.dificultad("dificil")
      {:ok, :dificil}
      iex> Trivia.Reglas.dificultad("experto")
      {:error, :dificultad_invalida}
  """
  @spec dificultad(String.t()) :: {:ok, :facil | :dificil} | {:error, :dificultad_invalida}
  def dificultad(texto) when is_binary(texto) do
    case Map.fetch(@dificultades, String.downcase(texto)) do
      {:ok, dificultad} -> {:ok, dificultad}
      :error -> {:error, :dificultad_invalida}
    end
  end

  def dificultad(_), do: {:error, :dificultad_invalida}

  @doc "Valida que `solicitante` pueda agregar un bot a la partida."
  @spec validar_agregar_bot(map(), String.t()) :: :ok | {:error, atom()}
  def validar_agregar_bot(partida, solicitante) do
    cond do
      solicitante != partida.creador -> {:error, :no_es_creador}
      partida.estado != :esperando -> {:error, :partida_no_esperando}
      length(partida.bots) >= @maximo_bots -> {:error, :maximo_bots}
      true -> :ok
    end
  end

  @doc "Valida que `solicitante` pueda iniciar la partida."
  @spec validar_inicio(map(), String.t()) :: :ok | {:error, atom()}
  def validar_inicio(partida, solicitante) do
    cond do
      solicitante != partida.creador -> {:error, :no_es_creador}
      partida.estado != :esperando -> {:error, :partida_no_esperando}
      length(partida.bots) < @minimo_bots -> {:error, :bots_insuficientes}
      true -> :ok
    end
  end

  @doc """
  Valida una respuesta. `ahora_ms` es el instante de recepción medido con
  `System.monotonic_time(:millisecond)`.
  """
  @spec validar_respuesta(map(), String.t(), String.t(), integer()) :: :ok | {:error, atom()}
  def validar_respuesta(partida, jugador, letra, ahora_ms) do
    cond do
      letra not in BancoPreguntas.letras() -> {:error, :respuesta_invalida}
      jugador not in participantes(partida) -> {:error, :jugador_ajeno}
      partida.estado != :en_curso -> {:error, :partida_no_en_curso}
      partida.ronda == nil -> {:error, :ronda_cerrada}
      ahora_ms - partida.ronda.inicio_ms >= partida.tiempo * 1000 -> {:error, :tiempo_agotado}
      Map.has_key?(partida.ronda.respuestas, jugador) -> {:error, :ya_respondio}
      true -> :ok
    end
  end

  @doc "Nombres de todos los participantes (humano y bots)."
  @spec participantes(map()) :: [String.t()]
  def participantes(partida), do: [partida.creador | Enum.map(partida.bots, & &1.nombre)]

  @doc "Indica si todos los participantes respondieron la ronda abierta."
  @spec todos_respondieron?(map()) :: boolean()
  def todos_respondieron?(%{ronda: nil}), do: false

  def todos_respondieron?(partida),
    do: Enum.all?(participantes(partida), &Map.has_key?(partida.ronda.respuestas, &1))

  @doc """
  Valida los parámetros de `create_game` (ya convertidos a enteros).
  """
  @spec validar_parametros_partida(map()) :: :ok | {:error, :parametros_invalidos}
  def validar_parametros_partida(%{tema: tema, preguntas: preguntas, tiempo: tiempo})
      when is_binary(tema) and tema != "" and is_integer(preguntas) and preguntas > 0 and
             is_integer(tiempo) and tiempo > 0,
      do: :ok

  def validar_parametros_partida(_), do: {:error, :parametros_invalidos}
end
