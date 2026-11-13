defmodule Trivia.PuntuacionTest do
  @moduledoc "Prueba 1: cálculo de puntuación y bonificación por rapidez."
  use ExUnit.Case, async: true

  alias Trivia.Puntuacion

  doctest Trivia.Puntuacion

  describe "puntos_base/2" do
    test "respeta la tabla de puntos por nivel" do
      assert Puntuacion.puntos_base(:basico, :correcta) == 10
      assert Puntuacion.puntos_base(:basico, :incorrecta) == -5
      assert Puntuacion.puntos_base(:intermedio, :correcta) == 15
      assert Puntuacion.puntos_base(:intermedio, :incorrecta) == -8
      assert Puntuacion.puntos_base(:avanzado, :correcta) == 20
      assert Puntuacion.puntos_base(:avanzado, :incorrecta) == -10
    end

    test "una pregunta sin responder vale 0 en cualquier nivel" do
      for nivel <- [:basico, :intermedio, :avanzado] do
        assert Puntuacion.puntos_base(nivel, :sin_responder) == 0
      end
    end
  end

  describe "bonificacion/2" do
    test "aplica trunc(5 * segundos_restantes / tiempo_pregunta)" do
      # Pregunta de 15 s
      assert Puntuacion.bonificacion(15_000, 15_000) == 5
      assert Puntuacion.bonificacion(12_000, 15_000) == 4
      assert Puntuacion.bonificacion(9_000, 15_000) == 3
      assert Puntuacion.bonificacion(7_000, 15_000) == 2
      assert Puntuacion.bonificacion(2_999, 15_000) == 0
      assert Puntuacion.bonificacion(0, 15_000) == 0
    end

    test "trunca los segundos fraccionarios" do
      # 5 * 5.9 / 10 = 2.95 -> 2
      assert Puntuacion.bonificacion(5_900, 10_000) == 2
    end

    test "nunca es negativa ni supera 5" do
      assert Puntuacion.bonificacion(-500, 10_000) == 0
      assert Puntuacion.bonificacion(20_000, 10_000) == 5
    end
  end

  describe "puntos_ronda/4" do
    test "suma la bonificación a las respuestas correctas" do
      # Avanzada respondida con 8 de 10 s restantes: 20 + trunc(5*8/10) = 24
      assert Puntuacion.puntos_ronda(:avanzado, :correcta, 8_000, 10_000) == 24
      # Básica respondida al instante: 10 + 5
      assert Puntuacion.puntos_ronda(:basico, :correcta, 10_000, 10_000) == 15
    end

    test "no da bonificación a las incorrectas ni a las no respondidas" do
      assert Puntuacion.puntos_ronda(:intermedio, :incorrecta, 10_000, 10_000) == -8
      assert Puntuacion.puntos_ronda(:avanzado, :sin_responder, 0, 10_000) == 0
    end
  end

  test "resultado/2 clasifica la respuesta" do
    assert Puntuacion.resultado("B", "B") == :correcta
    assert Puntuacion.resultado("A", "B") == :incorrecta
    assert Puntuacion.resultado(nil, "B") == :sin_responder
  end
end
