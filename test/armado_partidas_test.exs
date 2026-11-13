defmodule Trivia.ArmadoPartidasTest do
  @moduledoc "Prueba 4: reglas de armado de partidas."
  use ExUnit.Case, async: false

  alias Trivia.{Comandos, EntornoPrueba, GestorPartidas, Partida, Reglas, Servidor}

  describe "reglas puras" do
    setup do
      %{partida: %Partida{creador: "pedro", estado: :esperando, bots: []}}
    end

    test "solo el creador agrega bots e inicia", %{partida: partida} do
      assert Reglas.validar_agregar_bot(partida, "carlos") == {:error, :no_es_creador}
      assert Reglas.validar_inicio(partida, "carlos") == {:error, :no_es_creador}
    end

    test "se requieren de 2 a 3 bots", %{partida: partida} do
      bot = %{nombre: "bot_facil_1"}

      assert Reglas.validar_inicio(%{partida | bots: [bot]}, "pedro") ==
               {:error, :bots_insuficientes}

      assert Reglas.validar_inicio(%{partida | bots: [bot, bot]}, "pedro") == :ok
      assert Reglas.validar_agregar_bot(%{partida | bots: [bot, bot]}, "pedro") == :ok

      assert Reglas.validar_agregar_bot(%{partida | bots: [bot, bot, bot]}, "pedro") ==
               {:error, :maximo_bots}
    end

    test "no se modifica una partida que ya comenzó", %{partida: partida} do
      en_curso = %{partida | estado: :en_curso, bots: [%{nombre: "b1"}, %{nombre: "b2"}]}
      assert Reglas.validar_agregar_bot(en_curso, "pedro") == {:error, :partida_no_esperando}
      assert Reglas.validar_inicio(en_curso, "pedro") == {:error, :partida_no_esperando}
    end

    test "valida los parámetros de create_game" do
      assert Comandos.interpretar("create_game tiempo=20 tema=Historia preguntas=4") ==
               {:ok, {:create_game, %{tema: "historia", preguntas: 4, tiempo: 20}}}

      for invalido <- [
            "create_game tema=ciencia preguntas=0 tiempo=10",
            "create_game tema=ciencia preguntas=5 tiempo=-3",
            "create_game tema=ciencia preguntas=cinco tiempo=10",
            "create_game tema=ciencia preguntas=5",
            "create_game tema= preguntas=5 tiempo=10"
          ] do
        assert Comandos.interpretar(invalido) == {:error, :parametros_invalidos}, invalido
      end
    end

    test "add_bot solo admite facil o dificil" do
      assert Comandos.interpretar("add_bot Facil") == {:ok, {:add_bot, :facil}}
      assert Comandos.interpretar("add_bot experto") == {:error, :dificultad_invalida}
    end
  end

  describe "armado con procesos reales" do
    setup do
      EntornoPrueba.iniciar_servidor()
      receptor = EntornoPrueba.receptor_falso()

      {:ok, {:conectado, %{token: token}}} =
        Servidor.procesar(nil, "connect pedro clave1", receptor)

      %{token: token, receptor: receptor}
    end

    test "crea una partida con identificador único y el nivel del creador", %{
      token: token,
      receptor: receptor
    } do
      assert {:ok, {:partida_creada, info}} =
               Servidor.procesar(
                 token,
                 "create_game tema=ciencia preguntas=5 tiempo=10",
                 receptor
               )

      assert "P-" <> _ = info.id
      assert info.nivel == :basico
      assert info.distribucion == %{basico: 4, intermedio: 1, avanzado: 0}
      assert [%{id: id, creador: "pedro"}] = GestorPartidas.listar()
      assert id == info.id
    end

    test "un jugador solo puede estar en una partida a la vez", %{
      token: token,
      receptor: receptor
    } do
      {:ok, _} =
        Servidor.procesar(token, "create_game tema=ciencia preguntas=3 tiempo=10", receptor)

      assert {:error, :ya_en_partida, _} =
               Servidor.procesar(
                 token,
                 "create_game tema=historia preguntas=3 tiempo=10",
                 receptor
               )
    end

    test "valida el tema y la cantidad de preguntas", %{token: token, receptor: receptor} do
      assert {:error, :tema_inexistente, _} =
               Servidor.procesar(token, "create_game tema=arte preguntas=3 tiempo=10", receptor)

      # El banco de prueba tiene 6 preguntas por nivel: un jugador básico no
      # puede pedir 10 (necesitaría 7 básicas).
      assert {:error, :preguntas_insuficientes, _} =
               Servidor.procesar(
                 token,
                 "create_game tema=ciencia preguntas=10 tiempo=10",
                 receptor
               )

      assert GestorPartidas.listar() == []
    end

    test "agrega de 2 a 3 bots y solo entonces permite iniciar", %{
      token: token,
      receptor: receptor
    } do
      {:ok, _} =
        Servidor.procesar(token, "create_game tema=ciencia preguntas=3 tiempo=10", receptor)

      assert {:error, :bots_insuficientes, _} = Servidor.procesar(token, "start_game", receptor)

      assert {:ok, {:bot_agregado, %{nombre: "bot_facil_1"}}} =
               Servidor.procesar(token, "add_bot facil", receptor)

      assert {:error, :bots_insuficientes, _} = Servidor.procesar(token, "start_game", receptor)

      assert {:ok, {:bot_agregado, %{nombre: "bot_dificil_2"}}} =
               Servidor.procesar(token, "add_bot dificil", receptor)

      assert {:ok, {:bot_agregado, %{total_bots: 3}}} =
               Servidor.procesar(token, "add_bot dificil", receptor)

      assert {:error, :maximo_bots, _} = Servidor.procesar(token, "add_bot facil", receptor)

      # Cada bot es un proceso independiente supervisado.
      assert DynamicSupervisor.count_children(Trivia.SupervisorBots).active == 3

      assert {:ok, {:partida_iniciando, %{jugadores: jugadores}}} =
               Servidor.procesar(token, "start_game", receptor)

      assert jugadores == ["pedro", "bot_facil_1", "bot_dificil_2", "bot_dificil_3"]

      assert {:error, :partida_no_esperando, _} =
               Servidor.procesar(token, "add_bot facil", receptor)
    end

    test "sin partida no se pueden usar los comandos de juego", %{
      token: token,
      receptor: receptor
    } do
      for comando <- ["add_bot facil", "start_game", "answer A", "leave_game"] do
        assert {:error, :sin_partida, _} = Servidor.procesar(token, comando, receptor)
      end
    end

    test "dos jugadores tienen partidas independientes", %{token: token, receptor: receptor} do
      receptor2 = EntornoPrueba.receptor_falso()

      {:ok, {:conectado, %{token: token2}}} =
        Servidor.procesar(nil, "connect carlos clave2", receptor2)

      {:ok, {:partida_creada, p1}} =
        Servidor.procesar(token, "create_game tema=ciencia preguntas=3 tiempo=10", receptor)

      {:ok, {:partida_creada, p2}} =
        Servidor.procesar(token2, "create_game tema=historia preguntas=4 tiempo=20", receptor2)

      assert p1.id != p2.id
      {:ok, pid1} = GestorPartidas.partida_de("pedro")
      {:ok, pid2} = GestorPartidas.partida_de("carlos")
      assert pid1 != pid2
      assert Partida.resumen(pid1).tema == "ciencia"
      assert Partida.resumen(pid2).tema == "historia"
    end
  end
end
