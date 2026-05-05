defmodule GreenGrassLite.Daemon do
  @moduledoc """
  GenServer that manages a single greengrass-lite daemon process via `Port`.

  Stdout/stderr are always appended to `<ggc_root>/logs/<name>.log` (default
  `ggc_root` `/home/ggc_user`). By default
  that stream is **not** duplicated into Elixir `Logger` (too verbose). Enable with:

      config :greengrass_lite, forward_daemon_logs_to_logger: true
      # optional: :debug | :info | :warning
      config :greengrass_lite, forward_daemon_log_level: :info
      # when forwarding, skip C lines starting with T[ / D[ (trace/debug), e.g. MQTT pings
      config :greengrass_lite, forward_daemon_logs_skip_c_debug: true

  Daemon logs are rotated by size to bound disk usage. Defaults: 5 MB per
  file, 1 archived generation (`<name>.log` + `<name>.log.1`). Override with:

      config :greengrass_lite, daemon_log_max_bytes: 5 * 1024 * 1024
      config :greengrass_lite, daemon_log_keep: 1
  """

  use GenServer
  require Logger

  defp ggc_root do
    Application.get_env(:greengrass_lite, :ggc_root, "/home/ggc_user")
  end

  defp log_dir, do: Path.join(ggc_root(), "logs")
  defp work_dir, do: ggc_root()
  # Core-bus socket created by ggconfigd; others must not start until it exists.
  @gg_config_socket "/run/greengrass/gg_config"
  @gg_config_wait_attempts 300
  @gg_config_poll_ms 50

  @default_log_max_bytes 5 * 1024 * 1024
  @default_log_keep 1

  defp log_max_bytes,
    do: Application.get_env(:greengrass_lite, :daemon_log_max_bytes, @default_log_max_bytes)

  defp log_keep_count,
    do: Application.get_env(:greengrass_lite, :daemon_log_keep, @default_log_keep)

  defstruct [:name, :bin, :args, :port, :os_pid, :log_io, :log_path, log_size: 0]

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
    Logger.debug("GREENGRASS_LITE_DAEMON_STARTING #{name}")

    case File.exists?(bin) do
      true ->
        Process.flag(:trap_exit, true)

        if name == :ggconfigd do
          case spawn_daemon_port(name, bin, args) do
            {:ok, port, os_pid, log_io, log_path, log_size} ->
              wait_for_gg_config_socket(@gg_config_wait_attempts)
              log_started(name, os_pid, log_path)

              {:ok,
               %__MODULE__{
                 name: name,
                 bin: bin,
                 args: args,
                 port: port,
                 os_pid: os_pid,
                 log_io: log_io,
                 log_path: log_path,
                 log_size: log_size
               }}

            :error ->
              {:ok, %__MODULE__{name: name, bin: bin, args: args}}
          end
        else
          send(self(), :start_daemon)
          {:ok, %__MODULE__{name: name, bin: bin, args: args}}
        end

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
      case spawn_daemon_port(name, bin, args) do
        {:ok, port, os_pid, log_io, log_path, log_size} ->
          log_started(name, os_pid, log_path)

          {:noreply,
           %{
             state
             | port: port,
               os_pid: os_pid,
               log_io: log_io,
               log_path: log_path,
               log_size: log_size
           }}

        :error ->
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, name: name} = state) do
    {new_io, new_size} =
      write_daemon_log(name, state.log_io, state.log_path, state.log_size, data)

    log_daemon_lines(name, data)
    {:noreply, %{state | log_io: new_io, log_size: new_size}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, name: name} = state) do
    Logger.warning("GREENGRASS_LITE_DAEMON_EXITED #{name} status=#{status}")
    {:stop, {:daemon_exit, status}, %{state | port: nil, os_pid: nil}}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port, name: name} = state) do
    Logger.warning("GREENGRASS_LITE_DAEMON_PORT_EXIT #{name} reason=#{inspect(reason)}")
    {:stop, reason, %{state | port: nil, os_pid: nil}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("GREENGRASS_LITE_DAEMON_UNEXPECTED #{state.name} #{inspect(msg)}")
    {:noreply, state}
  end

  defp spawn_daemon_port(name, bin, args) do
    {log_io, log_path, log_size} = open_daemon_log(name)

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        cd: String.to_charlist(work_dir()),
        args: args
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        {:ok, port, os_pid, log_io, log_path, log_size}

      _ ->
        :error
    end
  end

  defp log_started(name, os_pid, log_path) do
    if log_path do
      Logger.info("GREENGRASS_LITE_DAEMON_STARTED #{name} pid=#{os_pid} log=#{log_path}")
    else
      Logger.info("GREENGRASS_LITE_DAEMON_STARTED #{name} pid=#{os_pid}")
    end
  end

  defp wait_for_gg_config_socket(0) do
    Logger.warning(
      "GREENGRASS_LITE_GGCONFIG_SOCKET_WAIT_TIMEOUT path=#{@gg_config_socket} after #{@gg_config_wait_attempts * @gg_config_poll_ms}ms"
    )
  end

  defp wait_for_gg_config_socket(n) when n > 0 do
    if File.exists?(@gg_config_socket) do
      Logger.debug("GREENGRASS_LITE_GGCONFIG_SOCKET_READY #{@gg_config_socket}")
    else
      Process.sleep(@gg_config_poll_ms)
      wait_for_gg_config_socket(n - 1)
    end
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
    Logger.debug("GREENGRASS_LITE_DAEMON_TERMINATING #{name}")
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
    dir = log_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{Atom.to_string(name)}.log")

    initial_size = file_size(path)

    size =
      if initial_size >= log_max_bytes() do
        rotate_log_file(path)
        Logger.info("GREENGRASS_LITE_DAEMON_LOG_ROTATED #{name} path=#{path} reason=size_at_open")
        0
      else
        initial_size
      end

    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        {io, path, size}

      {:error, reason} ->
        Logger.warning(
          "GREENGRASS_LITE_DAEMON_LOG_OPEN_FAILED #{name} path=#{path} reason=#{inspect(reason)}"
        )

        {nil, nil, 0}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  # Shifts <path>.log -> <path>.log.1 -> <path>.log.2 ... up to log_keep_count/0,
  # discarding the oldest archive (so disk usage stays bounded).
  defp rotate_log_file(path) do
    keep = log_keep_count()

    if keep <= 0 do
      _ = File.rm(path)
    else
      _ = File.rm("#{path}.#{keep}")

      keep..2//-1
      |> Enum.each(fn n ->
        src = "#{path}.#{n - 1}"
        if File.exists?(src), do: _ = File.rename(src, "#{path}.#{n}")
      end)

      if File.exists?(path), do: _ = File.rename(path, "#{path}.1")
    end

    :ok
  end

  defp write_daemon_log(_name, nil, _path, _size, _data), do: {nil, 0}

  # Use :file.write/2 instead of IO.binwrite/2: the latter raises on {:error, reason}
  # (e.g. :enospc when /home/ggc_user or the log volume is full), which kills the GenServer
  # and restarts daemons in a tight loop without fixing the underlying disk issue.
  defp write_daemon_log(name, io, path, size, data) when is_binary(data) do
    case :file.write(io, data) do
      :ok ->
        maybe_rotate(name, io, path, size + byte_size(data))

      {:error, :enospc} ->
        log_enospc_once(name)
        # Best-effort recovery: rotation deletes the oldest archive, which usually
        # frees enough space to keep logging. If it still fails, fall back to the
        # old behavior of dropping chunks until disk space is freed.
        emergency_rotate(name, io, path)

      {:error, reason} ->
        Logger.warning(
          "GREENGRASS_LITE_DAEMON_LOG_WRITE_FAILED daemon=#{name} reason=#{inspect(reason)}"
        )

        {io, size}
    end
  end

  defp maybe_rotate(name, io, path, new_size) do
    if new_size >= log_max_bytes() do
      close_log_io(io)
      rotate_log_file(path)
      Logger.info("GREENGRASS_LITE_DAEMON_LOG_ROTATED #{name} path=#{path} reason=size")
      reopen_after_rotate(name, path)
    else
      {io, new_size}
    end
  end

  defp emergency_rotate(name, io, path) do
    close_log_io(io)
    rotate_log_file(path)

    case File.open(path, [:append, :binary]) do
      {:ok, new_io} ->
        Logger.info("GREENGRASS_LITE_DAEMON_LOG_ROTATED #{name} path=#{path} reason=enospc")
        Process.delete({:greengrass_lite_daemon, :enospc_logged, name})
        {new_io, 0}

      {:error, _reason} ->
        {nil, 0}
    end
  end

  defp reopen_after_rotate(name, path) do
    case File.open(path, [:append, :binary]) do
      {:ok, new_io} ->
        {new_io, 0}

      {:error, reason} ->
        Logger.warning(
          "GREENGRASS_LITE_DAEMON_LOG_REOPEN_FAILED #{name} path=#{path} reason=#{inspect(reason)}"
        )

        {nil, 0}
    end
  end

  defp log_enospc_once(name) do
    key = {:greengrass_lite_daemon, :enospc_logged, name}

    unless Process.get(key) do
      Process.put(key, true)

      Logger.error(
        "GREENGRASS_LITE_DAEMON_LOG_ENOSPC daemon=#{name} dir=#{log_dir()} — " <>
          "no space left on device while appending daemon log; chunks are dropped until space is freed. " <>
          "Prune #{log_dir()}/*.log or enlarge the partition (df -h /home/ggc_user)."
      )
    end
  end

  defp log_daemon_lines(name, data) when is_binary(data) do
    if Application.get_env(:greengrass_lite, :forward_daemon_logs_to_logger, false) do
      level = Application.get_env(:greengrass_lite, :forward_daemon_log_level, :info)
      skip_debug? = Application.get_env(:greengrass_lite, :forward_daemon_logs_skip_c_debug, true)

      for line <- String.split(data, "\n", trim: true),
          not (skip_debug? and c_stdout_debug_or_trace?(line)) do
        Logger.log(level, "[#{name}] #{line}")
      end
    end
  end

  # Greengrass Nucleus Lite prints e.g. "D[iotcored] mqtt.c:420: ..." / "T[...]" on stdout.
  defp c_stdout_debug_or_trace?(line) do
    t = String.trim_leading(line)
    String.starts_with?(t, "D[") or String.starts_with?(t, "T[")
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
