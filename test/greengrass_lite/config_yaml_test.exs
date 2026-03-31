defmodule GreenGrassLite.ConfigYamlTest do
  use ExUnit.Case, async: true

  alias GreenGrassLite.ConfigYaml

  @core_yaml """
  system:
    certificateFilePath: "/home/ggc_user/device.pem.crt"
    privateKeyPath: "/home/ggc_user/private.pem.key"
    rootCaPath: "/home/ggc_user/CA.pem"
    rootpath: "/home/ggc_user/"
    thingName: "apop-test"
  services:
    aws.greengrass.Nucleus:
      componentType: "NUCLEUS"
      version: "2.11.1"
      configuration:
        awsRegion: "us-east-1"
        iotRoleAlias: "alias"
        iotDataEndpoint: "data.ats.iot.us-east-1.amazonaws.com"
        iotCredEndpoint: "creds.credentials.iot.us-east-1.amazonaws.com"
        platformOverride:
          os: "linux"
          architecture: "pi4_v7"
          mainBoardType: "pi4_v7"
  """

  test "transform_for_lite converts Nucleus to NucleusLite and rootpath to rootPath" do
    assert {:ok, out} = ConfigYaml.transform_for_lite(@core_yaml)
    assert {:ok, parsed} = YamlElixir.read_from_string(out)

    assert parsed["system"]["rootPath"] == "/home/ggc_user/"
    refute Map.has_key?(parsed["system"], "rootpath")

    lite = parsed["services"]["aws.greengrass.NucleusLite"]
    assert lite["version"] == "2.4.0"
    assert lite["configuration"]["greengrassDataPlanePort"] == "8443"
    assert lite["configuration"]["runWithDefault"]["posixUser"] == "root:root"
    refute Map.has_key?(parsed["services"], "aws.greengrass.Nucleus")

    po = lite["configuration"]["platformOverride"]
    assert po["os"] == "linux"
    assert po["architecture"] == "pi4_v7"
    assert po["architecture.detail"] == "pi4_v7"
    refute Map.has_key?(po, "mainBoardType")
    refute Map.has_key?(po, "main_board_type")
  end

  test "transform_for_lite maps board id to architecture.detail when that is all platformOverride has" do
    yml = """
    system:
      rootPath: "/x/"
    services:
      aws.greengrass.Nucleus:
        componentType: "NUCLEUS"
        version: "2.11.1"
        configuration:
          awsRegion: "us-east-1"
          platformOverride:
            main_board_type: "pi4_v7"
    """

    assert {:ok, out} = ConfigYaml.transform_for_lite(yml)
    assert {:ok, parsed} = YamlElixir.read_from_string(out)
    conf = parsed["services"]["aws.greengrass.NucleusLite"]["configuration"]
    assert conf["platformOverride"]["architecture.detail"] == "pi4_v7"
    refute Map.has_key?(conf["platformOverride"], "main_board_type")
  end

  test "transform_for_lite does not overwrite existing architecture.detail with mainBoardType" do
    yml = """
    system:
      rootPath: "/x/"
    services:
      aws.greengrass.Nucleus:
        componentType: "NUCLEUS"
        version: "2.11.1"
        configuration:
          awsRegion: "us-east-1"
          platformOverride:
            architecture.detail: "custom"
            mainBoardType: "ignored"
    """

    assert {:ok, out} = ConfigYaml.transform_for_lite(yml)
    assert {:ok, parsed} = YamlElixir.read_from_string(out)
    po = parsed["services"]["aws.greengrass.NucleusLite"]["configuration"]["platformOverride"]
    assert po["architecture.detail"] == "custom"
    refute Map.has_key?(po, "mainBoardType")
  end

  test "transform_for_lite keeps NucleusLite and fills defaults" do
    yml = """
    system:
      rootPath: "/x/"
    services:
      aws.greengrass.NucleusLite:
        componentType: "NUCLEUS"
        version: "2.4.0"
        configuration:
          awsRegion: "us-east-1"
    """

    assert {:ok, out} = ConfigYaml.transform_for_lite(yml)
    assert {:ok, parsed} = YamlElixir.read_from_string(out)
    conf = parsed["services"]["aws.greengrass.NucleusLite"]["configuration"]
    assert conf["greengrassDataPlanePort"] == "8443"
    assert conf["runWithDefault"]["posixUser"] == "root:root"
  end
end
