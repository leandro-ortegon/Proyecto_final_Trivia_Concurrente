defmodule Trivia.Bot do
  @moduledoc """
  Jugador automático. Cada bot es un proceso independiente supervisado por
  `Trivia.SupervisorBots` (`restart: :temporary`: si un bot falla no se
  reinicia y la partida sigue; si la partida termina, el bot se detiene).

  ## Funcionamiento

  1. La partida le envía la pregunta por mensaje junto con la letra
     correcta (`{:trivia_bot, {:pregunta, publica, correcta}}`).
  2. El bot decide si acertará según su dificultad y el nivel de la
     pregunta, elige la letra y calcula un retraso dentro de su rango.
  3. Programa su respuesta con `Process.send_after/3` (nunca bloquea).
  4. Al vencer el retraso responde con `Trivia.Partida.responder/3`, el
     mismo mecanismo que usa un humano, por lo que recibe la misma
     puntuación y bonificación.

  | Dificultad | Básico | Intermedio | Avanzado | Tiempo de respuesta |
  |------------|--------|------------|----------|---------------------|
  | fácil      | 40 %   | 30 %       | 20 %     | 40 % – 90 % del tiempo |
  | difícil    | 80 %   | 70 %       | 60 %     | 10 % – 40 % del tiempo |
  """

  use GenServer, restart: :temporary

  alias Trivia.{BancoPreguntas, Partida}

  @probabilidades %{
    facil: %{basico: 40, intermedio: 30, avanzado: 20},
    dificil: %{basico: 80, intermedio: 70, avanzado: 60}
  }

  @rangos_tiempo %{facil: {40, 90}, dificil: {10, 40}}

  # ===========================================================================
  # API pública
  # ===========================================================================

  @doc "Inicia un bot. `argumentos`: `:nombre`, `:dificultad` y `:partida` (PID)."
  def start_link(argumentos) when is_map(argumentos),
    do: GenServer.start_link(__MODULE__, argumentos)

  @doc """
  Nombre de un bot. Siempre comienza con el prefijo reservado `bot_`.

      iex> Trivia.Bot.nombre(:facil, 2)
      "bot_facil_2"
  """
  @spec nombre(:facil | :dificil, pos_integer()) :: String.t()
  def nombre(dificultad, numero), do: "bot_#{dificultad}_#{numero}"

  @doc "Probabilidad de acierto (en %) según dificultad y nivel de la pregunta."
  @spec probabilidad_acierto(:facil | :dificil, Trivia.Nivel.t()) :: 0..100
  def probabilidad_acierto(dificultad, nivel),
    do: @probabilidades |> Map.fetch!(dificultad) |> Map.fetch!(nivel)

  @doc """
  Rango de retraso en milisegundos para una pregunta de `tiempo` segundos.

      iex> Trivia.Bot.rango_retraso_ms(:dificil, 10)
      {1000, 4000}
  """
  @spec rango_retraso_ms(:facil | :dificil, pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def rango_retraso_ms(dificultad, tiempo) do
    {minimo, maximo} = Map.fetch!(@rangos_tiempo, dificultad)
    tiempo_ms = tiempo * 1000
    {div(tiempo_ms * minimo, 100), div(tiempo_ms * maximo, 100)}
  end

  @doc """
  Calcula el retraso de respuesta. `aleatorio` devuelve un número en
  `[0, 1)` (inyectable para pruebas reproducibles).
  """
  @spec calcular_retraso_ms(:facil | :dificil, pos_integer(), (-> float())) :: non_neg_integer()
  def calcular_retraso_ms(dificultad, tiempo, aleatorio \\ &:rand.uniform_real/0) do
    {minimo, maximo} = rango_retraso_ms(dificultad, tiempo)
    minimo + trunc(aleatorio.() * (maximo - minimo))
  end

  @doc """
  Elige la letra con la que responderá el bot. Acierta cuando el número
  aleatorio (en `[0, 1)`) cae por debajo de su probabilidad; si falla,
  elige una de las otras tres letras.
  """
  @spec elegir_respuesta(:facil | :dificil, Trivia.Nivel.t(), String.t(), (-> float())) ::
          String.t()
  def elegir_respuesta(dificultad, nivel, correcta, aleatorio \\ &:rand.uniform_real/0) do
    if aleatorio.() * 100 < probabilidad_acierto(dificultad, nivel) do
      correcta
    else
      BancoPreguntas.letras() |> List.delete(correcta) |> Enum.random()
    end
  end

  # ===========================================================================
  # Callbacks
  # ===========================================================================

  @impl true
  def init(%{nombre: nombre, dificultad: dificultad, partida: partida}) do
    Process.monitor(partida)
    {:ok, %{nombre: nombre, dificultad: dificultad, partida: partida, ronda: nil}}
  end

  @impl true
  def handle_info({:trivia_bot, {:pregunta, publica, correcta}}, estado) do
    letra = elegir_respuesta(estado.dificultad, publica.nivel, correcta)
    retraso = calcular_retraso_ms(estado.dificultad, publica.tiempo)
    Process.send_after(self(), {:responder, publica.numero, letra}, retraso)
    {:noreply, %{estado | ronda: publica.numero}}
  end

  # Solo responde si la ronda para la que se programó sigue siendo la actual.
  def handle_info({:responder, numero, letra}, %{ronda: numero} = estado) do
    Partida.responder(estado.partida, estado.nombre, letra)
    {:noreply, %{estado | ronda: nil}}
  end

  def handle_info({:trivia, {:resultado_ronda, _}}, estado),
    do: {:noreply, %{estado | ronda: nil}}

  def handle_info({:DOWN, _ref, :process, partida, _motivo}, %{partida: partida} = estado),
    do: {:stop, :normal, estado}

  # Otros eventos de la partida (inicio, fin, respuestas de otros…).
  def handle_info(_mensaje, estado), do: {:noreply, estado}
end
