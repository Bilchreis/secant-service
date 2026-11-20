defmodule SecantService.FrappyServer do
  @moduledoc """
  Runs the simulated cryostat SEC node from frappy (`frappy_demo.cryo`) as an
  OS process for end to end tests.

  Uses `frappy-server` from the PATH if there is one, otherwise runs it from
  PyPI through `uvx`.
  """

  @frappy_version "0.20.9"
  @startup_timeout 60_000

  defstruct [:port, :os_pid, :tcp_port]

  @doc "The command line that starts a frappy server, or nil if there is none."
  def command do
    cond do
      path = System.find_executable("frappy-server") ->
        {path, []}

      path = System.find_executable("uvx") ->
        {path, ["--from", "frappy-core==#{@frappy_version}", "frappy-server"]}

      true ->
        nil
    end
  end

  def available?, do: command() != nil

  @doc "A TCP port nothing listens on right now."
  def free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @doc """
  Starts a cryostat node listening on `tcp_port` and waits until it accepts
  connections. `dir` holds its config and logs.

  Options: `:equipment_id` and `:description` of the node.
  """
  def start(dir, tcp_port, opts \\ []) do
    {executable, args} = command() || raise "neither frappy-server nor uvx found"

    File.write!(Path.join(dir, "cryo_cfg.py"), config(tcp_port, opts))

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args ++ ["cryo"],
        env:
          for name <- ~w(FRAPPY_CONFDIR FRAPPY_LOGDIR FRAPPY_PIDDIR) do
            {String.to_charlist(name), String.to_charlist(dir)}
          end
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    server = %__MODULE__{port: port, os_pid: os_pid, tcp_port: tcp_port}

    wait_until(@startup_timeout, "frappy to listen on port #{tcp_port}", fn ->
      listening?(tcp_port)
    end)

    server
  end

  @doc "Stops the node and waits until its port is closed."
  def stop(%__MODULE__{} = server) do
    System.cmd("kill", ["-TERM", to_string(server.os_pid)], stderr_to_stdout: true)

    wait_until(10_000, "frappy to stop", fn -> not listening?(server.tcp_port) end)

    if Port.info(server.port), do: Port.close(server.port)
    :ok
  end

  @doc "Polls `fun` until it returns a truthy value, which is returned."
  def wait_until(timeout, what, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(deadline, what, fun)
  end

  defp do_wait_until(deadline, what, fun) do
    cond do
      result = fun.() ->
        result

      System.monotonic_time(:millisecond) > deadline ->
        raise "timed out waiting for #{what}"

      true ->
        Process.sleep(100)
        do_wait_until(deadline, what, fun)
    end
  end

  defp listening?(tcp_port) do
    case :gen_tcp.connect(~c"127.0.0.1", tcp_port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp config(tcp_port, opts) do
    equipment_id = Keyword.get(opts, :equipment_id, "cryo_e2e.secant.test")
    description = Keyword.get(opts, :description, "simulated cryostat")

    """
    # Keep the test node out of SECoP discovery, so a secant-service running
    # on this network does not pick it up
    import frappy.server

    class NoDiscovery:
        def __init__(self, *args, **kwargs):
            pass

        def run(self):
            pass

        def shutdown(self):
            pass

    frappy.server.UDPListener = NoDiscovery

    Node(#{inspect(equipment_id)}, #{inspect(description)}, 'tcp://#{tcp_port}')

    Mod('cryo',
        'frappy_demo.cryo.Cryostat',
        'A simulated cc cryostat',
        T_start=10.0,
        target=10.0,
        looptime=1,
        ramp=6,
        maxpower=20.0,
        heater=4.1,
        mode='pid',
        tolerance=0.1,
        window=30,
        timeout=900,
        p=40,
        i=10,
        d=2,
    )
    """
  end
end
