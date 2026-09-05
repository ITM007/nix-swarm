defmodule NixSwarmWeb.Export do
  @moduledoc """
  Pure, bounded serializers for the read-only web export surface.

  Exporters take already normalized snapshots and query results. They never read
  from the query socket or create files, which keeps response generation small,
  deterministic, and easy to exercise without a running broker.
  """

  @max_log_lines 1_000

  @node_headers [
    "captured_at",
    "stale",
    "name",
    "host",
    "status",
    "availability",
    "version",
    "build_version",
    "release_version",
    "config_digest",
    "services",
    "error"
  ]

  @service_headers [
    "captured_at",
    "stale",
    "service",
    "desired_replicas",
    "status",
    "running_slots",
    "degraded",
    "awaiting_heal",
    "unplaced_slots",
    "slot",
    "unit",
    "owner",
    "node",
    "slot_status",
    "state_contract"
  ]

  @doc "Returns deterministic JSON for a normalized snapshot."
  @spec snapshot_json(map()) :: binary()
  def snapshot_json(snapshot) when is_map(snapshot),
    do: snapshot |> json_value() |> IO.iodata_to_binary()

  def snapshot_json(_snapshot), do: snapshot_json(%{})

  @doc "Returns an RFC 4180 node inventory with stable headers and ordering."
  @spec nodes_csv(map()) :: binary()
  def nodes_csv(snapshot) when is_map(snapshot) do
    metadata = metadata(snapshot)

    rows =
      snapshot
      |> value(:nodes, [])
      |> list_value()
      |> Enum.sort_by(&sort_key(value(&1, :name, "")))
      |> Enum.map(&node_row(&1, metadata))

    csv_document(@node_headers, rows)
  end

  def nodes_csv(_snapshot), do: csv_document(@node_headers, [])

  @doc "Returns an RFC 4180 service/slot inventory with stable headers and ordering."
  @spec services_csv(map()) :: binary()
  def services_csv(snapshot) when is_map(snapshot) do
    metadata = metadata(snapshot)

    rows =
      snapshot
      |> value(:services, [])
      |> list_value()
      |> Enum.sort_by(&sort_key(value(&1, :name, "")))
      |> Enum.flat_map(&service_rows(&1, metadata))

    csv_document(@service_headers, rows)
  end

  def services_csv(_snapshot), do: csv_document(@service_headers, [])

  @doc "Returns bounded log text from a query result or a list of log lines."
  @spec logs_text(term(), keyword() | pos_integer()) :: binary()
  def logs_text(data, opts \\ [])

  def logs_text(data, max_lines) when is_integer(max_lines),
    do: logs_text(data, max_lines: max_lines)

  def logs_text(data, opts) when is_list(opts) do
    max_lines = bounded_max_lines(Keyword.get(opts, :max_lines, @max_log_lines))

    data
    |> unwrap_log_result()
    |> log_lines()
    |> Enum.take(max_lines)
    |> Enum.map(&safe_text/1)
    |> Enum.join("\n")
  end

  @doc "Returns the maximum number of lines accepted by the log exporter."
  @spec max_log_lines() :: pos_integer()
  def max_log_lines, do: @max_log_lines

  @doc "Returns valid UTF-8, replacing malformed byte sequences."
  @spec utf8(binary()) :: binary()
  def utf8(value) when is_binary(value), do: repair_utf8(value)
  def utf8(value), do: safe_text(value)

  defp node_row(node, metadata) do
    services =
      node
      |> value(:services, [])
      |> list_value()
      |> Enum.map(&safe_text(value(&1, :name, "")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort()
      |> Enum.join(";")

    [
      metadata.captured_at,
      metadata.stale,
      value(node, :name, nil),
      value(node, :host, nil),
      value(node, :status, nil),
      value(node, :availability, nil),
      value(node, :version, nil),
      value(node, :build_version, nil),
      value(node, :release_version, nil),
      value(node, :config_digest, nil),
      services,
      value(node, :error, nil)
    ]
  end

  defp service_rows(service, metadata) do
    slots = service |> value(:slots, []) |> list_value()
    slots = if slots == [], do: [nil], else: sort_slots(slots)

    Enum.map(slots, fn slot ->
      [
        metadata.captured_at,
        metadata.stale,
        value(service, :name, nil),
        value(service, :desired_replicas, nil),
        value(service, :status, nil),
        value(service, :running_slots, nil),
        value(service, :degraded?, nil),
        value(service, :awaiting_heal?, nil),
        value(service, :unplaced_slots, nil),
        value(slot, :slot, nil),
        value(slot, :unit, nil),
        value(slot, :owner, nil),
        value(slot, :node, value(slot, :owner, nil)),
        value(slot, :status, nil),
        value(service, :state_contract, nil)
      ]
    end)
  end

  defp sort_slots(slots) do
    Enum.sort_by(slots, fn slot ->
      {slot_number(value(slot, :slot, nil)), safe_text(value(slot, :unit, "")),
       safe_text(value(slot, :owner, ""))}
    end)
  end

  defp slot_number(value) when is_integer(value), do: value
  defp slot_number(value) when is_float(value), do: trunc(value)

  defp slot_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> 1_000_000
    end
  end

  defp slot_number(_value), do: 1_000_000

  defp sort_key(value) do
    value
    |> safe_text()
    |> String.trim_leading("=")
    |> String.trim_leading("+")
    |> String.trim_leading("-")
    |> String.trim_leading("@")
  end

  defp metadata(snapshot) do
    %{
      captured_at: timestamp(value(snapshot, :captured_at, nil)),
      stale: boolean_text(value(snapshot, :stale?, false))
    }
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp(value), do: safe_text(value)

  defp csv_document(headers, rows) do
    [headers | rows]
    |> Enum.map(&csv_row/1)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp csv_row(row), do: row |> Enum.map(&csv_field/1) |> Enum.join(",")

  defp csv_field(value) do
    value = csv_text(value)
    value = neutralize_formula(value)

    if String.contains?(value, [",", "\"", "\r", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp csv_text(nil), do: ""
  defp csv_text(value) when is_binary(value), do: safe_text(value)
  defp csv_text(value) when is_boolean(value), do: boolean_text(value)
  defp csv_text(%DateTime{} = value), do: timestamp(value)
  defp csv_text(%NaiveDateTime{} = value), do: timestamp(value)
  defp csv_text(value) when is_map(value), do: snapshot_json(value)
  defp csv_text(value) when is_list(value), do: value |> Enum.map(&csv_text/1) |> Enum.join(";")
  defp csv_text(value), do: safe_text(value)

  defp neutralize_formula(<<first::utf8, _rest::binary>> = value)
       when first in [?=, ?+, ?-, ?@],
       do: "'" <> value

  defp neutralize_formula(value), do: value

  defp boolean_text(true), do: "true"
  defp boolean_text(false), do: "false"

  defp safe_text(nil), do: ""
  defp safe_text(value) when is_binary(value), do: repair_utf8(value)
  defp safe_text(value) when is_atom(value), do: value |> Atom.to_string() |> safe_text()
  defp safe_text(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_text(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp safe_text(value), do: value |> to_string() |> safe_text()

  defp repair_utf8(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      value when is_binary(value) ->
        value

      {:error, valid, rest} ->
        repaired_prefix = if valid == "", do: "", else: repair_utf8(valid)

        case rest do
          <<_invalid, tail::binary>> -> repaired_prefix <> "�" <> repair_utf8(tail)
          <<>> -> repaired_prefix
        end

      {:incomplete, valid, rest} ->
        repaired_prefix = if valid == "", do: "", else: repair_utf8(valid)

        case rest do
          <<_invalid, tail::binary>> -> repaired_prefix <> "�" <> repair_utf8(tail)
          <<>> -> repaired_prefix
        end
    end
  end

  defp json_value(%DateTime{} = value), do: json_value(DateTime.to_iso8601(value))
  defp json_value(%NaiveDateTime{} = value), do: json_value(NaiveDateTime.to_iso8601(value))

  defp json_value(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {safe_text(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))

    [
      "{",
      Enum.intersperse(
        Enum.map(entries, fn {key, item} ->
          [:json.encode(safe_text(key)), ":", json_value(canonical_collection(key, item))]
        end),
        ","
      ),
      "}"
    ]
  end

  defp json_value(value) when is_list(value) do
    ["[", Enum.intersperse(Enum.map(value, &json_value/1), ","), "]"]
  end

  defp json_value(value) when is_tuple(value), do: json_value(Tuple.to_list(value))
  defp json_value(nil), do: "null"
  defp json_value(true), do: "true"
  defp json_value(false), do: "false"
  defp json_value(value) when is_atom(value), do: json_value(Atom.to_string(value))
  defp json_value(value) when is_binary(value), do: :json.encode(safe_text(value))
  defp json_value(value) when is_integer(value), do: Integer.to_string(value)
  defp json_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp json_value(value), do: json_value(to_string(value))

  defp canonical_collection(key, value) when is_list(value) do
    case key do
      key when key in ["nodes", "services"] ->
        sort_by_fields(value, [:name])

      key when key in ["slots", "units"] ->
        sort_by_fields(value, [:slot, :unit])

      "ownership_edges" ->
        sort_by_fields(value, [:service, :slot, :unit])

      key when key in ["errors", "diagnostics"] ->
        Enum.sort_by(value, &json_value/1)

      key when key in ["configured_nodes", "live_nodes", "placement_nodes"] ->
        Enum.sort_by(value, &safe_text/1)

      _ ->
        value
    end
  end

  defp canonical_collection(_key, value), do: value

  defp sort_by_fields(values, fields) do
    Enum.sort_by(values, fn item ->
      Enum.map(fields, &safe_text(value(item, &1, "")))
    end)
  end

  defp unwrap_log_result({:ok, data}), do: unwrap_log_result(data)
  defp unwrap_log_result({:error, _reason}), do: []
  defp unwrap_log_result(data), do: data

  defp log_lines(data) when is_binary(data), do: String.split(safe_text(data), "\n", trim: false)
  defp log_lines(data) when is_list(data), do: data

  defp log_lines(data) when is_map(data) do
    value(data, :logs, value(data, :lines, value(data, :text, []))) |> log_lines()
  end

  defp log_lines(_data), do: []

  defp bounded_max_lines(value) when is_integer(value) and value in 1..@max_log_lines, do: value
  defp bounded_max_lines(_value), do: @max_log_lines

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default
end
