defmodule GreenGrassLite.Boot do
  @moduledoc false

  require Logger

  @config_path "/home/ggc_user/config.yaml"
  @config_dir "/home/ggc_user/config.d"
  @logs_dir "/home/ggc_user/logs"

  @doc """
  Runs before Nucleus Lite daemons start: `/dev/fd` symlink and optional `config.yaml` normalization.
  """
  def setup! do
    ensure_dev_fd_symlink()
    ensure_lite_config_yaml_on_disk()
    :ok
  end

  @doc """
  Normalizes on-disk `config.yaml` for Nucleus Lite (Core-style keys → Lite).
  Safe to call from host apps after writing new YAML (e.g. credential refresh).
  """
  def ensure_lite_config_yaml_on_disk do
    _ = File.mkdir_p(@config_dir)
    _ = File.mkdir_p(@logs_dir)

    case File.read(@config_path) do
      {:ok, content} ->
        new_content = normalize_config_yaml_string(content)

        if new_content != content do
          case File.write(@config_path, new_content) do
            :ok ->
              Logger.info("GREENGRASS_LITE_CONFIG_BOOT_NORMALIZED #{@config_path}")

            {:error, reason} ->
              Logger.warning("GREENGRASS_LITE_CONFIG_BOOT_WRITE_FAILED #{inspect(reason)}")
          end
        end

      {:error, _} ->
        :ok
    end

    :ok
  end

  defp normalize_config_yaml_string(content) do
    case GreenGrassLite.ConfigYaml.transform_for_lite(content) do
      {:ok, yml} ->
        yml

      {:error, reason} ->
        Logger.info("GREENGRASS_LITE_CONFIG_BOOT_PARSE_FALLBACK #{inspect(reason)}")

        content
        |> String.replace("\r\n", "\n")
        |> String.replace("aws.greengrass.Nucleus:", "aws.greengrass.NucleusLite:")
        |> String.replace("rootpath:", "rootPath:")
    end
  end

  defp ensure_dev_fd_symlink do
    path = "/dev/fd"
    target = "/proc/self/fd"

    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :symlink do
      _ = File.rm(path)
    else
      _ -> :ok
    end

    case File.ln_s(target, path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} -> :ok
    end
  end
end
