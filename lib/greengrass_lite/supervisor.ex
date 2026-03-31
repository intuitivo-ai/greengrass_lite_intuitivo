defmodule GreenGrassLite.Supervisor do
  @moduledoc """
  Supervises all greengrass-lite daemons.

  Daemons are started in dependency order:
  1. ggconfigd   - config store (all others depend on this)
  2. iotcored    - MQTT connection to AWS IoT Core
  3. tesd        - TES credential exchange
  4. tes-serverd - local HTTP TES server
  5. ggdeploymentd - deployment handler (IoT Jobs)
  6. ggpubsubd   - pub/sub IPC
  7. ggipcd      - IPC socket
  8. gghealthd   - health monitoring
  9. gg-fleet-statusd - fleet status reporting
  """

  use Supervisor

  @default_opts %{
    config_path: "/home/ggc_user/config.yaml",
    config_dir: "/home/ggc_user/config.d",
    root_path: "/home/ggc_user",
    bin_dir: "/usr/bin"
  }

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Map.merge(@default_opts, Map.new(opts))

    children = [
      daemon_spec(:ggconfigd, config, ["-c", config.config_path, "-C", config.config_dir]),
      daemon_spec(:iotcored, config, []),
      daemon_spec(:tesd, config, []),
      daemon_spec(:"tes-serverd", config, []),
      daemon_spec(:ggdeploymentd, config, []),
      daemon_spec(:ggpubsubd, config, []),
      daemon_spec(:ggipcd, config, []),
      daemon_spec(:gghealthd, config, []),
      daemon_spec(:"gg-fleet-statusd", config, [])
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp daemon_spec(name, config, args) do
    bin = Path.join(config.bin_dir, to_string(name))

    %{
      id: name,
      start: {GreenGrassLite.Daemon, :start_link, [{name, bin, args}]},
      restart: :permanent,
      shutdown: 5_000
    }
  end
end
