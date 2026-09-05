defmodule NixSwarmWeb.ExportTest do
  use ExUnit.Case, async: true

  alias NixSwarmWeb.{ClusterSnapshot, Export}

  @captured_at ~U[2026-09-05 12:34:56Z]
  @fixture Path.expand("../fixtures/operator_snapshot.json", __DIR__)

  defp snapshot(opts) do
    payload = @fixture |> File.read!() |> :json.decode()
    ClusterSnapshot.normalize(payload, Keyword.merge([captured_at: @captured_at], opts))
  end

  test "snapshot JSON is deterministic and keeps timestamp, stale, and partial metadata" do
    value = snapshot(stale?: true)
    first = Export.snapshot_json(value)

    second =
      Export.snapshot_json(%{
        value
        | nodes: Enum.reverse(value.nodes),
          services: Enum.reverse(value.services)
      })

    decoded = :json.decode(first)

    assert first == second
    assert String.valid?(first)
    assert decoded["captured_at"] == "2026-09-05T12:34:56Z"
    assert decoded["captured_at_ms"] == DateTime.to_unix(@captured_at, :millisecond)
    assert decoded["stale?"] == true
    assert decoded["drift"]["config_consistent?"] == false
    assert decoded["errors"] != []
    assert Enum.any?(decoded["errors"], &(&1["node"] == "node-c@cluster"))
  end

  test "snapshot JSON preserves UTF-8 and replaces invalid byte sequences" do
    value = %{
      captured_at: @captured_at,
      stale?: false,
      queried_node: "nóde-☃",
      nodes: [%{name: <<0xFF, "-node">>, host: "café.example", status: "up"}],
      services: [],
      drift: %{config_consistent?: nil},
      graph: %{},
      metrics: %{},
      errors: [%{reason: "échec"}]
    }

    body = Export.snapshot_json(value)

    assert String.valid?(body)
    assert body =~ "nóde-☃"
    assert body =~ "café.example"
    assert body =~ "échec"
    assert body =~ "�-node"
  end

  test "nodes CSV has stable order and neutralizes formula fields" do
    value = %{
      captured_at: @captured_at,
      stale?: true,
      nodes: [
        %{
          name: "+node",
          host: "host,one",
          status: "up",
          availability: "active",
          version: "1",
          build_version: "b",
          release_version: "r",
          config_digest: "d",
          services: [],
          error: nil
        },
        %{
          name: "alpha",
          host: "host",
          status: "down",
          availability: "unknown",
          version: "2",
          build_version: "b2",
          release_version: "r2",
          config_digest: "=digest",
          services: [%{name: "svc"}],
          error: %{reason: "timeout"}
        }
      ]
    }

    csv = Export.nodes_csv(value)
    [header, first, second] = String.split(csv, "\r\n", trim: true)

    assert header ==
             "captured_at,stale,name,host,status,availability,version,build_version,release_version,config_digest,services,error"

    assert first =~ "2026-09-05T12:34:56Z,true,alpha,host,down,unknown,2,b2,r2,'=digest,svc"
    assert first =~ "timeout"

    assert second =~ "2026-09-05T12:34:56Z,true,'+node,\"host,one\",up,active,1,b,r,d,,"

    assert first != second
  end

  test "services CSV is stable, flattened by slot, UTF-8 safe, and formula-safe" do
    value = %{
      captured_at: @captured_at,
      stale?: false,
      services: [
        %{
          name: "é-service",
          desired_replicas: 1,
          status: "running",
          running_slots: 1,
          degraded?: false,
          awaiting_heal?: false,
          unplaced_slots: 0,
          state_contract: %{restore: "none"},
          slots: [%{slot: 0, unit: "@unit", owner: "-owner", node: "node", status: "running"}]
        },
        %{
          name: "api",
          desired_replicas: 1,
          status: "degraded",
          running_slots: 0,
          degraded?: true,
          awaiting_heal?: true,
          unplaced_slots: 1,
          slots: [%{slot: 1, unit: "api@1.service", owner: nil, status: "unplaced"}]
        }
      ]
    }

    csv = Export.services_csv(value)
    [header, api, service] = String.split(csv, "\r\n", trim: true)

    assert header ==
             "captured_at,stale,service,desired_replicas,status,running_slots,degraded,awaiting_heal,unplaced_slots,slot,unit,owner,node,slot_status,state_contract"

    assert api =~
             "2026-09-05T12:34:56Z,false,api,1,degraded,0,true,true,1,1,api@1.service,, ,unplaced" or
             api =~
               "2026-09-05T12:34:56Z,false,api,1,degraded,0,true,true,1,1,api@1.service,,,unplaced"

    assert service =~ "é-service"
    assert service =~ "'@unit"
    assert service =~ "'-owner"
  end

  test "logs text accepts query payloads, preserves UTF-8, and caps lines" do
    lines = Enum.map(1..1_005, &"ligne-#{&1}-é")

    assert Export.logs_text(%{"logs" => lines}) ==
             lines |> Enum.take(1_000) |> Enum.join("\n")

    assert Export.logs_text({:ok, %{:logs => ["one", "two"]}}) == "one\ntwo"
    assert Export.logs_text(["one", "two", "three"], 2) == "one\ntwo"
    assert Export.logs_text("déjà texte") == "déjà texte"
    refute Export.logs_text(%{"logs" => ["one", <<0xFF>>]}) =~ <<0xFF>>
  end

  test "CSV quoting follows RFC 4180 for commas, quotes, and newlines" do
    value = %{
      captured_at: @captured_at,
      stale?: false,
      nodes: [%{name: "=danger, \"quoted\"\r\nnext", host: "h", status: "up", services: []}]
    }

    csv = Export.nodes_csv(value)

    assert csv =~ "\"'=danger, \"\"quoted\"\"\r\nnext\""
    assert String.ends_with?(csv, "\r\n")
  end
end
