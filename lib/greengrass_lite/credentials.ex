defmodule GreenGrassLite.Credentials do
  @moduledoc false

  @default_root "/home/ggc_user"
  @default_files %{
    config: "config.yaml",
    device_cert: "device.pem.crt",
    ca: "CA.pem",
    private_key: "private.pem.key"
  }

  @doc """
  True when all Greengrass Lite credential files exist on disk (same set as
  `In2Firmware.Services.Operations.GreenGrass.review_files/0`).
  """
  def ready? do
    paths = paths()
    Enum.all?(paths, &File.exists?/1)
  end

  @doc """
  List of absolute paths that must exist for `ready?/0` to be true.
  """
  def paths do
    root = Application.get_env(:greengrass_lite, :ggc_root, @default_root)
    files = Map.merge(@default_files, Application.get_env(:greengrass_lite, :credential_files, %{}))

    [
      Path.join(root, files.config),
      Path.join(root, files.device_cert),
      Path.join(root, files.ca),
      Path.join(root, files.private_key)
    ]
  end
end
