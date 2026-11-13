defmodule Trivia.Errores do
  @moduledoc """
  Catálogo centralizado de los errores de dominio de Trivia Concurrente.

  Todos los módulos del servidor devuelven errores con la forma
  `{:error, codigo}`, donde `codigo` es uno de los átomos de este catálogo.
  Solamente el `Trivia.Servidor` traduce el código a un mensaje en español
  antes de responder al cliente, de modo que la lógica de negocio no
  depende del texto que se muestra al usuario.

  No se usan excepciones para el flujo normal: un error es un valor.
  """

  @mensajes %{
    # Autenticación y sesiones
    usuario_invalido:
      "El nombre de usuario debe tener entre 3 y 20 caracteres (letras, números o guion bajo).",
    clave_invalida: "La contraseña no puede estar vacía.",
    prefijo_reservado: "El prefijo \"bot_\" está reservado para los jugadores automáticos.",
    clave_incorrecta: "La contraseña es incorrecta.",
    sesion_activa: "Ese usuario ya tiene una sesión activa en otro cliente.",
    ya_conectado: "Ya tienes una sesión iniciada. Usa disconnect para cerrarla.",
    no_autenticado: "Debes iniciar sesión primero: connect <usuario> <clave>.",

    # Comandos
    comando_vacio: "No escribiste ningún comando. Escribe help para ver la lista.",
    comando_desconocido: "Comando no reconocido. Escribe help para ver la lista.",
    parametros_invalidos:
      "Parámetros inválidos. Uso: create_game tema=<tema> preguntas=<n> tiempo=<segundos>.",
    uso_connect: "Uso: connect <usuario> <clave>.",
    uso_add_bot: "Uso: add_bot <facil|dificil>.",
    uso_answer: "Uso: answer <A|B|C|D>.",
    uso_ranking: "Uso: ranking  o  ranking <tema>.",

    # Creación de partidas
    tema_inexistente: "El tema solicitado no existe en el banco de preguntas.",
    preguntas_insuficientes:
      "No hay suficientes preguntas de ese tema para tu nivel. Pide menos preguntas.",
    ya_en_partida: "Ya participas en una partida. Termínala o usa leave_game.",
    sin_partida: "No participas en ninguna partida.",
    partida_no_disponible: "La partida no está disponible en este momento. Intenta de nuevo.",

    # Armado de partidas
    no_es_creador: "Solamente el creador de la partida puede hacer eso.",
    partida_no_esperando: "La partida ya comenzó; no se puede modificar.",
    maximo_bots: "La partida ya tiene el máximo de 3 bots.",
    bots_insuficientes: "Se necesitan al menos 2 bots para iniciar la partida.",
    dificultad_invalida: "La dificultad del bot debe ser facil o dificil.",

    # Rondas y respuestas
    partida_no_en_curso: "La partida no está en curso.",
    ronda_cerrada: "No hay una pregunta abierta en este momento.",
    tiempo_agotado: "El tiempo para responder esta pregunta ya terminó.",
    respuesta_invalida: "La respuesta debe ser A, B, C o D.",
    ya_respondio: "Ya respondiste esta pregunta; solo cuenta tu primera respuesta.",
    jugador_ajeno: "No perteneces a esta partida.",

    # Infraestructura
    error_interno: "Ocurrió un error interno al procesar tu petición. Intenta de nuevo.",
    servidor_no_disponible: "El servidor no está disponible."
  }

  @typedoc "Código de error de dominio."
  @type codigo :: atom()

  @doc "Devuelve la lista de códigos de error conocidos."
  @spec codigos() :: [codigo()]
  def codigos, do: Map.keys(@mensajes)

  @doc """
  Traduce un código de error a un mensaje en español.

      iex> Trivia.Errores.mensaje(:clave_incorrecta)
      "La contraseña es incorrecta."
  """
  @spec mensaje(codigo()) :: String.t()
  def mensaje(codigo) when is_map_key(@mensajes, codigo), do: Map.fetch!(@mensajes, codigo)
  def mensaje(codigo), do: "Error no catalogado: #{inspect(codigo)}"
end
