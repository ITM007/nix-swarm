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

  test "a state term emitted like module.nix parses into the service state contract" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-module-bridge-#{System.unique_integer([:positive])}.config"
      )

    contents = """
    {peers, []}.
    {nodes, []}.
    {services, [
      [
        {name, <<"paperless">>},
        {replicas, 1},
        {unit_template, <<"paperless.service">>},
        {allowed_nodes, []},
        {autoscaling, [{enable, false}, {minReplicas, 1}, {maxReplicas, 1}]},
        {state, [
          {dirs, [<<"/var/lib/paperless">>]},
          {backup, [
            {schedule, <<"hourly">>},
            {target, <<"ssh://borg@backup/./paperless">>}
          ]},
          {restore, <<"borg-latest">>},
          {auto_heal, false},
          {heal_grace_sec, 600}
        ]}
      ]
    ]}.
    {runtime, [
      {connect_interval_ms, 1000},
      {reconcile_interval_ms, 1000},
      {autoscale_interval_ms, 1000},
      {failure_grace_ms, 5000},
      {recovery_stabilization_ms, 2000},
      {command_timeout_ms, 5000},
      {executor, [{adapter, systemd}]}
    ]}.
    """

    File.write!(path, contents)
    {:ok, terms} = NixSwarm.Config.load_from_path(path)
    config = NixSwarm.Config.normalize(terms)
    service = hd(config.services)

    assert service.state == %{
             dirs: ["/var/lib/paperless"],
             backup: %{schedule: "hourly", target: "ssh://borg@backup/./paperless"},
             restore: "borg-latest",
             auto_heal: false,
             heal_grace_sec: 600
           }

    assert :ok == NixSwarm.Config.validate(config)
    File.rm(path)
  end

  test "a state term of undefined (module default) leaves state nil" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-module-bridge-#{System.unique_integer([:positive])}.config"
      )

    contents = """
    {peers, []}.
    {nodes, []}.
    {services, [
      [
        {name, <<"web">>},
        {replicas, 2},
        {unit_template, <<"web@%{slot}.service">>},
        {allowed_nodes, []},
        {autoscaling, [{enable, false}, {minReplicas, 2}, {maxReplicas, 2}]},
        {state, undefined}
      ]
    ]}.
    """

    File.write!(path, contents)
    {:ok, terms} = NixSwarm.Config.load_from_path(path)
    config = NixSwarm.Config.normalize(terms)
    assert hd(config.services).state == nil
    assert :ok == NixSwarm.Config.validate(config)
    File.rm(path)
  end
end
