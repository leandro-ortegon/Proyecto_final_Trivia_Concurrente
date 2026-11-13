defmodule Trivia.Cliente do
  @moduledoc """
  Interfaz de consola del jugador.

  Se ejecuta en un nodo de Erlang distinto al del servidor:

      iex --sname pedro --cookie trivia -S mix
      iex> Trivia.Cliente.iniciar()                 # servidor@<este host>
      iex> Trivia.Cliente.iniciar(:"servidor@PC1")  # servidor en otro equipo

  El proceso que llama a `iniciar/1` solo **lee el teclado** y envía cada
  línea al servidor junto con el token de sesión y el PID del receptor. Las
  notificaciones asíncronas las muestra `Trivia.Receptor`, que es otro
  proceso.

  El cliente no interpreta los comandos de juego, no accede a archivos y
  no conoce las respuestas correctas: solo guarda su token de sesión.
  Los únicos comandos locales son `help` y `exit`.
  """

  alias Trivia.{Presentacion, Receptor, Servidor}

  @doc """
  Conecta con el servidor y comienza a leer comandos. Devuelve `:ok` al
  salir con `exit`.
  """
  def iniciar(nodo_servidor \\ nil) do
    nodo = nodo_servidor || nodo_por_defecto()

    with :ok <- conectar_nodo(nodo),
         {:ok, receptor} <- Receptor.iniciar(nodo) do
      IO.puts(Presentacion.bienvenida(nodo))
      ciclo(%{token: nil, receptor: receptor})
    else
      {:error, mensaje} when is_binary(mensaje) -> IO.puts("✖ " <> mensaje)
      {:error, motivo} -> IO.puts("✖ No se pudo iniciar el cliente: #{inspect(motivo)}")
    end
  end

  @doc "Nombre por defecto del nodo servidor: `servidor@<host de este nodo>`."
  def nodo_por_defecto do
    nombre = Application.get_env(:trivia, :nombre_servidor, "servidor")
    [_nombre, host] = Node.self() |> Atom.to_string() |> String.split("@")
    String.to_atom("#{nombre}@#{host}")
  end

  # ===========================================================================
  # Conexión con el nodo servidor
  # ===========================================================================

  defp conectar_nodo(nodo) do
    cond do
      not Node.alive?() ->
        {:error,
         "Este nodo no es distribuido. Inicia con: iex --sname <nombre> --cookie trivia -S mix"}

      not Node.connect(nodo) ->
        {:error,
         """
         No fue posible conectar con #{nodo}.
           1. Verifica que el servidor esté encendido.
           2. Usa la misma cookie en ambos nodos (--cookie trivia).
           3. Revisa el nombre del nodo y que los equipos estén en la misma red.
           4. Revisa que el firewall no bloquee Erlang (puerto 4369 y puertos dinámicos).
         """}

      true ->
        :global.sync()
        verificar_servidor(nodo)
    end
  end

  defp verificar_servidor(nodo) do
    case :global.whereis_name(Servidor.nombre_global()) do
      :undefined ->
        {:error, "Se conectó con #{nodo}, pero el servidor de Trivia no está en ejecución."}

      _pid ->
        :ok
    end
  end

  # ===========================================================================
  # Ciclo de lectura del teclado
  # ===========================================================================

  defp ciclo(sesion) do
    case IO.gets("trivia> ") do
      entrada when is_binary(entrada) -> entrada |> String.trim() |> manejar(sesion)
      _fin_de_entrada -> salir(sesion)
    end
  end

  defp manejar("", sesion), do: ciclo(sesion)

  defp manejar(linea, sesion) when linea in ["help", "ayuda"] do
    IO.puts(Presentacion.ayuda())
    ciclo(sesion)
  end

  defp manejar(linea, sesion) when linea in ["exit", "salir"], do: salir(sesion)

  defp manejar(linea, sesion) do
    respuesta = Servidor.peticion(sesion.token, linea, sesion.receptor)
    mostrar(Presentacion.respuesta(respuesta))
    sesion |> actualizar_token(respuesta) |> ciclo()
  end

  defp mostrar(nil), do: :ok
  defp mostrar(texto), do: IO.puts(texto)

  defp actualizar_token(sesion, {:ok, {:conectado, %{token: token}}}),
    do: %{sesion | token: token}

  defp actualizar_token(sesion, {:ok, :desconectado}), do: %{sesion | token: nil}
  defp actualizar_token(sesion, _respuesta), do: sesion

  defp salir(sesion) do
    if sesion.token, do: Servidor.peticion(sesion.token, "disconnect", sesion.receptor)
    Receptor.detener(sesion.receptor)
    IO.puts("Hasta pronto.")
  end
end
