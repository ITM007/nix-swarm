defmodule NixSwarmWeb.ConfigSourceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NixSwarmWeb.ConfigSource

  @fixture Path.expand("../fixtures/config_source", __DIR__)

  setup do
    on_exit(fn -> Application.delete_env(:nix_swarm_web, :config_source) end)
    :ok
  end

  describe "load/1" do
    test "is disabled when no source is configured" do
      source = ConfigSource.load(nil)

      refute source.enabled?
      assert source.groups == []
    end

    test "is disabled when the configured path is missing or not a directory" do
      assert capture_log(fn ->
               source = ConfigSource.load("/definitely/not/a/real/nix/path")

               refute source.enabled?
               assert source.groups == []
             end)
    end

    test "indexes nix files grouped by their directory role" do
      source = ConfigSource.load(@fixture)

      assert source.enabled?
      labels = Enum.map(source.groups, & &1.label)

      assert "Cluster" in labels
      assert "Machines" in labels
      assert "Services" in labels

      refute Enum.any?(
               Enum.flat_map(source.groups, & &1.files),
               &String.ends_with?(&1.rel, "secrets.nix")
             )
    end

    test "excludes secrets directories and credential-looking filenames" do
      source = ConfigSource.load(@fixture)
      rels = Enum.flat_map(source.groups, & &1.files) |> Enum.map(& &1.rel)

      refute Enum.any?(rels, &(&1 == "secrets/blocked.nix"))
      refute Enum.any?(rels, &(&1 == "secrets.nix"))
      refute Enum.any?(rels, &(&1 == "machines/cookie-in-name.nix"))
      assert "cluster.nix" in rels
      assert "machines/node-a.nix" in rels
      assert "services/web.nix" in rels
    end

    test "excludes hidden directories" do
      source = ConfigSource.load(@fixture)
      rels = Enum.flat_map(source.groups, & &1.files) |> Enum.map(& &1.rel)

      refute Enum.any?(rels, &String.starts_with?(&1, ".git/"))
    end

    test "cluster group lists root files with a stable order" do
      source = ConfigSource.load(@fixture)
      cluster = Enum.find(source.groups, &(&1.label == "Cluster"))

      assert Enum.map(cluster.files, & &1.rel) == ["cluster.nix", "flake.nix"]
    end
  end

  describe "read/2" do
    setup do
      {:ok, source} = {:ok, ConfigSource.load(@fixture)}
      {:ok, source: source}
    end

    test "returns indexed file contents", %{source: source} do
      assert {:ok, content, truncated?} = ConfigSource.read(source, "cluster.nix")

      refute truncated?
      assert content =~ "services.nix-swarm"
    end

    test "rejects relative escapes", %{source: source} do
      assert {:error, :forbidden} = ConfigSource.read(source, "../cluster.nix")
      assert {:error, :forbidden} = ConfigSource.read(source, "machines/../../flake.nix")
    end

    test "rejects absolute paths", %{source: source} do
      assert {:error, :forbidden} = ConfigSource.read(source, "/etc/passwd")
    end

    test "rejects files outside the scanned index", %{source: source} do
      assert {:error, :forbidden} = ConfigSource.read(source, "secrets/blocked.nix")
    end

    test "returns an error when an indexed file disappears", %{source: _source} do
      dir =
        Path.join(
          System.tmp_dir!(),
          "nix-swarm-config-source-read-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "fleeting.nix")
      File.write!(path, "{ ... }: { }\n")
      fleeting = ConfigSource.load(dir)
      File.rm!(path)

      assert {:error, :enoent} = ConfigSource.read(fleeting, "fleeting.nix")
    end
  end

  describe "resolve/3" do
    setup do
      {:ok, source} = {:ok, ConfigSource.load(@fixture)}
      {:ok, source: source}
    end

    test "resolves a node to its machine file by nodeName", %{source: source} do
      assert ConfigSource.resolve(source, "node", "node-a@cluster") == "machines/node-a.nix"
    end

    test "resolves a service by exact basename", %{source: source} do
      assert ConfigSource.resolve(source, "service", "web") == "services/web.nix"
    end

    test "returns nil for unknown nodes and services", %{source: source} do
      assert ConfigSource.resolve(source, "node", "unknown@host") == nil
      assert ConfigSource.resolve(source, "service", "missing") == nil
    end

    test "returns nil when the source is disabled" do
      assert ConfigSource.resolve(ConfigSource.load(nil), "node", "node-a@cluster") == nil
    end

    test "falls back to a targeted enable-pattern content match" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "nix-swarm-config-resolve-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(dir, "services"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "services/grouped.nix"),
        "jellyfin.enable = true;\ntransmission = {\n  enable = true;\n};\n"
      )

      File.write!(Path.join(dir, "services/network.nix"), "jellyfin.home:80 { };\n")

      source = ConfigSource.load(dir)

      assert ConfigSource.resolve(source, "service", "jellyfin") == "services/grouped.nix"
      assert ConfigSource.resolve(source, "service", "transmission") == "services/grouped.nix"
      assert ConfigSource.resolve(source, "service", "adguardhome") == nil
    end
  end

  describe "service_ports/2" do
    test "extracts configured ports without evaluating the source" do
      source = ConfigSource.load(@fixture)

      assert ConfigSource.service_ports(source, ["example-web", "missing"]) == %{
               "example-web" => [8080]
             }
    end

    test "returns no ports for a disabled source" do
      assert ConfigSource.service_ports(ConfigSource.load(nil), ["example-web"]) == %{}
    end
  end

  describe "large file truncation" do
    test "reads only the configured byte cap and reports truncation" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "nix-swarm-config-source-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      big = Path.join(dir, "big.nix")
      File.write!(big, String.duplicate("# padding line\n", 60_000))
      source = ConfigSource.load(dir)

      assert {:ok, content, true} = ConfigSource.read(source, "big.nix")
      assert byte_size(content) <= ConfigSource.max_bytes()
    end
  end
end
