defmodule GreenGrassLite.DaemonLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag skip: not File.dir?("/proc/self")
  @env_keys [:ggc_root, :always_on_log_daemons, :gg_config_socket]

  defmodule FixtureSupervisor do
    use Supervisor
    def start_link(children), do: Supervisor.start_link(__MODULE__, children)

    def init(children),
      do: Supervisor.init(children, strategy: :rest_for_one, max_restarts: 100, max_seconds: 60)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "gg_lifecycle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    bin = Path.join(root, "stubborn_daemon")
    source = Path.expand("../fixtures/stubborn_daemon.c", __DIR__)
    {output, status} = System.cmd("cc", ["-Wall", "-Wextra", "-Werror", source, "-o", bin])
    assert status == 0, output
    previous = Map.new(@env_keys, &{&1, Application.fetch_env(:greengrass_lite, &1)})
    Application.put_env(:greengrass_lite, :ggc_root, root)
    Application.put_env(:greengrass_lite, :always_on_log_daemons, [:iotcored])
    Application.put_env(:greengrass_lite, :gg_config_socket, Path.join(root, "gg_config"))

    on_exit(fn ->
      # Only terminate fixture processes whose executable still matches this test.
      for pid <- recorded_pids(root), File.read_link("/proc/#{pid}/exe") == {:ok, bin} do
        System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
      end

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:greengrass_lite, key, value)
          :error -> Application.delete_env(:greengrass_lite, key)
        end
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root, bin: bin}
  end

  test "normal stop does not leave the OS daemon running", %{root: root, bin: bin} do
    daemon = start_daemon!(bin, root)
    assert eventually(fn -> length(recorded_pids(root)) == 1 end)
    [os_pid] = recorded_pids(root)
    assert running?(os_pid)

    :ok = GenServer.stop(daemon)
    refute running?(os_pid), "orderly shutdown returned before the OS daemon exited"
  end

  test "explicit stop waits for the OS daemon to exit", %{root: root, bin: bin} do
    _daemon = start_daemon!(bin, root)
    assert eventually(fn -> length(recorded_pids(root)) == 1 end)
    [os_pid] = recorded_pids(root)
    assert :ok = GreenGrassLite.Daemon.stop(:iotcored)
    refute running?(os_pid)
  end

  test "ggconfigd can create its socket after more than one output window", %{
    root: root,
    bin: bin
  } do
    args = [Path.join(root, "pids"), "config", Path.join(root, "gg_config")]
    Application.put_env(:greengrass_lite, :always_on_log_daemons, [:ggconfigd])
    started_at = System.monotonic_time(:millisecond)
    daemon = start_supervised!({GreenGrassLite.Daemon, {:ggconfigd, bin, args}})
    assert System.monotonic_time(:millisecond) - started_at < 2_000
    assert File.exists?(Path.join(root, "gg_config"))

    assert eventually(fn ->
             File.read!(Path.join([root, "logs", "ggconfigd.log"])) =~ "STDOUT_COMPLETE"
           end)

    assert Process.alive?(daemon)
  end

  test "an owner crash during continuous output still cleans up", %{root: root, bin: bin} do
    daemon = start_daemon!(bin, root, "chatty")
    assert eventually(fn -> length(recorded_pids(root)) == 1 end)
    [os_pid] = recorded_pids(root)

    assert eventually(fn ->
             case File.read(Path.join([root, "logs", "iotcored.log"])) do
               {:ok, data} -> data =~ "CONTINUOUS_OUTPUT"
               _ -> false
             end
           end)

    Process.exit(daemon, :kill)
    assert eventually(fn -> not running?(os_pid) end)
  end

  test "killing the owner also contains a daemon that ignores SIGTERM", %{root: root, bin: bin} do
    daemon = start_daemon!(bin, root)
    assert eventually(fn -> length(recorded_pids(root)) == 1 end)
    [os_pid] = recorded_pids(root)
    ref = Process.monitor(daemon)
    Process.exit(daemon, :kill)
    assert_receive {:DOWN, ^ref, :process, ^daemon, :killed}

    assert eventually(fn -> not running?(os_pid) end), "OS daemon survived an untrappable exit"
  end

  test "a duplicate start message cannot spawn another daemon", %{root: root, bin: bin} do
    daemon = start_daemon!(bin, root)
    assert eventually(fn -> length(recorded_pids(root)) == 1 end)
    send(daemon, :start_daemon)
    _state = :sys.get_state(daemon)
    refute eventually(fn -> length(recorded_pids(root)) > 1 end, 250)
    GenServer.stop(daemon)
  end

  test "rest_for_one restart cycles do not accumulate OS daemons", %{root: root, bin: bin} do
    children =
      for name <- [:iotcored, :tesd] do
        Supervisor.child_spec({GreenGrassLite.Daemon, {name, bin, [Path.join(root, "pids")]}},
          id: name
        )
      end

    start_supervised!({FixtureSupervisor, children})

    for cycle <- 1..20 do
      assert eventually(fn -> length(recorded_pids(root)) == cycle * 2 end)

      assert eventually(fn -> count_running(root) == 2 end),
             "OS daemons accumulated at cycle #{cycle}"

      owner = GenServer.whereis({:global, {GreenGrassLite.Daemon, :iotcored}})
      Process.exit(owner, :kill)
    end

    assert eventually(fn -> length(recorded_pids(root)) == 42 end)
    assert eventually(fn -> count_running(root) == 2 end)
    stop_supervised!(FixtureSupervisor)
    assert eventually(fn -> count_running(root) == 0 end)
  end

  test "stdout and stderr keep flowing beyond the monitor's output window", %{
    root: root,
    bin: bin
  } do
    daemon = start_daemon!(bin, root, "output")
    log = Path.join([root, "logs", "iotcored.log"])

    assert eventually(fn ->
             case File.read(log) do
               {:ok, data} ->
                 String.contains?(data, "STDOUT_COMPLETE") and
                   String.contains?(data, "STDERR_COMPLETE")

               _ ->
                 false
             end
           end)

    assert Process.alive?(daemon)
    GenServer.stop(daemon)
  end

  test "OS exit status still stops its owner", %{root: root, bin: bin} do
    daemon = start_daemon!(bin, root)
    ref = Process.monitor(daemon)
    assert eventually(fn -> length(recorded_pids(root)) == 1 end)
    [os_pid] = recorded_pids(root)
    {_, 0} = System.cmd("kill", ["-USR1", to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, ^daemon, {:daemon_exit, 7}}, 2_000
    assert eventually(fn -> count_running(root) == 0 end)
  end

  defp start_daemon!(bin, root, mode \\ "idle") do
    {:ok, pid} =
      GreenGrassLite.Daemon.start_link({:iotcored, bin, [Path.join(root, "pids"), mode]})

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp recorded_pids(root) do
    case File.read(Path.join(root, "pids")) do
      {:ok, text} -> text |> String.split() |> Enum.map(&String.to_integer/1)
      _ -> []
    end
  end

  defp count_running(root), do: Enum.count(recorded_pids(root), &running?/1)

  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        (stat |> String.split(") ", parts: 2) |> List.last() |> String.first()) not in ["Z", "X"]

      _ ->
        false
    end
  end

  defp eventually(fun, timeout \\ 2_000),
    do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        poll(fun, deadline)
    end
  end
end
