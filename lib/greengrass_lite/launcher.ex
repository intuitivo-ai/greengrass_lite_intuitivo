defmodule GreenGrassLite.Launcher do
  @moduledoc false

  use GenServer
  require Logger

  @dynamic_sup GreenGrassLite.DaemonDynamicSupervisor
  @max_poll_backoff_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Wake the launcher to retry starting daemons (e.g. after writing certs). Non-blocking."
  def wake do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :wake)
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    schedule_poll(0)
    {:ok, default_state()}
  end

  defp default_state, do: %{poll_backoff_ms: nil}

  @impl true
  def handle_cast(:wake, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    base_ms = Application.get_env(:greengrass_lite, :credentials_poll_interval_ms, 3_000)

    {next_state, schedule_ms} =
      cond do
        not GreenGrassLite.Control.enabled?() ->
          _ = stop_daemons_tree()
          {%{state | poll_backoff_ms: nil}, base_ms}

        not GreenGrassLite.Credentials.ready?() ->
          _ = stop_daemons_tree()
          {%{state | poll_backoff_ms: nil}, base_ms}

        true ->
          case ensure_daemons_running() do
            :ok ->
              {%{state | poll_backoff_ms: nil}, base_ms}

            {:error, reason} ->
              Logger.warning("GREENGRASS_LITE_LAUNCHER_START_FAILED #{inspect(reason)}")
              prev = state.poll_backoff_ms || base_ms
              # Back off when spawn fails (e.g. :eagain / EMFILE) to avoid log + retry storms.
              next_backoff = min(@max_poll_backoff_ms, max(base_ms, trunc(prev * 1.5)))
              {%{state | poll_backoff_ms: next_backoff}, next_backoff}
          end
      end

    schedule_poll(schedule_ms)
    {:noreply, next_state}
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp ensure_daemons_running do
    if daemons_supervisor_running?() do
      :ok
    else
      :ok = GreenGrassLite.Boot.setup!()
      opts = Application.get_env(:greengrass_lite, :supervisor_opts, [])

      spec = %{
        id: GreenGrassLite.Supervisor,
        start: {GreenGrassLite.Supervisor, :start_link, [opts]},
        restart: :permanent,
        type: :supervisor
      }

      case DynamicSupervisor.start_child(@dynamic_sup, spec) do
        {:ok, _pid} ->
          Logger.info("GREENGRASS_LITE_DAEMONS_STARTED_AFTER_CREDENTIALS")
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp daemons_supervisor_running? do
    Process.whereis(GreenGrassLite.Supervisor) != nil
  end

  defp stop_daemons_tree do
    case DynamicSupervisor.which_children(@dynamic_sup) do
      [] ->
        :ok

      children ->
        Enum.each(children, fn
          {_, pid, :supervisor, _} when is_pid(pid) ->
            _ = DynamicSupervisor.terminate_child(@dynamic_sup, pid)

          _ ->
            :ok
        end)
    end
  end
end
