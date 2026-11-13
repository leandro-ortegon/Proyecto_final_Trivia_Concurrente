defmodule Trivia.SorteoPreguntasTest do
  @moduledoc "Prueba 2: sorteo y distribución de preguntas (y validación del banco)."
  use ExUnit.Case, async: true

  alias Trivia.{BancoPreguntas, EntornoPrueba, Nivel}

  setup do
    {banco, []} = BancoPreguntas.construir(EntornoPrueba.preguntas_de_prueba(["ciencia"], 6))
    %{banco: banco}
  end

  describe "sortear_de/4" do
    test "respeta la distribución calculada para cada nivel", %{banco: banco} do
      for nivel <- Nivel.niveles() do
        distribucion = Nivel.distribucion(nivel, 8)
        {:ok, preguntas} = BancoPreguntas.sortear_de(banco, "ciencia", distribucion)

        conteo = Enum.frequencies_by(preguntas, & &1.nivel)
        assert Map.get(conteo, :basico, 0) == distribucion.basico
        assert Map.get(conteo, :intermedio, 0) == distribucion.intermedio
        assert Map.get(conteo, :avanzado, 0) == distribucion.avanzado
      end
    end

    test "no repite preguntas dentro de una partida", %{banco: banco} do
      for _ <- 1..50 do
        {:ok, preguntas} =
          BancoPreguntas.sortear_de(banco, "ciencia", %{basico: 6, intermedio: 6, avanzado: 6})

        assert length(preguntas) == 18
        assert preguntas |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 18
      end
    end

    test "ordena las preguntas de menor a mayor dificultad", %{banco: banco} do
      {:ok, preguntas} =
        BancoPreguntas.sortear_de(banco, "ciencia", Nivel.distribucion(:intermedio, 10))

      ordenes = Enum.map(preguntas, &Nivel.orden(&1.nivel))
      assert ordenes == Enum.sort(ordenes)
    end

    test "el sorteo es aleatorio", %{banco: banco} do
      sorteos =
        for _ <- 1..30 do
          {:ok, preguntas} =
            BancoPreguntas.sortear_de(banco, "ciencia", %{basico: 3, intermedio: 0, avanzado: 0})

          Enum.map(preguntas, & &1.id)
        end

      assert sorteos |> Enum.uniq() |> length() > 1
    end

    test "con una función de barajado fija el resultado es reproducible", %{banco: banco} do
      identidad = fn lista -> lista end

      {:ok, a} =
        BancoPreguntas.sortear_de(
          banco,
          "ciencia",
          %{basico: 2, intermedio: 1, avanzado: 0},
          identidad
        )

      {:ok, b} =
        BancoPreguntas.sortear_de(
          banco,
          "ciencia",
          %{basico: 2, intermedio: 1, avanzado: 0},
          identidad
        )

      assert a == b
    end

    test "falla si no hay suficientes preguntas de algún nivel", %{banco: banco} do
      assert BancoPreguntas.sortear_de(banco, "ciencia", %{basico: 7, intermedio: 0, avanzado: 0}) ==
               {:error, :preguntas_insuficientes}
    end

    test "falla si el tema no existe", %{banco: banco} do
      assert BancoPreguntas.sortear_de(banco, "astrologia", %{
               basico: 1,
               intermedio: 0,
               avanzado: 0
             }) ==
               {:error, :tema_inexistente}
    end
  end

  describe "validación del banco" do
    test "descarta preguntas mal formadas y los identificadores repetidos" do
      buena = EntornoPrueba.pregunta("ciencia", "basico", 1)

      sin_opcion_d =
        put_in(buena, ["opciones"], Map.delete(buena["opciones"], "D")) |> Map.put("id", "x2")

      nivel_malo = buena |> Map.put("nivel", "experto") |> Map.put("id", "x3")
      respuesta_mala = buena |> Map.put("respuesta", "E") |> Map.put("id", "x4")

      {banco, errores} =
        BancoPreguntas.construir([
          buena,
          buena,
          sin_opcion_d,
          nivel_malo,
          respuesta_mala,
          "texto"
        ])

      assert BancoPreguntas.disponibles(banco, "ciencia", :basico) == 1
      motivos = Enum.map(errores, &elem(&1, 1))
      assert :id_repetido in motivos
      assert :opciones_invalidas in motivos
      assert :nivel_invalido in motivos
      assert :respuesta_invalida in motivos
      assert :no_es_objeto in motivos
    end

    test "la versión pública de una pregunta no incluye la respuesta correcta" do
      {:ok, pregunta} =
        BancoPreguntas.validar_pregunta(EntornoPrueba.pregunta("ciencia", "basico", 1, "C"))

      publica = BancoPreguntas.publica(pregunta, 1, 5, 15)

      refute Map.has_key?(publica, :respuesta)
      assert Enum.map(publica.opciones, &elem(&1, 0)) == ["A", "B", "C", "D"]
    end

    test "data/questions.json es válido y cumple los mínimos del proyecto" do
      contenido = File.read!(Path.join([File.cwd!(), "data", "questions.json"]))
      %{"preguntas" => lista} = Jason.decode!(contenido)
      {banco, errores} = BancoPreguntas.construir(lista)

      assert errores == []
      assert map_size(banco) >= 4
      assert length(lista) >= 96

      for {tema, _} <- banco, nivel <- Nivel.niveles() do
        assert BancoPreguntas.disponibles(banco, tema, nivel) >= 8,
               "el tema #{tema} tiene menos de 8 preguntas de nivel #{nivel}"
      end
    end
  end
end
