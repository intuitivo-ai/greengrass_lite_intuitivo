defmodule GreenGrassLite.MqttHint do
  @moduledoc false

  # Matches iotcored GG_LOGI in aws-greengrass-lite modules/iotcored/src/mqtt.c
  @connected "Connected to IoT core at"

  @disconnect_markers [
    "Exiting the MQTT thread",
    "Error in receive loop, closing connection",
    "Connection failed:",
    "Failed to create TLS connection",
    "Socket error detected",
    "Server-initiated DISCONNECT received"
  ]

  @doc """
  Best-effort MQTT session state from recent `iotcored` log lines (newest last).
  Returns `:pending` if there is no successful connect line in the window.
  """
  def from_lines(lines) when is_list(lines) do
    indexed = lines |> Enum.with_index()

    connect_idxs =
      for {line, i} <- indexed,
          String.contains?(line, @connected),
          do: i

    last_connect = List.last(connect_idxs)

    if last_connect == nil do
      :pending
    else
      disc_idxs =
        for {line, i} <- indexed,
            i > last_connect,
            Enum.any?(@disconnect_markers, &String.contains?(line, &1)),
            do: i

      if disc_idxs != [] do
        :disconnected
      else
        :connected
      end
    end
  end

  @doc """
  Reads up to `max_lines` from the end of `path` and passes them to `from_lines/1`.
  On missing/unreadable file returns `:pending`.
  """
  def from_log_file(path, max_lines \\ 500) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.take(-max_lines)
        |> from_lines()

      {:error, _} ->
        :pending
    end
  end
end
