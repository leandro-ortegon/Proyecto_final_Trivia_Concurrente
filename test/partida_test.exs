defmodule Trivia.PartidaTest do
  @moduledoc """
  Pruebas de integración de una partida completa (sin nodos distribuidos):
  rondas, temporizadores, notificaciones, puntuación, historial,
  desconexión y reinicio supervisado.
  """
  use ExUnit.Case, async: false

  alias Trivia.{EntornoPrueba, GestorPartidas, Partida, Persistencia, Servidor}

  setup do
    directorio = EntornoPrueba.iniciar_servidor()
    {:ok, {:conectado, %{token: token}}} = Servidor.procesar(nil, "connect pedro clave1", self())
    %{token: token, directorio: directorio}
  end

  defp preparar(token, preguntas, tiempo, bots \\ ["facil", "dificil"]) do
    {:ok, {:partida_creada, info}} =
      Servidor.procesar(
        token,
        "create_game tema=ciencia preguntas=#{preguntas} tiempo=#{tiempo}",
        self()
      )

    Enum.each(bots, fn dificultad ->
      {:ok, _} = Servidor.procesar(token, "add_bot #{dificultad}", self())
    end)

    info
  end

  defp historial(directorio) do
    directorio |> Path.join("results.log") |> Persistencia.stream_historial() |> Enum.to_list()
  end

  test "partida completa: preguntas a todos, cierre por respuestas o por tiempo, ranking e historial",
       %{token: token, directorio: directorio} do
    info = preparar(token, 2, 1)
    assert {:ok, {:partida_iniciando, _}} = Servidor.procesar(token, "start_game", self())
    assert_receive {:trivia, {:partida_iniciada, %{id: id, jugadores: ["pedro" | _]}}}
    assert id == info.id

    # Ronda 1: el humano responde (todas las respuestas del banco de prueba son A).
    assert_receive {:trivia, {:pregunta, %{numero: 1, total: 2} = pregunta}}, 1_000
    refute Map.has_key?(pregunta, :respuesta)

    assert {:ok, {:respuesta_registrada, %{letra: "A"}}} =
             Servidor.procesar(token, "answer A", self())

    assert {:error, :ya_respondio, _} = Servidor.procesar(token, "answer B", self())

    assert_receive {:trivia, {:resultado_ronda, ronda1}}, 2_000
    assert ronda1.correcta == "A"

    assert %{resultado: :correcta, puntos: puntos_pedro} =
             Enum.find(ronda1.detalle, &(&1.jugador == "pedro"))

    # Básica correcta respondida casi al instante: 10 + bonificación (4 o 5).
    assert puntos_pedro in 14..15

    # Durante la pausa no hay ronda abierta.
    assert {:error, :ronda_cerrada, _} = Servidor.procesar(token, "answer A", self())

    # Ronda 2: el humano no responde; los bots sí, así que se cierra por tiempo.
    assert_receive {:trivia, {:pregunta, %{numero: 2}}}, 1_000
    assert_receive {:trivia, {:resultado_ronda, ronda2}}, 2_000

    assert %{resultado: :sin_responder, puntos: 0} =
             Enum.find(ronda2.detalle, &(&1.jugador == "pedro"))

    assert ronda2.ultima

    assert_receive {:trivia, {:partida_finalizada, final}}, 1_000
    assert final.motivo == :completada
    assert length(final.ranking) == 3
    assert final.ganadores != []

    # El jugador queda libre y el resultado se guardó en el historial.
    Process.sleep(50)
    assert GestorPartidas.partida_de("pedro") == {:error, :sin_partida}
    assert [registro] = historial(directorio)
    assert registro["motivo"] == "completada"
    assert registro["rondas_jugadas"] == 2
    assert Enum.find(registro["jugadores"], &(&1["nombre"] == "pedro"))["puntos"] == puntos_pedro
    assert Enum.count(registro["jugadores"], &(&1["tipo"] == "bot")) == 2

    # Puede crear otra partida y su puntaje histórico refleja la anterior.
    {:ok, {:score, score}} = Servidor.procesar(token, "score", self())
    assert score.total == puntos_pedro and score.partidas == 1

    assert {:ok, {:partida_creada, _}} =
             Servidor.procesar(token, "create_game tema=historia preguntas=1 tiempo=5", self())
  end

  test "si todos responden, la ronda se cierra antes del tiempo", %{token: token} do
    preparar(token, 1, 30, ["dificil", "dificil"])
    {:ok, _} = Servidor.procesar(token, "start_game", self())
    assert_receive {:trivia, {:pregunta, _}}, 1_000

    inicio = System.monotonic_time(:millisecond)
    {:ok, _} = Servidor.procesar(token, "answer B", self())
    # Bots difíciles con 30 s: responden entre 3 s y 12 s, nunca a los 30 s.
    assert_receive {:trivia, {:resultado_ronda, _}}, 13_000
    assert System.monotonic_time(:millisecond) - inicio < 13_000
  end

  test "si el humano abandona, la partida termina y se registra el resultado parcial",
       %{token: token, directorio: directorio} do
    preparar(token, 3, 5)
    {:ok, _} = Servidor.procesar(token, "start_game", self())
    assert_receive {:trivia, {:pregunta, %{numero: 1}}}, 1_000

    assert {:ok, :partida_abandonada} = Servidor.procesar(token, "leave_game", self())
    assert_receive {:trivia, {:partida_finalizada, %{motivo: :abandono}}}, 1_000

    assert [%{"motivo" => "abandono", "rondas_jugadas" => 0}] = historial(directorio)
    assert GestorPartidas.partida_de("pedro") == {:error, :sin_partida}
    # Los bots de la partida se detienen.
    Process.sleep(50)
    assert DynamicSupervisor.count_children(Trivia.SupervisorBots).active == 0
  end

  test "si el cliente se desconecta (su proceso muere) la partida termina y libera al jugador",
       %{directorio: directorio} do
    receptor = EntornoPrueba.receptor_falso()
    {:ok, {:conectado, %{token: token}}} = Servidor.procesar(nil, "connect ana clave", receptor)
    {:ok, _} = Servidor.procesar(token, "create_game tema=ciencia preguntas=2 tiempo=5", receptor)
    {:ok, _} = Servidor.procesar(token, "add_bot facil", receptor)
    {:ok, _} = Servidor.procesar(token, "add_bot facil", receptor)
    {:ok, partida} = GestorPartidas.partida_de("ana")
    ref = Process.monitor(partida)
    {:ok, _} = Servidor.procesar(token, "start_game", receptor)

    Process.exit(receptor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^partida, :normal}, 1_000

    Process.sleep(50)
    assert GestorPartidas.partida_de("ana") == {:error, :sin_partida}
    assert [%{"motivo" => "abandono", "creador" => "ana"}] = historial(directorio)
    # La sesión también se libera: el usuario puede volver a conectarse.
    assert {:ok, {:conectado, _}} = Servidor.procesar(nil, "connect ana clave", self())
  end

  test "abandonar mientras espera cancela la partida sin registrar historial",
       %{token: token, directorio: directorio} do
    preparar(token, 2, 5, ["facil"])
    assert {:ok, :partida_abandonada} = Servidor.procesar(token, "leave_game", self())
    assert_receive {:trivia, {:partida_cancelada, _}}
    assert historial(directorio) == []
  end

  describe "reinicio supervisado" do
    test "una partida que falla se reinicia en espera, sin bots, y avisa al creador", %{
      token: token
    } do
      info = preparar(token, 3, 5)
      {:ok, _} = Servidor.procesar(token, "start_game", self())
      assert_receive {:trivia, {:pregunta, %{numero: 1}}}, 1_000
      {:ok, pid_anterior} = GestorPartidas.partida_de("pedro")

      # Otra partida independiente que no debe verse afectada.
      receptor2 = EntornoPrueba.receptor_falso()

      {:ok, {:conectado, %{token: token2}}} =
        Servidor.procesar(nil, "connect carlos clave", receptor2)

      {:ok, _} =
        Servidor.procesar(token2, "create_game tema=historia preguntas=2 tiempo=5", receptor2)

      {:ok, otra} = GestorPartidas.partida_de("carlos")

      ExUnit.CaptureLog.capture_log(fn ->
        :ok = GestorPartidas.simular_fallo(info.id)
        assert_receive {:trivia, {:partida_reiniciada, %{id: id}}}, 2_000
        assert id == info.id
      end)

      {:ok, pid_nuevo} = GestorPartidas.partida_de("pedro")
      assert pid_nuevo != pid_anterior

      resumen = Partida.resumen(pid_nuevo)
      assert resumen.estado == :esperando
      assert resumen.bots == []
      assert resumen.id == info.id
      assert resumen.tema == "ciencia"

      # Los bots anteriores murieron con la partida y se pueden agregar de nuevo.
      Process.sleep(50)
      assert DynamicSupervisor.count_children(Trivia.SupervisorBots).active == 0
      assert {:ok, {:bot_agregado, _}} = Servidor.procesar(token, "add_bot facil", self())
      assert {:ok, {:bot_agregado, _}} = Servidor.procesar(token, "add_bot dificil", self())
      assert {:ok, {:partida_iniciando, _}} = Servidor.procesar(token, "start_game", self())
      assert_receive {:trivia, {:pregunta, %{numero: 1}}}, 1_000

      # La otra partida y los gestores siguen vivos.
      assert Process.alive?(otra)
      assert GestorPartidas.partida_de("carlos") == {:ok, otra}
      assert Process.whereis(Trivia.GestorPartidas) |> Process.alive?()
    end
  end
end
