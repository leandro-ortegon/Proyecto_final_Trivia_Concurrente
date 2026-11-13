defmodule Trivia.BotsTest do
  @moduledoc "Prueba 6: comportamiento y tiempos de los bots."
  use ExUnit.Case, async: true

  alias Trivia.Bot

  doctest Trivia.Bot

  describe "probabilidades de acierto" do
    test "coinciden con la especificación" do
      assert Bot.probabilidad_acierto(:facil, :basico) == 40
      assert Bot.probabilidad_acierto(:facil, :intermedio) == 30
      assert Bot.probabilidad_acierto(:facil, :avanzado) == 20
      assert Bot.probabilidad_acierto(:dificil, :basico) == 80
      assert Bot.probabilidad_acierto(:dificil, :intermedio) == 70
      assert Bot.probabilidad_acierto(:dificil, :avanzado) == 60
    end

    test "acierta justo por debajo del umbral y falla en el umbral" do
      assert Bot.elegir_respuesta(:facil, :basico, "C", fn -> 0.399 end) == "C"
      assert Bot.elegir_respuesta(:facil, :basico, "C", fn -> 0.40 end) != "C"
      assert Bot.elegir_respuesta(:dificil, :avanzado, "A", fn -> 0.599 end) == "A"
      assert Bot.elegir_respuesta(:dificil, :avanzado, "A", fn -> 0.60 end) in ["B", "C", "D"]
    end

    test "la frecuencia de aciertos se aproxima a la probabilidad" do
      :rand.seed(:exsss, {1, 2, 3})

      for {dificultad, nivel, esperado} <- [
            {:facil, :basico, 0.40},
            {:dificil, :intermedio, 0.70}
          ] do
        aciertos =
          Enum.count(1..4_000, fn _ -> Bot.elegir_respuesta(dificultad, nivel, "B") == "B" end)

        assert_in_delta aciertos / 4_000, esperado, 0.04
      end
    end
  end

  describe "tiempos de respuesta" do
    test "rango fácil: 40 % a 90 % del tiempo disponible" do
      assert Bot.rango_retraso_ms(:facil, 10) == {4_000, 9_000}
    end

    test "rango difícil: 10 % a 40 % del tiempo disponible" do
      assert Bot.rango_retraso_ms(:dificil, 15) == {1_500, 6_000}
    end

    test "el retraso calculado siempre cae dentro del rango y del tiempo de la pregunta" do
      for dificultad <- [:facil, :dificil], tiempo <- [1, 5, 15, 30], _ <- 1..200 do
        {minimo, maximo} = Bot.rango_retraso_ms(dificultad, tiempo)
        retraso = Bot.calcular_retraso_ms(dificultad, tiempo)
        assert retraso >= minimo and retraso <= maximo
        assert retraso < tiempo * 1000
      end
    end
  end

  describe "proceso del bot" do
    test "recibe la pregunta por mensaje y responde con send_after usando el mismo mecanismo que un humano" do
      # Este proceso de prueba hace las veces de partida.
      {:ok, bot} =
        Bot.start_link(%{nombre: "bot_dificil_1", dificultad: :dificil, partida: self()})

      publica = %{
        numero: 1,
        total: 1,
        nivel: :basico,
        tiempo: 1,
        enunciado: "?",
        opciones: [],
        tema: "t"
      }

      enviado = System.monotonic_time(:millisecond)
      send(bot, {:trivia_bot, {:pregunta, publica, "B"}})

      # El bot llama a Trivia.Partida.responder/3, que es un GenServer.call.
      assert_receive {:"$gen_call", from, {:responder, "bot_dificil_1", letra}}, 1_000
      transcurrido = System.monotonic_time(:millisecond) - enviado
      GenServer.reply(from, {:ok, %{letra: letra, numero: 1}})

      assert letra in ["A", "B", "C", "D"]
      # Difícil con 1 s: entre 100 ms y 400 ms (más un margen de planificación).
      assert transcurrido >= 100 and transcurrido <= 450
    end

    test "no responde una ronda que ya se cerró" do
      {:ok, bot} = Bot.start_link(%{nombre: "bot_facil_1", dificultad: :facil, partida: self()})

      publica = %{
        numero: 1,
        total: 2,
        nivel: :basico,
        tiempo: 1,
        enunciado: "?",
        opciones: [],
        tema: "t"
      }

      send(bot, {:trivia_bot, {:pregunta, publica, "A"}})
      send(bot, {:trivia, {:resultado_ronda, %{numero: 1}}})

      refute_receive {:"$gen_call", _, {:responder, _, _}}, 1_000
    end

    test "termina cuando su partida termina" do
      partida = spawn(fn -> receive do: (:fin -> :ok) end)
      {:ok, bot} = Bot.start_link(%{nombre: "bot_facil_1", dificultad: :facil, partida: partida})
      Process.unlink(bot)
      ref = Process.monitor(bot)

      send(partida, :fin)
      assert_receive {:DOWN, ^ref, :process, ^bot, :normal}, 1_000
    end

    test "los nombres de los bots usan el prefijo reservado" do
      assert Bot.nombre(:dificil, 3) |> String.starts_with?("bot_")
    end
  end
end
