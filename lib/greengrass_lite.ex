defmodule GreenGrassLite do
  @moduledoc """
  Manager for AWS IoT Greengrass Nucleus Lite daemons on Nerves.

  OTP application `:greengrass_lite` starts `GreenGrassLite.Application`, which
  runs boot prep (`GreenGrassLite.Boot`) and supervises the C daemons when
  `config :greengrass_lite, autostart: true` (and the control file allows it).

  Provides start/stop/status control for the greengrass-lite C daemons,
  replacing the Java-based Greengrass Nucleus (.jar).
  """

  defdelegate start_link(opts), to: GreenGrassLite.Supervisor
  defdelegate enable(), to: GreenGrassLite.Control
  defdelegate disable(), to: GreenGrassLite.Control
  defdelegate status(), to: GreenGrassLite.Control
end
