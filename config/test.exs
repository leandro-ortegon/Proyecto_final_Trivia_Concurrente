import Config

# Las pruebas nunca tocan la carpeta data/ real: cada prueba crea su
# propio directorio temporal y lo pasa a los procesos que inicia.
config :trivia,
  directorio_datos: "tmp/test_data",
  # Pausa corta entre rondas para que las pruebas de partidas completas
  # sean rápidas; en desarrollo y producción es de 3 segundos.
  pausa_entre_rondas_ms: 100

config :logger, level: :warning
