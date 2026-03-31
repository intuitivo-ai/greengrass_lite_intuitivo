defmodule GreenGrassLite.ConfigYaml do
  @moduledoc false

  @nucleus "aws.greengrass.Nucleus"
  @nucleus_lite "aws.greengrass.NucleusLite"
  @nucleus_lite_version "2.4.0"

  @doc """
  Normalizes Greengrass Core-style nucleus config to Nucleus Lite `config.yaml` for ggconfigd.
  """
  def transform_for_lite(yml) when is_binary(yml) do
    case YamlElixir.read_from_string(yml) do
      {:ok, doc} ->
        doc
        |> stringify_keys_deep()
        |> normalize_document()
        |> encode_document()

      {:error, _} = err ->
        err
    end
  end

  defp stringify_keys_deep(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      {key, stringify_keys_deep(v)}
    end)
  end

  defp stringify_keys_deep(value) when is_list(value) do
    Enum.map(value, &stringify_keys_deep/1)
  end

  defp stringify_keys_deep(value), do: value

  defp normalize_document(doc) when is_map(doc) do
    system = doc |> Map.get("system", %{}) |> normalize_system()
    services = doc |> Map.get("services", %{}) |> normalize_services()

    doc
    |> Map.put("system", system)
    |> Map.put("services", services)
  end

  defp normalize_system(sys) when is_map(sys) do
    cond do
      Map.has_key?(sys, "rootpath") and not Map.has_key?(sys, "rootPath") ->
        sys
        |> Map.put("rootPath", sys["rootpath"])
        |> Map.delete("rootpath")

      Map.has_key?(sys, "rootpath") and Map.has_key?(sys, "rootPath") ->
        Map.delete(sys, "rootpath")

      true ->
        sys
    end
  end

  defp normalize_services(services) when is_map(services) do
    has_nucleus = Map.has_key?(services, @nucleus)
    has_lite = Map.has_key?(services, @nucleus_lite)

    cond do
      has_nucleus and not has_lite ->
        nucleus = Map.fetch!(services, @nucleus)

        services
        |> Map.delete(@nucleus)
        |> Map.put(@nucleus_lite, nucleus_to_lite_service(nucleus))

      has_lite ->
        lite = Map.fetch!(services, @nucleus_lite)
        services = if has_nucleus, do: Map.delete(services, @nucleus), else: services
        Map.put(services, @nucleus_lite, ensure_lite_service(lite))

      true ->
        services
    end
  end

  defp nucleus_to_lite_service(%{} = svc) do
    conf = Map.get(svc, "configuration", %{}) |> ensure_lite_configuration()

    svc
    |> Map.put("version", @nucleus_lite_version)
    |> Map.put("configuration", conf)
  end

  defp ensure_lite_service(%{} = svc) do
    conf = Map.get(svc, "configuration", %{}) |> ensure_lite_configuration()
    Map.put(svc, "configuration", conf)
  end

  defp ensure_lite_configuration(%{} = conf) do
    conf = prune_platform_override_for_lite(conf)

    conf
    |> Map.put_new("greengrassDataPlanePort", "8443")
    |> Map.put_new("runWithDefault", %{"posixUser" => "root:root"})
  end

  @architecture_detail_key "architecture.detail"

  defp prune_platform_override_for_lite(conf) do
    case Map.get(conf, "platformOverride") do
      po when is_map(po) ->
        board_hint =
          Map.get(po, "mainBoardType") || Map.get(po, "main_board_type")

        po =
          po
          |> Map.delete("mainBoardType")
          |> Map.delete("main_board_type")

        po =
          if board_hint && not Map.has_key?(po, @architecture_detail_key) do
            Map.put(po, @architecture_detail_key, to_string(board_hint))
          else
            po
          end

        if map_size(po) == 0 do
          Map.delete(conf, "platformOverride")
        else
          Map.put(conf, "platformOverride", po)
        end

      _ ->
        conf
    end
  end

  defp encode_document(doc) when is_map(doc) do
    body =
      doc
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join("\n", fn key ->
        val = Map.fetch!(doc, key)
        to_string(key) <> ":" <> encode_nested(val, 0)
      end)

    {:ok, "---\n" <> body <> "\n"}
  end

  defp encode_nested(map, _depth) when is_map(map) and map_size(map) == 0 do
    ""
  end

  defp encode_nested(map, depth) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join("\n", fn {k, v} ->
        pad = String.duplicate("  ", depth + 1)
        kk = to_string(k)

        case v do
          v when is_map(v) ->
            "#{pad}#{kk}:" <> encode_nested(v, depth + 1)

          v when is_list(v) ->
            "#{pad}#{kk}:" <> encode_list(v, depth + 1)

          _ ->
            "#{pad}#{kk}: #{encode_scalar(v)}"
        end
      end)

    "\n" <> inner
  end

  defp encode_nested(value, _depth) do
    " " <> encode_scalar(value)
  end

  defp encode_list(items, depth) do
    pad = String.duplicate("  ", depth + 1)

    Enum.map_join(items, "\n", fn
      item when is_map(item) ->
        block = encode_nested(item, depth + 1)
        "#{pad}-" <> block

      item ->
        "#{pad}- #{encode_scalar(item)}"
    end)
    |> case do
      "" -> ""
      s -> "\n" <> s
    end
  end

  defp encode_scalar(v) when is_binary(v) do
    if simple_unquoted?(v) do
      v
    else
      "\"" <> String.replace(v, "\"", "\\\"") <> "\""
    end
  end

  defp encode_scalar(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_scalar(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 10)
  defp encode_scalar(true), do: "true"
  defp encode_scalar(false), do: "false"
  defp encode_scalar(nil), do: "null"

  defp simple_unquoted?(v) do
    v != "" and String.match?(v, ~r/^[A-Za-z0-9_.\-]+$/) and not String.match?(v, ~r/^\d+$/)
  end
end
