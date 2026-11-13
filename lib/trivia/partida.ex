defmodule Trivia.Partida do
  @moduledoc """
  GenServer independiente que controla **una** partida.

  Cada partida vive bajo `Trivia.SupervisorPartidas` con
  `restart: :transient`: si termina normalmente no se reinicia, pero si
  falla se reinicia con sus argumentos iniciales.

  ## Estados

      :esperando ──start_game──▶ :en_curso ──última ronda / abandono──▶ fin
                                    │
                    ronda abierta ◀─┴─▶ pausa de 3 s (ronda = nil)

  ## Rondas y temporizadores

  Al abrir una ronda se registra el instante de inicio
  (`System.monotonic_time/1`), se envía la pregunta a todos los
  participantes y se programa `{:tiempo_agotado, numero}` con
  `Process.send_after/3`. La ronda se cierra cuando todos respondieron o
  cuando llega ese mensaje. Tras el cierre se programa `:siguiente_ronda`
  después de la pausa. Nunca se usan pausas bloqueantes: el proceso sigue
  atendiendo mensajes en todo momento.

  ## Notificaciones

  Los humanos reciben `{:trivia, evento}` en el PID registrado del
  cliente. Los bots son procesos internos del servidor: reciben los mismos
  eventos y, para las preguntas, `{:trivia_bot, {:pregunta, publica, correcta}}`
  con la letra correcta, que necesitan para simular su probabilidad de
  acierto. La respuesta correcta nunca se envía a un cliente antes del
  cierre de la ronda.

  ## Reinicio

  En `init/1` la partida avisa a su gestor con un **cast**
  (`{:partida_iniciada, id, self()}`). Se usa cast, y no call, porque el
  gestor puede estar bloqueado esperando a que `DynamicSupervisor.start_child/2`
  termine este mismo `init/1`: un call produciría un interbloqueo. Si el
  gestor detecta que el PID cambió, sabe que hubo un reinicio y avisa al
  creador. La partida reiniciada empieza en `:esperando`, sin bots y sin
  progreso.
  """

  use GenServer, restart: :transient
  require Logger

  alias Trivia.{BancoPreguntas, Bot, Persistencia, Puntuacion, Reglas}

  defstruct [
    :id,
    :tema,
    :nivel,
    :tiempo,
    :preguntas,
    :creador,
    :pid_cliente,
    :ref_cliente,
    :gestor,
    :persistencia,
    :supervisor_bots,
    :pausa_ms,
    :timer,
    :ronda,
    estado: :esperando,
    bots: [],
    indice: 0,
    puntajes: %{},
    rondas_jugadas: 0
  ]

  @type t :: %__MODULE__{}

  # ===========================================================================
  # API pública
  # ===========================================================================

  @doc """
  Inicia una partida. `argumentos` debe incluir `:id`, `:tema`, `:nivel`,
  `:tiempo` (segundos), `:preguntas` (ya sorteadas), `:creador` y
  `:pid_cliente`. Opcionales: `:gestor`, `:persistencia`,
  `:supervisor_bots` y `:pausa_ms`.
  """
  def start_link(argumentos) when is_map(argumentos),
    do: GenServer.start_link(__MODULE__, argumentos)

  @doc "Agrega un bot de la dificultad indicada (solo el creador)."
  def agregar_bot(partida, solicitante, dificultad),
    do: llamar(partida, {:agregar_bot, solicitante, dificultad})

  @doc "Inicia la partida (solo el creador, con 2 o 3 bots)."
  def iniciar(partida, solicitante), do: llamar(partida, {:iniciar, solicitante})

  @doc """
  Registra la respuesta de un jugador. Es el **mismo** mecanismo para
  humanos y bots.
  """
  def responder(partida, jugador, letra), do: llamar(partida, {:responder, jugador, letra})

  @doc "El jugador abandona la partida."
  def abandonar(partida, jugador), do: llamar(partida, {:abandonar, jugador})

  @doc "Resumen público del estado de la partida."
  def resumen(partida), do: llamar(partida, :resumen)

  @doc """
  Provoca un fallo deliberado en la partida, para demostrar la supervisión
  y el reinicio automático durante la sustentación.
  """
  def simular_fallo(partida), do: GenServer.cast(partida, :simular_fallo)

  # Si la partida murió o se está reiniciando, la llamada no derriba al
  # proceso que pregunta (servidor o bot): se devuelve un error de dominio.
  defp llamar(partida, mensaje) do
    GenServer.call(partida, mensaje)
  catch
    :exit, _motivo -> {:error, :partida_no_disponible}
  end

  # ===========================================================================
  # Callbacks
  # ===========================================================================

  @impl true
  def init(argumentos) do
    estado = %__MODULE__{
      id: Map.fetch!(argumentos, :id),
      tema: Map.fetch!(argumentos, :tema),
      nivel: Map.fetch!(argumentos, :nivel),
      tiempo: Map.fetch!(argumentos, :tiempo),
      preguntas: Map.fetch!(argumentos, :preguntas),
      creador: Map.fetch!(argumentos, :creador),
      pid_cliente: Map.fetch!(argumentos, :pid_cliente),
      gestor: Map.get(argumentos, :gestor, Trivia.GestorPartidas),
      persistencia: Map.get(argumentos, :persistencia, Persistencia),
      supervisor_bots: Map.get(argumentos, :supervisor_bots, Trivia.SupervisorBots),
      pausa_ms:
        Map.get(
          argumentos,
          :pausa_ms,
          Application.get_env(:trivia, :pausa_entre_rondas_ms, 3_000)
        )
    }

    estado = %{estado | ref_cliente: Process.monitor(estado.pid_cliente)}

    # Cast (nunca call) para no bloquear al gestor que nos está iniciando.
    GenServer.cast(estado.gestor, {:partida_iniciada, estado.id, self()})
    {:ok, estado}
  end

  @impl true
  def handle_call({:agregar_bot, solicitante, dificultad}, _from, estado) do
    with :ok <- Reglas.validar_agregar_bot(estado, solicitante),
         {:ok, bot} <- iniciar_bot(estado, dificultad) do
      estado = %{estado | bots: estado.bots ++ [bot]}
      notificar_humano(estado, {:bot_agregado, %{nombre: bot.nombre, dificultad: dificultad}})

      {:reply,
       {:ok, %{nombre: bot.nombre, dificultad: dificultad, total_bots: length(estado.bots)}},
       estado}
    else
      {:error, codigo} -> {:reply, {:error, codigo}, estado}
    end
  end

  def handle_call({:iniciar, solicitante}, _from, estado) do
    case Reglas.validar_inicio(estado, solicitante) do
      :ok ->
        estado = %{
          estado
          | estado: :en_curso,
            puntajes: Map.new(Reglas.participantes(estado), &{&1, 0})
        }

        notificar_todos(estado, {:partida_iniciada, info_inicio(estado)})
        send(self(), :siguiente_ronda)
        {:reply, {:ok, info_inicio(estado)}, estado}

      {:error, codigo} ->
        {:reply, {:error, codigo}, estado}
    end
  end

  def handle_call({:responder, jugador, letra}, _from, estado) do
    ahora = System.monotonic_time(:millisecond)

    case Reglas.validar_respuesta(estado, jugador, letra, ahora) do
      :ok ->
        estado = registrar_respuesta(estado, jugador, letra, ahora)
        avisar_respuesta_ajena(estado, jugador)
        respuesta = {:ok, %{letra: letra, numero: estado.ronda.numero}}

        if Reglas.todos_respondieron?(estado) do
          estado |> cerrar_ronda() |> responder_y_continuar(respuesta)
        else
          {:reply, respuesta, estado}
        end

      {:error, codigo} ->
        {:reply, {:error, codigo}, estado}
    end
  end

  def handle_call({:abandonar, jugador}, _from, %{creador: jugador} = estado) do
    estado |> terminar_por_abandono() |> responder_y_continuar({:ok, :abandonada})
  end

  def handle_call({:abandonar, _jugador}, _from, estado),
    do: {:reply, {:error, :jugador_ajeno}, estado}

  def handle_call(:resumen, _from, estado), do: {:reply, resumen_publico(estado), estado}

  @impl true
  def handle_cast(:simular_fallo, estado) do
    Logger.warning("Fallo simulado en la partida #{estado.id}")
    raise "fallo simulado en la partida #{estado.id}"
  end

  @impl true
  def handle_info(:siguiente_ronda, %{estado: :en_curso} = estado) do
    {:noreply, abrir_ronda(estado)}
  end

  def handle_info({:tiempo_agotado, numero}, %{ronda: %{numero: numero}} = estado) do
    case cerrar_ronda(estado) do
      {:continuar, estado} -> {:noreply, estado}
      {:terminar, estado} -> {:stop, :normal, estado}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _motivo}, %{ref_cliente: ref} = estado) do
    Logger.info("El cliente de #{estado.creador} se desconectó de la partida #{estado.id}")

    {:terminar, estado} = terminar_por_abandono(estado)
    {:stop, :normal, estado}
  end

  # Mensajes obsoletos (temporizadores de rondas ya cerradas, bots caídos…).
  def handle_info(_mensaje, estado), do: {:noreply, estado}

  # ===========================================================================
  # Bots
  # ===========================================================================

  defp iniciar_bot(estado, dificultad) do
    nombre = Bot.nombre(dificultad, length(estado.bots) + 1)
    argumentos = %{nombre: nombre, dificultad: dificultad, partida: self()}

    case DynamicSupervisor.start_child(estado.supervisor_bots, {Bot, argumentos}) do
      {:ok, pid} -> {:ok, %{nombre: nombre, dificultad: dificultad, pid: pid}}
      {:error, _motivo} -> {:error, :error_interno}
    end
  end

  # ===========================================================================
  # Rondas
  # ===========================================================================

  defp abrir_ronda(estado) do
    pregunta = Enum.at(estado.preguntas, estado.indice)
    numero = estado.indice + 1
    publica = BancoPreguntas.publica(pregunta, numero, length(estado.preguntas), estado.tiempo)

    timer = Process.send_after(self(), {:tiempo_agotado, numero}, estado.tiempo * 1000)

    ronda = %{
      numero: numero,
      pregunta: pregunta,
      inicio_ms: System.monotonic_time(:millisecond),
      respuestas: %{}
    }

    notificar_humano(estado, {:pregunta, publica})
    Enum.each(estado.bots, &send(&1.pid, {:trivia_bot, {:pregunta, publica, pregunta.respuesta}}))

    %{estado | ronda: ronda, timer: timer}
  end

  defp registrar_respuesta(estado, jugador, letra, ahora) do
    respuestas = Map.put(estado.ronda.respuestas, jugador, %{letra: letra, recibida_ms: ahora})
    %{estado | ronda: %{estado.ronda | respuestas: respuestas}}
  end

  # Cierra la ronda abierta. Devuelve {:continuar, estado} o {:terminar, estado}.
  defp cerrar_ronda(estado) do
    cancelar_timer(estado.timer)
    detalle = puntuar_ronda(estado)

    puntajes =
      Enum.reduce(detalle, estado.puntajes, fn %{jugador: j, puntos: p}, acc ->
        Map.update!(acc, j, &(&1 + p))
      end)

    estado = %{estado | puntajes: puntajes, timer: nil, rondas_jugadas: estado.rondas_jugadas + 1}

    notificar_todos(estado, {:resultado_ronda, resultado_ronda(estado, detalle)})
    estado = %{estado | ronda: nil, indice: estado.indice + 1}

    if estado.indice >= length(estado.preguntas) do
      finalizar(estado, :completada)
    else
      Process.send_after(self(), :siguiente_ronda, estado.pausa_ms)
      {:continuar, estado}
    end
  end

  defp puntuar_ronda(estado) do
    %{pregunta: pregunta, inicio_ms: inicio, respuestas: respuestas} = estado.ronda
    tiempo_ms = estado.tiempo * 1000

    Enum.map(Reglas.participantes(estado), fn jugador ->
      respuesta = Map.get(respuestas, jugador)
      letra = respuesta && respuesta.letra
      resultado = Puntuacion.resultado(letra, pregunta.respuesta)
      restante = if respuesta, do: tiempo_ms - (respuesta.recibida_ms - inicio), else: 0

      %{
        jugador: jugador,
        respuesta: letra,
        resultado: resultado,
        puntos: Puntuacion.puntos_ronda(pregunta.nivel, resultado, restante, tiempo_ms)
      }
    end)
  end

  defp resultado_ronda(estado, detalle) do
    pregunta = estado.ronda.pregunta

    %{
      numero: estado.ronda.numero,
      total: length(estado.preguntas),
      correcta: pregunta.respuesta,
      texto_correcta: Map.fetch!(pregunta.opciones, pregunta.respuesta),
      detalle: detalle,
      acumulados: ranking(estado),
      ultima: estado.indice + 1 >= length(estado.preguntas),
      pausa_ms: estado.pausa_ms
    }
  end

  # ===========================================================================
  # Finalización
  # ===========================================================================

  defp terminar_por_abandono(%{estado: :esperando} = estado) do
    detener_bots(estado)
    GenServer.cast(estado.gestor, {:partida_terminada, estado.id, self()})
    notificar_humano(estado, {:partida_cancelada, %{id: estado.id}})
    {:terminar, estado}
  end

  defp terminar_por_abandono(estado) do
    cancelar_timer(estado.timer)
    finalizar(%{estado | ronda: nil}, :abandono)
  end

  defp finalizar(estado, motivo) do
    clasificacion = ranking(estado)
    ganadores = ganadores(clasificacion)
    resultado = resultado_historial(estado, motivo, clasificacion, ganadores)

    case Persistencia.registrar_resultado(estado.persistencia, resultado) do
      :ok -> :ok
      error -> Logger.error("No se pudo registrar la partida #{estado.id}: #{inspect(error)}")
    end

    # Primero se libera al jugador en el gestor y después se notifica, para
    # que pueda crear otra partida apenas vea los resultados.
    GenServer.cast(estado.gestor, {:partida_terminada, estado.id, self()})

    notificar_todos(estado, {
      :partida_finalizada,
      %{
        id: estado.id,
        motivo: motivo,
        ranking: clasificacion,
        ganadores: ganadores,
        empate: length(ganadores) > 1
      }
    })

    detener_bots(estado)
    {:terminar, %{estado | estado: :finalizada}}
  end

  defp ranking(estado) do
    tipos = Map.new(estado.bots, &{&1.nombre, :bot}) |> Map.put(estado.creador, :humano)

    estado.puntajes
    |> Enum.map(fn {jugador, puntos} ->
      %{jugador: jugador, puntos: puntos, tipo: Map.fetch!(tipos, jugador)}
    end)
    |> Enum.sort_by(&{-&1.puntos, &1.jugador})
  end

  @doc false
  def ganadores([]), do: []

  def ganadores([%{puntos: maximo} | _] = clasificacion),
    do: clasificacion |> Enum.filter(&(&1.puntos == maximo)) |> Enum.map(& &1.jugador)

  defp resultado_historial(estado, motivo, clasificacion, ganadores) do
    dificultades = Map.new(estado.bots, &{&1.nombre, Atom.to_string(&1.dificultad)})

    %{
      "id" => estado.id,
      "fecha" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tema" => estado.tema,
      "creador" => estado.creador,
      "nivel_creador" => Atom.to_string(estado.nivel),
      "motivo" => Atom.to_string(motivo),
      "total_preguntas" => length(estado.preguntas),
      "rondas_jugadas" => estado.rondas_jugadas,
      "tiempo_por_pregunta" => estado.tiempo,
      "jugadores" =>
        Enum.map(clasificacion, fn entrada ->
          %{
            "nombre" => entrada.jugador,
            "tipo" => Atom.to_string(entrada.tipo),
            "puntos" => entrada.puntos
          }
          |> agregar_dificultad(Map.get(dificultades, entrada.jugador))
        end),
      "ganadores" => ganadores,
      "empate" => length(ganadores) > 1
    }
  end

  defp agregar_dificultad(jugador, nil), do: jugador
  defp agregar_dificultad(jugador, dificultad), do: Map.put(jugador, "dificultad", dificultad)

  defp detener_bots(estado) do
    Enum.each(estado.bots, fn bot ->
      DynamicSupervisor.terminate_child(estado.supervisor_bots, bot.pid)
    end)
  end

  # ===========================================================================
  # Utilidades
  # ===========================================================================

  defp responder_y_continuar({:continuar, estado}, respuesta), do: {:reply, respuesta, estado}

  defp responder_y_continuar({:terminar, estado}, respuesta),
    do: {:stop, :normal, respuesta, estado}

  defp notificar_humano(estado, evento), do: send(estado.pid_cliente, {:trivia, evento})

  # El humano ve cuándo responde cada bot; su propia respuesta ya la
  # confirma la respuesta síncrona del comando answer.
  defp avisar_respuesta_ajena(%{creador: jugador}, jugador), do: :ok

  defp avisar_respuesta_ajena(estado, jugador),
    do: notificar_humano(estado, {:jugador_respondio, %{jugador: jugador}})

  defp notificar_todos(estado, evento) do
    notificar_humano(estado, evento)
    Enum.each(estado.bots, &send(&1.pid, {:trivia, evento}))
  end

  defp cancelar_timer(nil), do: :ok
  defp cancelar_timer(ref), do: Process.cancel_timer(ref)

  defp info_inicio(estado) do
    %{
      id: estado.id,
      tema: estado.tema,
      total_preguntas: length(estado.preguntas),
      tiempo: estado.tiempo,
      jugadores: Reglas.participantes(estado)
    }
  end

  defp resumen_publico(estado) do
    %{
      id: estado.id,
      tema: estado.tema,
      nivel: estado.nivel,
      estado: estado.estado,
      creador: estado.creador,
      pid_cliente: estado.pid_cliente,
      bots: Enum.map(estado.bots, &Map.take(&1, [:nombre, :dificultad])),
      total_preguntas: length(estado.preguntas),
      ronda_actual: estado.ronda && estado.ronda.numero,
      puntajes: estado.puntajes
    }
  end
end
