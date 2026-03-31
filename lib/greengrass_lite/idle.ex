defmodule GreenGrassLite.Idle do
  @moduledoc false
  # Placeholder worker when :autostart is false (no Nucleus Lite on this image/target).

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_), do: {:ok, %{}}
end
