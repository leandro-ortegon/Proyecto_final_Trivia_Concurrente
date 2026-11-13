defmodule Trivia.ValidacionRespuestasTest do
  @moduledoc "Prueba 3: validación de respuestas."
  use ExUnit.Case, async: true

  alias Trivia.{Comandos, Partida, Reglas}

  @tiempo 10

  defp partida_en_ronda(respuestas \\ %{}) do
    %Partida{
      creador: "pedro",
      estado: :en_curso,
      tiempo: @tiempo,
      bots: [%{nombre: "bot_facil_1"}, %{nombre: "bot_dificil_2"}],
      ronda: %{numero: 1, inicio_ms: 1_000, respuestas: respuestas}
    }
  end

  test "acepta una respuesta válida dentro del tiempo" do
    assert Reglas.validar_respuesta(partida_en_ronda(), "pedro", "B", 2_000) == :ok
    assert Reglas.validar_respuesta(partida_en_ronda(), "bot_facil_1", "D", 10_999) == :ok
  end

  test "solo admite las letras A, B, C y D" do
    for letra <- ["E", "a", "", "AB"] do
      assert Reglas.validar_respuesta(partida_en_ronda(), "pedro", letra, 2_000) ==
               {:error, :respuesta_invalida}
    end
  end

  test "acepta solamente la primera respuesta de cada jugador" do
    partida = partida_en_ronda(%{"pedro" => %{letra: "A", recibida_ms: 1_500}})
    assert Reglas.validar_respuesta(partida, "pedro", "B", 2_000) == {:error, :ya_respondio}
    assert Reglas.validar_respuesta(partida, "bot_facil_1", "B", 2_000) == :ok
  end

  test "rechaza respuestas fuera del tiempo de la pregunta" do
    assert Reglas.validar_respuesta(partida_en_ronda(), "pedro", "A", 1_000 + @tiempo * 1000) ==
             {:error, :tiempo_agotado}
  end

  test "rechaza respuestas durante la pausa entre rondas" do
    partida = %{partida_en_ronda() | ronda: nil}
    assert Reglas.validar_respuesta(partida, "pedro", "A", 2_000) == {:error, :ronda_cerrada}
  end

  test "rechaza respuestas si la partida no está en curso" do
    partida = %{partida_en_ronda() | estado: :esperando, ronda: nil}

    assert Reglas.validar_respuesta(partida, "pedro", "A", 2_000) ==
             {:error, :partida_no_en_curso}
  end

  test "rechaza jugadores que no pertenecen a la partida" do
    assert Reglas.validar_respuesta(partida_en_ronda(), "carlos", "A", 2_000) ==
             {:error, :jugador_ajeno}
  end

  test "todos_respondieron?/1 detecta el cierre anticipado de la ronda" do
    refute Reglas.todos_respondieron?(partida_en_ronda(%{"pedro" => %{}}))

    assert Reglas.todos_respondieron?(
             partida_en_ronda(%{"pedro" => %{}, "bot_facil_1" => %{}, "bot_dificil_2" => %{}})
           )
  end

  describe "comando answer" do
    test "normaliza minúsculas" do
      assert Comandos.interpretar("answer c") == {:ok, {:answer, "C"}}
      assert Comandos.interpretar("ANSWER d") == {:ok, {:answer, "D"}}
    end

    test "rechaza letras inválidas y usos incorrectos" do
      assert Comandos.interpretar("answer x") == {:error, :respuesta_invalida}
      assert Comandos.interpretar("answer") == {:error, :uso_answer}
      assert Comandos.interpretar("answer a b") == {:error, :uso_answer}
    end
  end
end
