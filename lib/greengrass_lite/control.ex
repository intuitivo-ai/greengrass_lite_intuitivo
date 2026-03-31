defmodule GreenGrassLite.Control do
  @moduledoc """
  Enable/disable/status control for greengrass-lite.
  Uses a control file to persist desired state across reboots.

  Override path in tests or custom images:

      config :greengrass_lite, control_file: \"/data/.greengrass_control.txt\"
  """

  require Logger

  @default_control_file "/root/.greengrass_control.txt"

  defp control_file_path do
    Application.get_env(:greengrass_lite, :control_file, @default_control_file)
  end

  @doc """
  Returns the current status: :enabled, :disabled, or :unknown.
  """
  def status do
    case File.read(control_file_path()) do
      {:ok, content} ->
        content = String.trim(content)

        cond do
          content in ["1", "enabled"] -> :enabled
          content in ["0", "disabled"] -> :disabled
          true -> :unknown
        end

      {:error, :enoent} ->
        :enabled

      {:error, reason} ->
        Logger.warning("GREENGRASS_LITE_CONTROL_READ_ERROR #{inspect(reason)}")
        :unknown
    end
  end

  @doc """
  Enables greengrass-lite. Daemons will be started on next boot.
  """
  def enable do
    File.write(control_file_path(), "enabled")
  end

  @doc """
  Disables greengrass-lite. Daemons will not start on next boot.
  """
  def disable do
    File.write(control_file_path(), "disabled")
  end

  @doc """
  Returns true unless the control file explicitly disables Lite (`disabled` / `0`).

  Matches firmware default: anything other than an explicit disable is treated as enabled.
  """
  def enabled? do
    status() != :disabled
  end

  @doc """
  Snapshot for operations dashboards: credentials, process state, and a heuristic
  for IoT Core MQTT (`iotcored` log: \"Connected to IoT core at …\").

  `mqtt` is `:inactive` (no iotcored), `:pending`, `:connected`, or `:disconnected`.
  """
  def runtime_status do
    creds = GreenGrassLite.Credentials.ready?()
    sup = Process.whereis(GreenGrassLite.Supervisor)
    daemons = daemon_status()
    all_alive =
      creds && map_size(daemons) > 0 && Enum.all?(daemons, fn {_, alive?} -> alive? end)

    iotcored_up = sup != nil && Map.get(daemons, :iotcored, false)

    mqtt =
      if iotcored_up do
        root = Application.get_env(:greengrass_lite, :ggc_root, "/home/ggc_user")
        GreenGrassLite.MqttHint.from_log_file(Path.join(root, "logs/iotcored.log"))
      else
        :inactive
      end

    %{
      enabled: enabled?(),
      credentials_ready: creds,
      supervisor_started: sup != nil,
      daemons: daemons,
      all_daemons_alive: all_alive,
      mqtt: mqtt
    }
  end

  @doc """
  Returns a map with status of each running daemon.
  """
  def daemon_status do
    daemons = [
      :ggconfigd,
      :iotcored,
      :tesd,
      :"tes-serverd",
      :ggdeploymentd,
      :ggpubsubd,
      :ggipcd,
      :gghealthd,
      :"gg-fleet-statusd"
    ]

    Map.new(daemons, fn name ->
      {name, GreenGrassLite.Daemon.alive?(name)}
    end)
  end

  @doc """
  Returns list of OS PIDs for all running greengrass-lite processes.
  """
  def pids do
    {output, 0} = System.cmd("ps", [])

    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "gg"))
    |> Enum.filter(fn line ->
      Enum.any?(
        ["ggconfigd", "iotcored", "tesd", "tes-serverd", "ggdeploymentd",
         "ggpubsubd", "ggipcd", "gghealthd", "gg-fleet-statusd"],
        &String.contains?(line, &1)
      )
    end)
    |> Enum.map(fn line ->
      line |> String.trim() |> String.split(~r/\s+/) |> List.first()
    end)
    |> Enum.reject(&is_nil/1)
  end
end
