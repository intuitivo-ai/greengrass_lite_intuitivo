defmodule GreenGrassLite.Daemon do
  @moduledoc """
  GenServer that manages a single greengrass-lite daemon process via `Port`.

  Stdout/stderr are appended to `/home/ggc_user/logs/<name>.log` (same layout idea
  as classic Greengrass under the GG root `logs/` directory). Each complete line
  is also logged with `Logger.info/1` so RingLogger and other backends see the
  stream at the default level.
  """

  use GenServer
  require Logger

  @log_dir "/home/ggc_user/logs"
  @work_dir "/home/ggc_user"

  defstruct [:name, :bin, :args, :port, :os_pid, :log_io]

  def start_link({name, bin, args}) do
    GenServer.start_link(__MODULE__, {name, bin, args}, name: via(name))
  end

  def stop(name) do
    GenServer.call(via(name), :stop)
  end

  def alive?(name) do
    case GenServer.whereis(via(name)) do
      nil -> false
      pid -> GenServer.call(pid, :alive?)
    end
  end

  defp via(name), do: {:global, {__MODULE__, name}}

  @impl true
  def init({name, bin, args}) do
    Logger.info("GREENGRASS_LITE_DAEMON_STARTING #{name}")

    case File.exists?(bin) do
      true ->
        Process.flag(:trap_exit, true)
        send(self(), :start_daemon)
        {:ok, %__MODULE__{name: name, bin: bin, args: args}}

      false ->
        Logger.warning("GREENGRASS_LITE_DAEMON_BIN_NOT_FOUND #{name} #{bin}")
        {:ok, %__MODULE__{name: name, bin: bin, args: args}}
    end
  end

  @impl true
  def handle_info(:start_daemon, %{bin: bin, args: args, name: name} = state) do
    unless File.exists?(bin) do
      Logger.warning("GREENGRASS_LITE_DAEMON_BIN_NOT_FOUND #{name} #{bin}")
      {:noreply, state}
    else
      {log_io, log_path} = open_daemon_log(name)

      port =
        Port.open({:spawn_executable, bin}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          cd: String.to_charlist(@work_dir),
          args: args
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      if log_path do
        Logger.info("GREENGRASS_LITE_DAEMON_STARTED #{name} pid=#{os_pid} log=#{log_path}")
      else
        Logger.info("GREENGRASS_LITE_DAEMON_STARTED #{name} pid=#{os_pid}")
      end

      {:noreply, %{state | port: port, os_pid: os_pid, log_io: log_io}}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port, name: name} = state) do
    write_daemon_log(state.log_io, data)
    log_daemon_lines(name, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port, name: name} = state) do
    Logger.warning("GREENGRASS_LITE_DAEMON_EXITED #{name} status=#{status}")
    {:stop, {:daemon_exit, status}, %{state | port: nil, os_pid: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port, name: name} = state) do
    Logger.warning("GREENGRASS_LITE_DAEMON_PORT_EXIT #{name} reason=#{inspect(reason)}")
    {:stop, reason, %{state | port: nil, os_pid: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("GREENGRASS_LITE_DAEMON_UNEXPECTED #{state.name} #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:alive?, _from, state) do
    {:reply, state.port != nil, state}
  end

  def handle_call(:stop, _from, %{port: port} = state) when port != nil do
    Port.close(port)
    {:stop, :normal, :ok, %{state | port: nil, os_pid: nil}}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def terminate(_reason, %{port: port, name: name, log_io: log_io}) do
    Logger.info("GREENGRASS_LITE_DAEMON_TERMINATING #{name}")
    close_log_io(log_io)

    if port != nil do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  def terminate(_reason, state) do
    close_log_io(Map.get(state, :log_io))
    :ok
  end

  defp open_daemon_log(name) do
    File.mkdir_p!(@log_dir)
    path = Path.join(@log_dir, "#{Atom.to_string(name)}.log")

    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        {io, path}

      {:error, reason} ->
        Logger.warning(
          "GREENGRASS_LITE_DAEMON_LOG_OPEN_FAILED #{name} path=#{path} reason=#{inspect(reason)}"
        )

        {nil, nil}
    end
  end

  defp write_daemon_log(nil, _data), do: :ok

  defp write_daemon_log(io, data) when is_binary(data) do
    IO.binwrite(io, data)
  end

  defp log_daemon_lines(name, data) when is_binary(data) do
    for line <- String.split(data, "\n", trim: true) do
      Logger.info("[#{name}] #{line}")
    end
  end

  defp close_log_io(nil), do: :ok

  defp close_log_io(io) do
    try do
      File.close(io)
    rescue
      _ -> :ok
    end
  end
end
