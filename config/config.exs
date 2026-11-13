import Config

# Configuración de Trivia Concurrente.
#
# - :directorio_datos       carpeta donde el servidor lee y escribe
#                           users.json, questions.json y results.log.
# - :pausa_entre_rondas_ms  pausa entre el cierre de una ronda y la siguiente
#                           pregunta (la especificación exige 3 segundos).
# - :nombre_servidor        nombre corto del nodo que actúa como servidor.
config :trivia,
  directorio_datos: "data",
  pausa_entre_rondas_ms: 3_000,
  nombre_servidor: "servidor"

import_config "#{config_env()}.exs"
