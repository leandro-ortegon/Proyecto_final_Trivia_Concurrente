defmodule Trivia.ServidorTest do
  @moduledoc "Registro, autenticación, sesiones y enrutamiento de comandos."
  use ExUnit.Case, async: false

  alias Trivia.{EntornoPrueba, GestorJugadores, Servidor}

  setup do
    directorio = EntornoPrueba.iniciar_servidor()
    %{directorio: directorio}
  end

  test "connect registra al usuario nuevo y luego valida su contraseña", %{directorio: directorio} do
    receptor = EntornoPrueba.receptor_falso()

    assert {:ok, {:conectado, %{usuario: "pedro", nuevo: true, token: token}}} =
             Servidor.procesar(nil, "connect pedro secreta", receptor)

    contenido = File.read!(Path.join(directorio, "users.json"))
    refute contenido =~ "secreta"

    assert {:ok, :desconectado} = Servidor.procesar(token, "disconnect", receptor)
    assert {:error, :clave_incorrecta, _} = Servidor.procesar(nil, "connect pedro otra", receptor)

    assert {:ok, {:conectado, %{nuevo: false}}} =
             Servidor.procesar(nil, "connect pedro secreta", receptor)
  end

  test "no permite dos sesiones simultáneas del mismo usuario" do
    {:ok, _} = Servidor.procesar(nil, "connect pedro clave", EntornoPrueba.receptor_falso())

    assert {:error, :sesion_activa, mensaje} =
             Servidor.procesar(nil, "connect pedro clave", EntornoPrueba.receptor_falso())

    assert mensaje =~ "sesión activa"
  end

  test "reserva el prefijo bot_ y valida el nombre de usuario" do
    assert {:error, :prefijo_reservado, _} = Servidor.procesar(nil, "connect bot_pedro x", self())
    assert {:error, :prefijo_reservado, _} = Servidor.procesar(nil, "connect BOT_juan x", self())
    assert {:error, :usuario_invalido, _} = Servidor.procesar(nil, "connect ab x", self())
    assert {:error, :uso_connect, _} = Servidor.procesar(nil, "connect pedro", self())
  end

  test "los comandos requieren sesión y los desconocidos no rompen nada" do
    assert {:error, :no_autenticado, _} = Servidor.procesar(nil, "score", self())
    assert {:error, :no_autenticado, _} = Servidor.procesar("token-falso", "ranking", self())
    assert {:error, :comando_vacio, _} = Servidor.procesar(nil, "   ", self())
    assert {:error, :comando_desconocido, _} = Servidor.procesar(nil, "volar", self())
  end

  test "ranking valida el tema y nunca muestra bots" do
    {:ok, {:conectado, %{token: token}}} = Servidor.procesar(nil, "connect pedro clave", self())
    assert {:ok, {:ranking, nil, []}} = Servidor.procesar(token, "ranking", self())
    assert {:error, :tema_inexistente, _} = Servidor.procesar(token, "ranking arte", self())
    assert {:ok, {:ranking, "ciencia", []}} = Servidor.procesar(token, "ranking Ciencia", self())
  end

  test "la sesión se libera si el proceso receptor del cliente muere" do
    receptor = EntornoPrueba.receptor_falso()
    {:ok, _} = Servidor.procesar(nil, "connect pedro clave", receptor)
    assert GestorJugadores.conectados() == ["pedro"]

    Process.exit(receptor, :kill)
    Process.sleep(50)
    assert GestorJugadores.conectados() == []
  end

  describe "proceso Servidor" do
    setup do
      start_supervised!({Task.Supervisor, name: Trivia.TareasServidor})
      start_supervised!({Servidor, name: :servidor_prueba})
      :ok
    end

    test "atiende peticiones en tareas y responde al llamador" do
      respuesta = GenServer.call(:servidor_prueba, {:comando, nil, "connect lucia clave", self()})
      assert {:ok, {:conectado, %{usuario: "lucia"}}} = respuesta
    end

    test "si una petición falla, el cliente recibe un error y el servidor sigue vivo" do
      # Sin GestorJugadores la tarea que atiende la petición termina con un exit.
      :ok = stop_supervised(Trivia.GestorJugadores)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :error_interno, _} =
                 GenServer.call(:servidor_prueba, {:comando, nil, "score", self()})
      end)

      assert Process.whereis(:servidor_prueba) |> Process.alive?()

      assert {:error, :comando_desconocido, _} =
               GenServer.call(:servidor_prueba, {:comando, nil, "volar", self()})
    end
  end
end
