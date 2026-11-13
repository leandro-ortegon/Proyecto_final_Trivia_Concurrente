defmodule Trivia.EstadisticasTest do
  @moduledoc "Prueba 5: estadísticas calculadas desde el historial."
  use ExUnit.Case, async: false

  alias Trivia.{EntornoPrueba, Estadisticas, Persistencia}

  defp resultado(tema, jugadores) do
    %{
      "tema" => tema,
      "jugadores" =>
        Enum.map(jugadores, fn {nombre, tipo, puntos} ->
          %{"nombre" => nombre, "tipo" => tipo, "puntos" => puntos}
        end)
    }
  end

  defp historial do
    [
      resultado("ciencia", [
        {"pedro", "humano", 45},
        {"bot_facil_1", "bot", 80},
        {"bot_dificil_2", "bot", 99}
      ]),
      resultado("ciencia", [{"pedro", "humano", 30}, {"bot_facil_1", "bot", 10}]),
      resultado("historia", [{"pedro", "humano", -12}, {"bot_facil_1", "bot", 5}]),
      resultado("historia", [{"carlos", "humano", 200}, {"bot_dificil_1", "bot", 300}])
    ]
  end

  describe "acumular/1" do
    test "suma puntaje total, partidas y puntaje por tema" do
      estadisticas = Estadisticas.acumular(historial())

      assert estadisticas["pedro"] == %{
               total: 63,
               partidas: 3,
               por_tema: %{"ciencia" => 75, "historia" => -12}
             }

      assert estadisticas["carlos"] == %{total: 200, partidas: 1, por_tema: %{"historia" => 200}}
    end

    test "los bots nunca forman parte de las estadísticas" do
      estadisticas = Estadisticas.acumular(historial())
      refute Enum.any?(Map.keys(estadisticas), &String.starts_with?(&1, "bot_"))
    end

    test "conserva los puntajes negativos y calcula el nivel desde el historial" do
      estadisticas = Estadisticas.acumular(historial())
      assert Estadisticas.puntaje_en_tema(estadisticas, "pedro", "historia") == -12
      assert Estadisticas.nivel_en_tema(estadisticas, "pedro", "historia") == :basico
      assert Estadisticas.nivel_en_tema(estadisticas, "pedro", "ciencia") == :intermedio
      assert Estadisticas.nivel_en_tema(estadisticas, "carlos", "historia") == :avanzado
      assert Estadisticas.nivel_en_tema(estadisticas, "nadie", "ciencia") == :basico
    end

    test "acepta un Stream y descarta registros mal formados" do
      stream = Stream.concat([%{"basura" => true}], historial())
      assert Estadisticas.acumular(stream) == Estadisticas.acumular(historial())
    end
  end

  describe "rankings históricos" do
    test "ranking global ordenado por puntaje" do
      ranking = historial() |> Estadisticas.acumular() |> Estadisticas.ranking()

      assert [
               %{posicion: 1, usuario: "carlos", puntos: 200},
               %{posicion: 2, usuario: "pedro", puntos: 63}
             ] =
               ranking
    end

    test "ranking por tema solo incluye a quienes jugaron ese tema" do
      ranking = historial() |> Estadisticas.acumular() |> Estadisticas.ranking("ciencia")
      assert ranking == [%{posicion: 1, usuario: "pedro", puntos: 75}]
    end
  end

  test "resumen del comando score incluye todos los temas con su nivel" do
    resumen =
      historial()
      |> Estadisticas.acumular()
      |> Estadisticas.resumen_jugador("pedro", ["ciencia", "geografia", "historia"])

    assert resumen.total == 63
    assert resumen.partidas == 3

    assert resumen.temas == [
             %{tema: "ciencia", puntos: 75, nivel: :intermedio},
             %{tema: "geografia", puntos: 0, nivel: :basico},
             %{tema: "historia", puntos: -12, nivel: :basico}
           ]
  end

  describe "persistencia del historial" do
    test "las estadísticas se recalculan desde results.log después de reiniciar el proceso" do
      directorio = EntornoPrueba.directorio_temporal()
      pid = start_supervised!({Persistencia, directorio: directorio}, id: :primera)

      Enum.each(historial(), &(:ok = Persistencia.registrar_resultado(&1)))
      File.write!(Path.join(directorio, "results.log"), "{linea rota\n\n", [:append])
      antes = Persistencia.estadisticas()

      :ok = stop_supervised(:primera)
      refute Process.alive?(pid)
      start_supervised!({Persistencia, directorio: directorio}, id: :segunda)

      assert Persistencia.estadisticas() == antes
      assert antes["pedro"].total == 63
    end

    test "los usuarios persisten en users.json" do
      directorio = EntornoPrueba.directorio_temporal()
      start_supervised!({Persistencia, directorio: directorio})

      :ok =
        Persistencia.guardar_usuario(%{"usuario" => "pedro", "sal" => "s", "clave_hash" => "h"})

      :ok = Persistencia.guardar_usuario(%{"usuario" => "ana", "sal" => "s", "clave_hash" => "h"})

      %{"usuarios" => usuarios} =
        directorio |> Path.join("users.json") |> File.read!() |> Jason.decode!()

      assert Enum.map(usuarios, & &1["usuario"]) == ["ana", "pedro"]
      assert Map.keys(Persistencia.leer_usuarios()) |> Enum.sort() == ["ana", "pedro"]
    end
  end
end
