defmodule GreenGrassLite.Config do
  @moduledoc """
  Manages greengrass-lite YAML configuration files.
  Handles reading/writing config.yaml in NucleusLite format.
  """

  require Logger

  @default_config_path "/home/ggc_user/config.yaml"

  @doc """
  Reads and parses the greengrass config YAML file.
  """
  def read(path \\ @default_config_path) do
    case YamlElixir.read_from_file(path) do
      {:ok, config} -> {:ok, config}
      {:error, reason} ->
        Logger.error("GREENGRASS_LITE_CONFIG_READ_ERROR #{path} #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Extracts the NucleusLite service configuration section.
  """
  def nucleus_config(config) when is_map(config) do
    get_in(config, ["services", "aws.greengrass.NucleusLite", "configuration"]) ||
      get_in(config, ["services", "aws.greengrass.Nucleus", "configuration"])
  end

  @doc """
  Returns the thing name from the config.
  """
  def thing_name(config) when is_map(config) do
    get_in(config, ["system", "thingName"])
  end

  @doc """
  Returns the IoT credential endpoint from the config.
  """
  def cred_endpoint(config) when is_map(config) do
    nucleus_config(config)["iotCredEndpoint"]
  end

  @doc """
  Returns the IoT data endpoint from the config.
  """
  def data_endpoint(config) when is_map(config) do
    nucleus_config(config)["iotDataEndpoint"]
  end

  @doc """
  Returns the IoT role alias from the config.
  """
  def role_alias(config) when is_map(config) do
    nucleus_config(config)["iotRoleAlias"]
  end

  @doc """
  Returns the AWS region from the config.
  """
  def aws_region(config) when is_map(config) do
    nucleus_config(config)["awsRegion"]
  end

  @doc """
  Returns the certificate file path from the config.
  """
  def cert_path(config) when is_map(config) do
    get_in(config, ["system", "certificateFilePath"])
  end

  @doc """
  Returns the private key file path from the config.
  """
  def key_path(config) when is_map(config) do
    get_in(config, ["system", "privateKeyPath"])
  end

  @doc """
  Returns the root CA file path from the config.
  """
  def root_ca_path(config) when is_map(config) do
    get_in(config, ["system", "rootCaPath"])
  end

  @doc """
  Writes a config.yaml for NucleusLite with the given parameters.
  """
  def write(path \\ @default_config_path, params) do
    yaml = """
    ---
    system:
      certificateFilePath: "#{params[:cert_path]}"
      privateKeyPath: "#{params[:key_path]}"
      rootCaPath: "#{params[:root_ca_path]}"
      rootPath: "#{params[:root_path]}"
      thingName: "#{params[:thing_name]}"
    services:
      aws.greengrass.NucleusLite:
        componentType: "NUCLEUS"
        configuration:
          awsRegion: "#{params[:aws_region]}"
          iotRoleAlias: "#{params[:role_alias]}"
          iotDataEndpoint: "#{params[:data_endpoint]}"
          iotCredEndpoint: "#{params[:cred_endpoint]}"
          greengrassDataPlanePort: "8443"
          runWithDefault:
            posixUser: "#{params[:posix_user] || "root:root"}"
    """

    case File.write(path, yaml) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("GREENGRASS_LITE_CONFIG_WRITE_ERROR #{path} #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Checks that all required credential files exist.
  """
  def files_ready?(config) when is_map(config) do
    paths = [cert_path(config), key_path(config), root_ca_path(config)]
    Enum.all?(paths, fn p -> p != nil and File.exists?(p) end)
  end

  def files_ready?(_), do: false
end
