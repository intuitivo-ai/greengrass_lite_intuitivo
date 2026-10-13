defmodule GreenGrassLite.DaemonProcess do
  @moduledoc false
  require Logger

  # The monitor outlives a killed Elixir owner long enough to reap its child.
  # No cgroup is used: Greengrass component processes are outside this lifecycle.
  @kill_delay_ms 500
  @close_timeout_ms 2_000

  def open(bin, args, directory) do
    port =
      Port.open({:spawn_executable, MuonTrap.muontrap_path()}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        cd: String.to_charlist(directory),
        args: [
          "--capture-output",
          "--capture-stderr",
          "--delay-to-sigkill",
          to_string(@kill_delay_ms),
          "--",
          bin | args
        ]
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, monitor_os_pid} ->
        {:ok, port, monitor_os_pid}

      _ ->
        close(port, nil)
        :error
    end
  end

  def acknowledge(port, data) do
    # MuonTrap stops reading child output when this byte window is exhausted.
    MuonTrap.Port.report_bytes_handled(port, byte_size(data))
  end

  def close(nil, _monitor_os_pid), do: :ok

  def close(port, monitor_os_pid) do
    identity = process_identity(monitor_os_pid)
    close_port(port)

    # On Linux/Nerves wait for the monitor's cleanup before an orderly restart.
    # Check start time too so PID reuse cannot make us wait on another process.
    if identity != nil do
      deadline = System.monotonic_time(:millisecond) + @close_timeout_ms
      await_exit(monitor_os_pid, identity, deadline)
    else
      :ok
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp await_exit(pid, identity, deadline) do
    cond do
      process_identity(pid) != identity ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.error("GREENGRASS_LITE_DAEMON_CLEANUP_TIMEOUT monitor_pid=#{pid}")
        {:error, :cleanup_timeout}

      true ->
        Process.sleep(10)
        await_exit(pid, identity, deadline)
    end
  end

  defp process_identity(nil), do: nil

  defp process_identity(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_comm, fields] <- String.split(stat, ") ", parts: 2),
         [state | _] = fields <- String.split(fields),
         false <- state in ["Z", "X"] do
      Enum.at(fields, 19)
    else
      _ -> nil
    end
  end
end
