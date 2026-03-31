defmodule GreenGrassLite.Control do
  @moduledoc """
  Enable/disable/status control for greengrass-lite.
  Uses a control file to persist desired state across reboots.
  """

  require Logger

  @control_file "/root/.greengrass_control.txt"

  @doc """
  Returns the current status: :enabled, :disabled, or :unknown.
  """
  def status do
    case File.read(@control_file) do
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
    File.write(@control_file, "enabled")
  end

  @doc """
  Disables greengrass-lite. Daemons will not start on next boot.
  """
  def disable do
    File.write(@control_file, "disabled")
  end

  @doc """
  Returns true if greengrass-lite is enabled.
  """
  def enabled? do
    status() == :enabled
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
