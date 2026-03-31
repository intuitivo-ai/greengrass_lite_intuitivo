defmodule GreenGrassLite.LauncherIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @app :greengrass_lite
  @env_keys ~w(autostart ggc_root control_file credentials_poll_interval_ms)a

  @moduletag :capture_log

  setup do
    root = Path.join(System.tmp_dir!(), "gglite_int_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    control_path = Path.join(root, "greengrass_control.txt")

    on_exit(fn ->
      _ = Application.stop(@app)

      Enum.each(@env_keys, fn key ->
        Application.delete_env(@app, key)
      end)

      {:ok, _} = Application.ensure_all_started(@app)
      File.rm_rf(root)
    end)

    {:ok, root: root, control: control_path}
  end

  test "does not start daemon supervisor until all credential files exist", %{
    root: root,
    control: control
  } do
    restart_lite!(root, control, creds: false, control_state: :absent)

    refute wait_until?(400, fn -> supervisor_started?() end),
           "supervisor should not start without credential files"
  end

  test "starts daemon supervisor when credentials exist", %{root: root, control: control} do
    restart_lite!(root, control, creds: true, control_state: :absent)

    assert wait_until?(3_000, fn -> supervisor_started?() end),
           "expected GreenGrassLite.Supervisor to start after credentials are present"

    rs = GreenGrassLite.Control.runtime_status()
    assert rs.credentials_ready
    assert rs.supervisor_started
    assert rs.enabled
    # Host CI has no gg binaries; daemons stay down but OTP tree is up.
    assert rs.mqtt == :inactive
  end

  test "starts supervisor after wake when credentials appear later", %{root: root, control: control} do
    restart_lite!(root, control, creds: false, control_state: :absent)
    Process.sleep(80)
    refute supervisor_started?()

    touch_credentials(root)
    GreenGrassLite.Launcher.wake()

    assert wait_until?(3_000, fn -> supervisor_started?() end)
  end

  test "stops daemon supervisor when credentials are removed", %{root: root, control: control} do
    restart_lite!(root, control, creds: true, control_state: :absent)

    assert wait_until?(3_000, fn -> supervisor_started?() end)

    _ = File.rm(Path.join(root, "config.yaml"))
    GreenGrassLite.Launcher.wake()

    assert wait_until?(3_000, fn -> not supervisor_started?() end),
           "expected supervisor to stop when credentials are incomplete"
  end

  test "stops daemon supervisor when control file disables lite", %{root: root, control: control} do
    restart_lite!(root, control, creds: true, control_state: :enabled)

    assert wait_until?(3_000, fn -> supervisor_started?() end)

    File.write!(control, "disabled")
    GreenGrassLite.Launcher.wake()

    assert wait_until?(3_000, fn -> not supervisor_started?() end),
           "expected supervisor to stop when control file is disabled"

    refute GreenGrassLite.Control.enabled?()
  end

  defp restart_lite!(root, control_path, opts) do
    _ = Application.stop(@app)

    File.mkdir_p!(Path.join(root, "logs"))

    if opts[:creds] do
      touch_credentials(root)
    else
      Enum.each(credential_names(), fn name ->
        _ = File.rm(Path.join(root, name))
      end)
    end

    case opts[:control_state] do
      :absent ->
        _ = File.rm(control_path)

      :enabled ->
        File.write!(control_path, "enabled")

      :disabled ->
        File.write!(control_path, "disabled")
    end

    Application.put_env(@app, :autostart, true)
    Application.put_env(@app, :ggc_root, root)
    Application.put_env(@app, :control_file, control_path)
    Application.put_env(@app, :credentials_poll_interval_ms, 30)

    {:ok, _} = Application.ensure_all_started(@app)
    :ok
  end

  defp touch_credentials(root) do
    Enum.each(credential_names(), fn name ->
      :ok = File.touch(Path.join(root, name))
    end)
  end

  defp credential_names do
    ~w(config.yaml device.pem.crt CA.pem private.pem.key)
  end

  defp supervisor_started? do
    Process.whereis(GreenGrassLite.Supervisor) != nil
  end

  defp wait_until?(timeout_ms, fun) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_loop(deadline, fun)
  end

  defp wait_until_loop(deadline, fun) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(15)
        wait_until_loop(deadline, fun)
      end
    end
  end
end
