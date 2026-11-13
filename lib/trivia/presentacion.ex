defmodule Trivia.Presentacion do
  @moduledoc """
  Formato en español de las respuestas y notificaciones que se muestran en
  la consola del cliente.

  Solo transforma datos en texto: no toma decisiones de juego ni conoce
  las respuestas correctas antes de que el servidor cierre la ronda.
  """

  @linea String.duplicate("─", 52)

  @doc "Pantalla de bienvenida."
  def bienvenida(servidor) do
    """

    ╔════════════════════════════════════════════════════╗
    ║              TRIVIA CONCURRENTE                    ║
    ╚════════════════════════════════════════════════════╝
    Estado: conectado al servidor #{servidor}.
    Escribe help para ver los comandos. Escribe exit para salir.
    """
  end

  @doc "Lista de comandos disponibles."
  def ayuda do
    """

    Comandos disponibles:
      connect <usuario> <clave>          Inicia sesión (o registra si no existe)
      disconnect                         Cierra la sesión
      create_game tema=<tema> preguntas=<n> tiempo=<segundos>
      add_bot facil | add_bot dificil    Agrega un bot (2 o 3 por partida)
      start_game                         Comienza la partida
      answer <A|B|C|D>                   Responde la pregunta actual
      score                              Tu puntaje histórico y niveles
      ranking                            Ranking histórico global
      ranking <tema>                     Ranking histórico de un tema
      leave_game                         Abandona la partida actual
      help                               Muestra esta ayuda
      exit                               Cierra el cliente
    """
  end

  # ===========================================================================
  # Respuestas a comandos
  # ===========================================================================

  @doc "Texto para la respuesta de un comando."
  def respuesta({:ok, {:conectado, %{usuario: usuario, nuevo: true}}}),
    do: "✔ Usuario #{usuario} registrado. Sesión iniciada."

  def respuesta({:ok, {:conectado, %{usuario: usuario}}}),
    do: "✔ Bienvenido de nuevo, #{usuario}."

  def respuesta({:ok, :desconectado}), do: "✔ Sesión cerrada."

  def respuesta({:ok, {:score, resumen}}) do
    temas =
      Enum.map_join(resumen.temas, "\n", fn t ->
        "  #{String.pad_trailing(t.tema, 14)} #{String.pad_leading(Integer.to_string(t.puntos), 6)} pts   nivel #{nivel(t.nivel)}"
      end)

    """

    Puntaje de #{resumen.usuario}
    #{@linea}
      Puntaje histórico: #{resumen.total}
      Partidas jugadas:  #{resumen.partidas}
    #{@linea}
    #{temas}
    """
  end

  def respuesta({:ok, {:ranking, tema, []}}),
    do: "Todavía no hay partidas registradas#{sufijo_tema(tema)}."

  def respuesta({:ok, {:ranking, tema, filas}}) do
    cuerpo =
      Enum.map_join(filas, "\n", fn fila ->
        jugadas = if Map.has_key?(fila, :partidas), do: "  (#{partidas(fila.partidas)})", else: ""

        "  #{String.pad_leading(Integer.to_string(fila.posicion), 2)}. #{String.pad_trailing(fila.usuario, 20)} #{String.pad_leading(Integer.to_string(fila.puntos), 6)} pts#{jugadas}"
      end)

    "\nRanking histórico#{sufijo_tema(tema)}\n#{@linea}\n#{cuerpo}\n"
  end

  def respuesta({:ok, {:partida_creada, p}}) do
    d = p.distribucion

    """
    ✔ Partida #{p.id} creada: tema #{p.tema}, #{preguntas(p.preguntas)}, #{p.tiempo} s por pregunta.
      Tu nivel en #{p.tema}: #{nivel(p.nivel)} (básico #{d.basico}, intermedio #{d.intermedio}, avanzado #{d.avanzado}).
      Agrega 2 o 3 bots con add_bot facil|dificil y luego usa start_game.
    """
  end

  def respuesta({:ok, {:bot_agregado, bot}}),
    do: "✔ Bot #{bot.nombre} (#{bot.dificultad}) agregado. Bots en la partida: #{bot.total_bots}."

  # El inicio se anuncia con la notificación :partida_iniciada, que puede
  # llegar antes que esta respuesta; por eso no se imprime nada aquí.
  def respuesta({:ok, {:partida_iniciando, _info}}), do: nil
  def respuesta({:ok, {:respuesta_registrada, info}}), do: "✔ Respuesta #{info.letra} registrada."
  def respuesta({:ok, :partida_abandonada}), do: "✔ Abandonaste la partida."
  def respuesta({:ok, otro}), do: "✔ #{inspect(otro)}"
  def respuesta({:error, _codigo, mensaje}), do: "✖ #{mensaje}"

  # ===========================================================================
  # Notificaciones asíncronas
  # ===========================================================================

  @doc "Texto para una notificación recibida por el receptor."
  def evento({:bot_agregado, _}), do: nil

  def evento({:partida_iniciada, info}) do
    "\n#{@linea}\nPartida #{info.id} — tema #{info.tema}: #{preguntas(info.total_preguntas)}, #{info.tiempo} s cada una.\nJugadores: #{Enum.join(info.jugadores, ", ")}\n#{@linea}"
  end

  def evento({:pregunta, p}) do
    opciones = Enum.map_join(p.opciones, "\n", fn {letra, texto} -> "   #{letra}) #{texto}" end)

    """

    Pregunta #{p.numero}/#{p.total}  [#{nivel(p.nivel)}]  ⏱ #{p.tiempo} s
    #{p.enunciado}
    #{opciones}
    Responde con: answer <A|B|C|D>
    """
  end

  def evento({:jugador_respondio, %{jugador: jugador}}), do: "  · #{jugador} respondió."

  def evento({:resultado_ronda, r}) do
    detalle =
      Enum.map_join(r.detalle, "\n", fn d ->
        "   #{String.pad_trailing(d.jugador, 18)} #{String.pad_trailing(d.respuesta || "—", 2)} #{resultado(d.resultado)} #{signo(d.puntos)}"
      end)

    acumulados = Enum.map_join(r.acumulados, "   ", fn a -> "#{a.jugador}: #{a.puntos}" end)

    siguiente =
      if r.ultima, do: "", else: "\n  Siguiente pregunta en #{div(r.pausa_ms, 1000)} segundos…"

    """

    Resultado de la pregunta #{r.numero}/#{r.total}
    Respuesta correcta: #{r.correcta}) #{r.texto_correcta}
    #{detalle}
    Acumulado: #{acumulados}#{siguiente}
    """
  end

  def evento({:partida_finalizada, f}) do
    tabla =
      f.ranking
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {e, i} ->
        "  #{i}. #{String.pad_trailing(e.jugador, 18)} #{String.pad_leading(Integer.to_string(e.puntos), 5)} pts"
      end)

    cierre =
      cond do
        f.motivo == :abandono ->
          "La partida terminó por abandono. Se registró el resultado parcial."

        f.empate ->
          "¡Empate entre #{Enum.join(f.ganadores, " y ")}!"

        true ->
          "Ganador: #{hd(f.ganadores)}"
      end

    "\n#{@linea}\nFIN DE LA PARTIDA #{f.id}\n#{tabla}\n#{cierre}\nYa puedes crear otra partida.\n#{@linea}"
  end

  def evento({:partida_cancelada, %{id: id}}),
    do: "La partida #{id} se canceló antes de comenzar."

  def evento({:partida_reiniciada, %{id: id}}) do
    "\n⚠ La partida #{id} tuvo un fallo y fue reiniciada por el supervisor.\n  Volvió al estado de espera, sin bots y sin progreso. Agrega los bots de nuevo y usa start_game."
  end

  def evento({:partida_perdida, %{id: id}}),
    do: "\n⚠ La partida #{id} falló y no pudo reiniciarse. Puedes crear otra partida."

  def evento(otro), do: "Notificación: #{inspect(otro)}"

  # ===========================================================================
  # Utilidades
  # ===========================================================================

  defp nivel(:basico), do: "básico"
  defp nivel(:intermedio), do: "intermedio"
  defp nivel(:avanzado), do: "avanzado"

  defp resultado(:correcta), do: "✔ correcta  "
  defp resultado(:incorrecta), do: "✖ incorrecta"
  defp resultado(:sin_responder), do: "· sin responder"

  defp signo(puntos) when puntos > 0, do: "+#{puntos}"
  defp signo(puntos), do: Integer.to_string(puntos)

  defp preguntas(1), do: "1 pregunta"
  defp preguntas(n), do: "#{n} preguntas"

  defp partidas(1), do: "1 partida"
  defp partidas(n), do: "#{n} partidas"

  defp sufijo_tema(nil), do: ""
  defp sufijo_tema(tema), do: " — tema #{tema}"
end
