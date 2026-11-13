defmodule Trivia.NivelTest do
  @moduledoc "Prueba 7: cálculo de niveles y umbrales."
  use ExUnit.Case, async: true

  alias Trivia.Nivel

  doctest Trivia.Nivel

  describe "por_puntaje/1" do
    test "menos de 60 es básico, incluidos los puntajes negativos" do
      assert Nivel.por_puntaje(-40) == :basico
      assert Nivel.por_puntaje(0) == :basico
      assert Nivel.por_puntaje(59) == :basico
    end

    test "de 60 a 179 es intermedio" do
      assert Nivel.por_puntaje(60) == :intermedio
      assert Nivel.por_puntaje(120) == :intermedio
      assert Nivel.por_puntaje(179) == :intermedio
    end

    test "180 o más es avanzado" do
      assert Nivel.por_puntaje(180) == :avanzado
      assert Nivel.por_puntaje(1_000) == :avanzado
    end
  end

  describe "distribucion/2" do
    test "jugador básico: 70 % básico, 30 % intermedio, 0 % avanzado" do
      assert Nivel.distribucion(:basico, 10) == %{basico: 7, intermedio: 3, avanzado: 0}
    end

    test "jugador intermedio: 20 % / 60 % / 20 %" do
      assert Nivel.distribucion(:intermedio, 10) == %{basico: 2, intermedio: 6, avanzado: 2}
    end

    test "jugador avanzado: 0 % / 30 % / 70 %" do
      assert Nivel.distribucion(:avanzado, 10) == %{basico: 0, intermedio: 3, avanzado: 7}
    end

    test "trunca los otros niveles y asigna el sobrante al nivel del jugador" do
      # 7 preguntas, intermedio: trunc(1.4) = 1 básica, trunc(1.4) = 1 avanzada, 5 intermedias
      assert Nivel.distribucion(:intermedio, 7) == %{basico: 1, intermedio: 5, avanzado: 1}
      # 3 preguntas, básico: trunc(0.9) = 0 intermedias, 3 básicas
      assert Nivel.distribucion(:basico, 3) == %{basico: 3, intermedio: 0, avanzado: 0}
      # 1 pregunta, avanzado: todo al nivel del jugador
      assert Nivel.distribucion(:avanzado, 1) == %{basico: 0, intermedio: 0, avanzado: 1}
    end

    test "la suma siempre coincide con el total pedido" do
      for nivel <- Nivel.niveles(), total <- 1..40 do
        assert nivel |> Nivel.distribucion(total) |> Map.values() |> Enum.sum() == total
      end
    end
  end
end
