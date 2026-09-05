defmodule NixSwarmWeb.ExportController do
  @moduledoc "Read-only, in-memory browser download responses."

  use NixSwarmWeb, :controller

  alias NixSwarmWeb.{ClusterSnapshot, Export, QueryBroker, QueryRequest}

  @doc "Serves the current cached normalized snapshot as JSON."
  def snapshot(conn, _params), do: snapshot_response(conn, current_snapshot())

  @doc "Serves the current cached node inventory as CSV."
  def nodes(conn, _params), do: nodes_response(conn, current_snapshot())

  @doc "Serves the current cached service and ownership inventory as CSV."
  def services(conn, _params), do: services_response(conn, current_snapshot())

  @doc "Fetches one validated bounded log selection and serves it as text."
  def logs(conn, params) when is_map(params) do
    with {:ok, {scope, target, lines}} <- log_request(params),
         {:ok, log_data} <- QueryBroker.logs(QueryBroker.broker_name(), scope, target, lines) do
      logs_response(conn, log_data)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  @doc "Builds a snapshot download response without consulting a broker."
  def snapshot_response(conn, snapshot),
    do: export_response(conn, Export.snapshot_json(snapshot), "snapshot.json", "application/json")

  @doc "Builds a node CSV download response without consulting a broker."
  def nodes_response(conn, snapshot),
    do: export_response(conn, Export.nodes_csv(snapshot), "nodes.csv", "text/csv")

  @doc "Builds a service CSV download response without consulting a broker."
  def services_response(conn, snapshot),
    do: export_response(conn, Export.services_csv(snapshot), "services.csv", "text/csv")

  @doc "Builds a bounded log text download response without consulting a broker."
  def logs_response(conn, log_data),
    do: export_response(conn, Export.logs_text(log_data), "logs.txt", "text/plain")

  @doc "Returns a content-disposition value safe for a response header."
  @spec content_disposition(binary()) :: binary()
  def content_disposition(filename) when is_binary(filename) do
    filename =
      filename
      |> Export.utf8()
      |> String.replace(~r/[\r\n\"]|[\\\/]/u, "_")

    ~s(attachment; filename="#{filename}")
  end

  @doc "Validates the whitelisted log query parameters without opening a socket."
  @spec log_request(map()) :: {:ok, {atom(), binary(), pos_integer()}} | {:error, atom()}
  def log_request(params) when is_map(params) do
    scope = parameter(params, :scope)
    target = parameter(params, :target)
    lines = parse_lines(parameter(params, :lines))

    with {:ok, scope, target} <- normalize_scope_and_target(scope, target, params),
         {:ok, lines} <- lines,
         {:ok, _encoded} <- QueryRequest.encode(log_query(scope, target, lines)) do
      {:ok, {scope, target, lines}}
    end
  end

  def log_request(_params), do: {:error, :invalid_log_scope}

  defp export_response(conn, body, filename, content_type) do
    conn
    |> put_resp_content_type(content_type, "utf-8")
    |> put_resp_header("content-disposition", content_disposition(filename))
    |> send_resp(200, body)
  end

  defp error_response(conn, reason) do
    body = Export.snapshot_json(%{error: safe_reason(reason)})

    conn
    |> put_resp_content_type("application/json", "utf-8")
    |> send_resp(400, body)
  end

  defp current_snapshot do
    case QueryBroker.snapshot() do
      snapshot when is_map(snapshot) -> snapshot
      _ -> ClusterSnapshot.empty(DateTime.utc_now(), stale?: true)
    end
  end

  defp normalize_scope_and_target(scope, target, params) do
    case scope do
      scope when scope in [:service, "service"] ->
        {:ok, :service, target || parameter(params, :service)}

      scope when scope in [:node, "node"] ->
        {:ok, :node, target || parameter(params, :node)}

      scope when scope in [:cluster, "cluster"] ->
        {:ok, :cluster, target || parameter(params, :node)}

      _ ->
        {:error, :invalid_log_scope}
    end
  end

  defp parse_lines(nil), do: {:ok, 200}
  defp parse_lines(value) when is_integer(value), do: {:ok, value}

  defp parse_lines(value) when is_binary(value) do
    case Integer.parse(value) do
      {lines, ""} -> {:ok, lines}
      _ -> {:error, :invalid_lines}
    end
  end

  defp parse_lines(_value), do: {:error, :invalid_lines}

  defp log_query(:service, target, lines), do: {:logs, target, lines}
  defp log_query(:node, target, lines), do: {:node_service_logs, target, lines}
  defp log_query(:cluster, target, lines), do: {:cluster_logs, target, lines}

  defp parameter(params, key) do
    Map.get(params, key, Map.get(params, Atom.to_string(key)))
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: reason
  defp safe_reason(_reason), do: "invalid_request"
end
