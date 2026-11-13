defmodule Trivia.DoctestsTest do
  @moduledoc "Ejecuta los ejemplos de la documentación de los módulos auxiliares."
  use ExUnit.Case, async: true

  doctest Trivia.Comandos
  doctest Trivia.Errores
  doctest Trivia.Reglas
  doctest Trivia.GestorJugadores
end
