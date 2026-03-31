defmodule GreenGrassLite do
  @moduledoc """
  Manager for AWS IoT Greengrass Nucleus Lite daemons on Nerves.

  OTP application `:greengrass_lite` starts `GreenGrassLite.Application`, which
  runs `GreenGrassLite.Launcher` when `config :greengrass_lite, autostart: true`
  and the control file allows it. Daemons start only after credential files exist
  under `/home/ggc_user/`; call `wake_launcher/0` after provisioning to retry immediately.

  Provides start/stop/status control for the greengrass-lite C daemons,
  replacing the Java-based Greengrass Nucleus (.jar).
  """

  defdelegate start_link(opts), to: GreenGrassLite.Supervisor
  defdelegate enable(), to: GreenGrassLite.Control
  defdelegate disable(), to: GreenGrassLite.Control
  defdelegate status(), to: GreenGrassLite.Control
  defdelegate runtime_status(), to: GreenGrassLite.Control

  def wake_launcher do
    GreenGrassLite.Launcher.wake()
  end
end
