defmodule GreenGrassLite.CredentialsTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "ggc_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:greengrass_lite, :ggc_root)
    end)

    Application.put_env(:greengrass_lite, :ggc_root, dir)
    {:ok, dir: dir}
  end

  test "ready?/0 false until all four files exist", %{dir: dir} do
    refute GreenGrassLite.Credentials.ready?()

    for f <- ["config.yaml", "device.pem.crt", "CA.pem", "private.pem.key"] do
      :ok = File.touch(Path.join(dir, f))
    end

    assert GreenGrassLite.Credentials.ready?()
  end
end
