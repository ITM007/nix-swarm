defmodule NixSwarmModuleBridgeTest do
  use ExUnit.Case, async: true

  defp write_config!(overrides \\ %{}) do
    timings = Map.merge(defaults(), overrides)

    path =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-module-bridge-#{System.unique_integer([:positive])}.config"
      )

    contents = """
    {peers, []}.
    {nodes, []}.
    {services, []}.
    {runtime, [
    #{String.trim(format_timings(timings))},
    {executor, [{adapter, systemd}]}
    ]}.
    """

    File.write!(path, contents)
    path
  end

  defp defaults do
    %{
      connect_interval_ms: 1_000,
      reconcile_interval_ms: 1_000,
      autoscale_interval_ms: 1_000,
      failure_grace_ms: 5_000,
      recovery_stabilization_ms: 2_000,
      command_timeout_ms: 5_000
    }
  end

  defp format_timings(timings) do
    Enum.map_join(timings, ",\n", fn {key, value} -> "{#{key}, #{value}}" end)
  end

  test "the emitted runtime term reaches normalized config with production defaults" do
    path = write_config!()
    {:ok, terms} = NixSwarm.Config.load_from_path(path)
    config = NixSwarm.Config.normalize(terms)

    assert config.runtime.connect_interval_ms == 1_000
    assert config.runtime.reconcile_interval_ms == 1_000
    assert config.runtime.autoscale_interval_ms == 1_000
    assert config.runtime.failure_grace_ms == 5_000
    assert config.runtime.recovery_stabilization_ms == 2_000
    assert config.runtime.command_timeout_ms == 5_000
    assert config.runtime.executor == %{adapter: :systemd}
    assert :ok == NixSwarm.Config.validate(config)
    File.rm(path)
  end

  test "Nix-rendered overrides replace defaults and validate" do
    path =
      write_config!(%{
        reconcile_interval_ms: 5_000,
        command_timeout_ms: 30_000,
        failure_grace_ms: 10_000
      })

    {:ok, terms} = NixSwarm.Config.load_from_path(path)
    config = NixSwarm.Config.normalize(terms)
    assert config.runtime.reconcile_interval_ms == 5_000
    assert config.runtime.command_timeout_ms == 30_000
    assert config.runtime.failure_grace_ms == 10_000
    assert config.runtime.connect_interval_ms == 1_000
    assert :ok == NixSwarm.Config.validate(config)
    File.rm(path)
  end
end
