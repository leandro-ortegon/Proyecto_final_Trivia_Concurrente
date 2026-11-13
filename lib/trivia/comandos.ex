defmodule Trivia.Comandos do
  @moduledoc """
  Interpreta el texto escrito por el usuario y lo convierte en un comando
  estructurado. Lo usa el **servidor**: el cliente envía la línea tal cual
  y no contiene lógica de negocio.

  Comandos reconocidos:

      connect <usuario> <clave>
      disconnect
      score
      ranking
      ranking <tema>
      create_game tema=<tema> preguntas=<n> tiempo=<segundos>
      add_bot <facil|dificil>
      start_game
      answer <A|B|C|D>
      leave_game
  """

  alias Trivia.Reglas

  @type comando ::
          {:connect, String.t(), String.t()}
          | :disconnect
          | :score
          | {:ranking, String.t() | nil}
          | {:create_game, %{tema: String.t(), preguntas: pos_integer(), tiempo: pos_integer()}}
          | {:add_bot, :facil | :dificil}
          | :start_game
          | {:answer, String.t()}
          | :leave_game

  @doc """
  Convierte una línea de texto en un comando.

      iex> Trivia.Comandos.interpretar("answer b")
      {:ok, {:answer, "B"}}
      iex> Trivia.Comandos.interpretar("create_game tema=Ciencia preguntas=5 tiempo=15")
      {:ok, {:create_game, %{tema: "ciencia", preguntas: 5, tiempo: 15}}}
  """
  @spec interpretar(term()) :: {:ok, comando()} | {:error, atom()}
  def interpretar(linea) when is_binary(linea) do
    linea
    |> String.split()
    |> traducir()
  end

  def interpretar(_), do: {:error, :comando_desconocido}

  defp traducir([]), do: {:error, :comando_vacio}
  defp traducir([nombre | argumentos]), do: traducir(String.downcase(nombre), argumentos)

  defp traducir("connect", [usuario, clave]), do: {:ok, {:connect, usuario, clave}}
  defp traducir("connect", _), do: {:error, :uso_connect}

  defp traducir("disconnect", []), do: {:ok, :disconnect}
  defp traducir("score", []), do: {:ok, :score}
  defp traducir("start_game", []), do: {:ok, :start_game}
  defp traducir("leave_game", []), do: {:ok, :leave_game}

  defp traducir("ranking", []), do: {:ok, {:ranking, nil}}
  defp traducir("ranking", [tema]), do: {:ok, {:ranking, String.downcase(tema)}}
  defp traducir("ranking", _), do: {:error, :uso_ranking}

  defp traducir("create_game", argumentos), do: parametros_partida(argumentos)

  defp traducir("add_bot", [dificultad]) do
    with {:ok, dificultad} <- Reglas.dificultad(dificultad), do: {:ok, {:add_bot, dificultad}}
  end

  defp traducir("add_bot", _), do: {:error, :uso_add_bot}

  defp traducir("answer", [letra]) do
    letra = String.upcase(letra)

    if letra in ["A", "B", "C", "D"],
      do: {:ok, {:answer, letra}},
      else: {:error, :respuesta_invalida}
  end

  defp traducir("answer", _), do: {:error, :uso_answer}

  defp traducir(_desconocido, _argumentos), do: {:error, :comando_desconocido}

  # create_game acepta los tres parámetros clave=valor en cualquier orden.
  defp parametros_partida(argumentos) do
    pares =
      for argumento <- argumentos, into: %{} do
        case String.split(argumento, "=", parts: 2) do
          [clave, valor] -> {String.downcase(clave), valor}
          [suelto] -> {suelto, nil}
        end
      end

    with true <- Map.keys(pares) |> Enum.sort() == ["preguntas", "tema", "tiempo"],
         {:ok, preguntas} <- entero_positivo(pares["preguntas"]),
         {:ok, tiempo} <- entero_positivo(pares["tiempo"]),
         parametros = %{
           tema: String.downcase(pares["tema"] || ""),
           preguntas: preguntas,
           tiempo: tiempo
         },
         :ok <- Reglas.validar_parametros_partida(parametros) do
      {:ok, {:create_game, parametros}}
    else
      _ -> {:error, :parametros_invalidos}
    end
  end

  defp entero_positivo(texto) when is_binary(texto) do
    case Integer.parse(texto) do
      {numero, ""} when numero > 0 -> {:ok, numero}
      _ -> :error
    end
  end

  defp entero_positivo(_), do: :error
end
