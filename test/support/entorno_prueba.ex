defmodule Trivia.EntornoPrueba do
  @moduledoc """
  Utilidades para las pruebas: crean un directorio de datos temporal y
  aislado, y levantan los procesos del servidor sin nodos distribuidos.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @doc "Crea un directorio temporal único y devuelve su ruta."
  def directorio_temporal(prefijo \\ "trivia") do
    ruta = Path.join(System.tmp_dir!(), "#{prefijo}_#{System.unique_integer([:positive])}")
    File.rm_rf!(ruta)
    File.mkdir_p!(ruta)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(ruta) end)
    ruta
  end

  @doc "Genera una pregunta cruda (formato del JSON)."
  def pregunta(tema, nivel, numero, respuesta \\ "A") do
    %{
      "id" => "#{tema}-#{nivel}-#{numero}",
      "tema" => tema,
      "nivel" => nivel,
      "enunciado" => "Pregunta #{numero} de #{tema} (#{nivel})",
      "opciones" => %{"A" => "Opción A", "B" => "Opción B", "C" => "Opción C", "D" => "Opción D"},
      "respuesta" => respuesta
    }
  end

  @doc "Banco de prueba: `cantidad` preguntas por nivel en cada tema, todas con respuesta A."
  def preguntas_de_prueba(temas \\ ["ciencia", "historia"], cantidad \\ 6) do
    for tema <- temas, nivel <- ["basico", "intermedio", "avanzado"], n <- 1..cantidad do
      pregunta(tema, nivel, n)
    end
  end

  @doc "Escribe `questions.json` en el directorio indicado."
  def escribir_preguntas(directorio, preguntas) do
    File.write!(
      Path.join(directorio, "questions.json"),
      Jason.encode!(%{"preguntas" => preguntas})
    )
  end

  @doc """
  Inicia todos los procesos del servidor (con sus nombres por defecto)
  sobre un directorio temporal. Devuelve el directorio.
  """
  def iniciar_servidor(opciones \\ []) do
    directorio = directorio_temporal()
    escribir_preguntas(directorio, Keyword.get(opciones, :preguntas, preguntas_de_prueba()))

    start_supervised!({Trivia.Persistencia, directorio: directorio})
    start_supervised!(Trivia.BancoPreguntas)
    start_supervised!(Trivia.GestorJugadores)
    start_supervised!(Trivia.SupervisorBots)
    start_supervised!(Trivia.SupervisorPartidas)
    start_supervised!(Trivia.GestorPartidas)
    directorio
  end

  @doc "Proceso que hace las veces de receptor de un cliente."
  def receptor_falso do
    padre = self()

    spawn(fn ->
      Stream.repeatedly(fn ->
        receive do
          {:trivia, evento} -> send(padre, {:receptor, self(), evento})
          :detener -> :detener
        end
      end)
      |> Enum.find(&(&1 == :detener))
    end)
  end
end
