defmodule GreenGrassLite.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if autostart?() do
        [
          {DynamicSupervisor,
           name: GreenGrassLite.DaemonDynamicSupervisor,
           strategy: :one_for_one,
           max_children: 1},
          {GreenGrassLite.Launcher, []}
        ]
      else
        [{GreenGrassLite.Idle, []}]
      end

    opts = [strategy: :one_for_one, name: GreenGrassLite.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp autostart? do
    Application.get_env(:greengrass_lite, :autostart, false) &&
      GreenGrassLite.Control.enabled?()
  end
end
