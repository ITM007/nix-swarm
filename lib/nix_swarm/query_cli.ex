defmodule NixSwarm.QueryCLI do
  @moduledoc false

  alias NixSwarm.QueryProtocol

  def main([encoded_request]) when is_binary(encoded_request) do
    result =
      with {:ok, request_payload} <- Base.url_decode64(encoded_request, padding: false),
           {:ok, request} <- QueryProtocol.decode_request(request_payload),
           {:ok, response} <- NixSwarm.QueryClient.query(request) do
        response
      end

    case QueryProtocol.encode_response(result) do
      {:ok, encoded} ->
        IO.write(encoded)

      {:error, reason} ->
        IO.puts(:stderr, "query failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def main(_args) do
    IO.puts(:stderr, "usage: nix-swarm-query REQUEST")
    System.halt(64)
  end
end
